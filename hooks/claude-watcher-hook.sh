#!/bin/zsh -f
# claude-watcher-hook.sh: Claude Code hook for ClaudeWatcher.
# claude-watcher-hook-version: 1
#
# Records what ~/.claude/sessions/<pid>.json lacks, so ClaudeWatcher can focus the
# right terminal: the claude PID <-> session_id link (found by walking up our own
# process tree), the controlling tty, TERM_PROGRAM and (eventually) the Ghostty
# terminal id.
#
# Input: hook JSON on stdin (session_id, cwd, transcript_path, hook_event_name, ...).
# Output: $STATE_DIR/<session_id>.json, written atomically (temp file + rename):
#   {"session_id":"…","claude_pid":123,"tty":"/dev/ttys001","term_program":"ghostty",
#    "cwd":"…","transcript_path":"…","last_event":"Stop","ghostty_terminal_id":null,
#    "updated_at":1792680000000}
# SessionEnd renames it to a short-lived "<session_id>.ended" tombstone so a slow async
# hook from the same session cannot resurrect it. On Ghostty, SessionStart also starts a
# detached OSC 7 nonce probe that fills in ghostty_terminal_id (see HOOK POINT below).
#
# Contract: never block or fail Claude. Always exit 0, print nothing on stdout,
# swallow errors.
#
# Env overrides (tests/debugging):
#   CLAUDE_WATCHER_STATE_DIR   state directory
#   CLAUDE_WATCHER_CLAUDE_PID  skip the process-tree walk and use this pid
#   CLAUDE_WATCHER_NO_JQ=1     force the pure-zsh fallback even when jq exists
#   CLAUDE_WATCHER_NO_GHOSTTY_PROBE=1  skip the Ghostty terminal-id probe

exec >/dev/null 2>&1
setopt no_nomatch extended_glob
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$PATH"
zmodload zsh/datetime 2>/dev/null
zmodload -F zsh/files b:zf_mv b:zf_rm b:zf_mkdir 2>/dev/null

main() {
  local input
  input=$(cat) || return 0
  [[ -n $input ]] || return 0

  local state_dir=${CLAUDE_WATCHER_STATE_DIR:-"$HOME/Library/Application Support/ClaudeWatcher/hook-state"}
  [[ -d $state_dir ]] || zf_mkdir -p "$state_dir" || mkdir -p "$state_dir" || return 0

  local use_jq=0
  if [[ ${CLAUDE_WATCHER_NO_JQ:-0} != 1 ]] && command -v jq >/dev/null; then use_jq=1; fi

  local sid event cwd
  if (( use_jq )); then
    local -a fields
    fields=( "${(@f)$(print -r -- "$input" | jq -r '.session_id // "", .hook_event_name // "", .cwd // ""')}" ) || return 0
    sid=${fields[1]} event=${fields[2]} cwd=${fields[3]}
  else
    sid=$(json_raw_string "$input" session_id)
    event=$(json_raw_string "$input" hook_event_name)
    cwd=$(json_raw_string "$input" cwd)
  fi
  # session_id becomes a filename: allow only a conservative character set.
  [[ $sid == [A-Za-z0-9][A-Za-z0-9._-]# ]] || return 0
  [[ $event == [A-Za-z]## ]] || event=unknown

  local state_file="$state_dir/$sid.json"
  local tombstone="$state_dir/$sid.ended"

  if [[ $event == SessionEnd ]]; then
    # Keep the last state as the tombstone: it blocks late async writers for this id and
    # lets a /clear successor in the same process adopt the Ghostty terminal id.
    if [[ -f $state_file ]]; then
      zf_mv -f "$state_file" "$tombstone" || mv -f "$state_file" "$tombstone"
    else
      : >| "$tombstone"
    fi
    return 0
  fi

  maybe_gc "$state_dir"

  local claude_pid tty
  find_claude || return 0   # not under a claude process: nothing useful to record

  local term_program=${TERM_PROGRAM:-}
  local now_ms=$(( ${EPOCHREALTIME:-$(date +%s)} * 1000 ))
  now_ms=${now_ms%%.*}

  # Keep a Ghostty id we already resolved for this session.
  local old="" ghostty_id=""
  [[ -f $state_file ]] && old=$(<"$state_file")
  ghostty_id=$(json_string_value "$old" ghostty_terminal_id)

  if [[ $event == SessionStart ]]; then
    # /clear and in-process /resume start a new session_id in the same claude process:
    # drop the predecessor's state and adopt its Ghostty id (same pid + tty => same terminal).
    supersede_same_pid "$state_dir"
    # A (re)started session supersedes any earlier end of the same id (e.g. --resume).
    zf_rm -f "$tombstone"
  fi

  local tmp="$state_dir/.$sid.json.tmp.$$"
  if (( use_jq )); then
    print -r -- "$input" | jq -c \
      --argjson pid "$claude_pid" \
      --arg tty "$tty" \
      --arg term "$term_program" \
      --arg event "$event" \
      --arg gid "$ghostty_id" \
      --argjson now "$now_ms" \
      '{session_id: .session_id,
        claude_pid: $pid,
        tty: (if $tty == "" then null else $tty end),
        term_program: (if $term == "" then null else $term end),
        cwd: .cwd,
        transcript_path: .transcript_path,
        last_event: $event,
        ghostty_terminal_id: (if $gid == "" then null else $gid end),
        updated_at: $now}' >| "$tmp" || { zf_rm -f "$tmp"; return 0; }
  else
    local tp_raw
    tp_raw=$(json_raw_string "$input" transcript_path)
    print -r -- "{\"session_id\":\"$sid\",\"claude_pid\":$claude_pid,\"tty\":$(json_str_or_null "$tty"),\"term_program\":$(json_str_or_null "$(json_escape "$term_program")"),\"cwd\":$(json_str_or_null "$cwd"),\"transcript_path\":$(json_str_or_null "$tp_raw"),\"last_event\":\"$event\",\"ghostty_terminal_id\":$(json_str_or_null "$ghostty_id"),\"updated_at\":$now_ms}" >| "$tmp" || { zf_rm -f "$tmp"; return 0; }
    cwd=${cwd//\\\//\/}   # raw JSON string -> path for the probe below (good enough)
  fi

  # SessionEnd may have run while we were working (async hooks race it).
  if [[ -e $tombstone ]]; then
    zf_rm -f "$tmp"
    return 0
  fi
  zf_mv -f "$tmp" "$state_file" || mv -f "$tmp" "$state_file" || { zf_rm -f "$tmp"; return 0; }

  # ===========================================================================
  # HOOK POINT: resolve Ghostty terminal id
  # SessionStart (any source), Ghostty only, with a tty, outside tmux, id still unknown.
  # The state file above is already written without the id so pid/tty are available
  # immediately; the probe runs fully detached and patches the id in when it resolves.
  # ===========================================================================
  if [[ $event == SessionStart && -z $ghostty_id && $term_program == ghostty && -n $tty \
        && -z ${TMUX:-} && ${CLAUDE_WATCHER_NO_GHOSTTY_PROBE:-0} != 1 ]]; then
    ( ghostty_probe "$state_dir" "$sid" "$claude_pid" "$tty" "${cwd:-$PWD}" ) </dev/null >/dev/null 2>&1 &!
  fi
  return 0
}

# On SessionStart: for other state files (and SessionEnd tombstones) of the same claude
# pid, adopt their Ghostty id when the tty matches, and delete the live ones.
# Uses caller's: sid, claude_pid, tty, ghostty_id.
supersede_same_pid() {
  local dir=$1 f content tty_json=null
  [[ -n $tty ]] && tty_json="\"$tty\""
  for f in $dir/[^.]*.(json|ended)(N); do
    [[ ${f:t:r} == $sid ]] && [[ $f == *.json ]] && continue
    content=$(<"$f")
    [[ $content == *\"claude_pid\":${claude_pid}[,}]* ]] || continue
    if [[ -z $ghostty_id && $content == *\"tty\":${tty_json}[,}]* ]]; then
      ghostty_id=$(json_string_value "$content" ghostty_terminal_id)
    fi
    [[ $f == *.json ]] && zf_rm -f "$f"
  done
}

# Detached: resolve the id (serialized per tty) and patch it into the state file.
ghostty_probe() {
  local dir=$1 sid=$2 pid=$3 tty=$4 cwd=$5
  local lock="$dir/.probe-${tty:t}.lock"
  local -a stale=( $lock(N/mm+1) )
  (( ${#stale} )) && rmdir "$lock" 2>/dev/null
  zf_mkdir "$lock" 2>/dev/null || return 0
  local id
  id=$(resolve_ghostty_terminal_id "$pid" "$tty" "$cwd")
  rmdir "$lock" 2>/dev/null
  [[ $id == [A-Za-z0-9-]## ]] || return 0
  local f="$dir/$sid.json" content
  [[ -f $f && ! -e $dir/$sid.ended ]] || return 0
  content=$(<"$f")
  [[ $content == *'"ghostty_terminal_id":null'* ]] || return 0
  local tmp="$dir/.$sid.json.tmp.$$"
  print -r -- "${content/\"ghostty_terminal_id\":null/\"ghostty_terminal_id\":\"$id\"}" >| "$tmp" \
    && zf_mv -f "$tmp" "$f" || zf_rm -f "$tmp"
}

# HOOK POINT (Ghostty terminal id): print the Ghostty AppleScript terminal id hosting
# claude_pid, or nothing. Args: claude_pid, tty ("/dev/ttysNNN"), cwd.
# OSC 7 nonce probe (verified 75-90ms, correct incl. split panes): set the terminal's
# pwd to a unique fake path via claude's tty, ask Ghostty which terminal reports it,
# then restore the real pwd. The hook has no controlling tty, so write to claude's.
resolve_ghostty_terminal_id() {
  local pid=$1 tty=$2 cwd=$3
  local host=${HOST:-$(hostname)}
  local nonce="CW-$pid-$RANDOM$RANDOM"
  [[ -w $tty ]] || return 0
  printf '\e]7;file://%s/tmp/%s\a' "$host" "$nonce" >> "$tty" || return 0
  local id
  id=$(osascript -e 'on run argv
    tell application "Ghostty"
      repeat 20 times
        set ids to id of every terminal whose working directory contains (item 1 of argv)
        if (count of ids) > 0 then return item 1 of ids
        delay 0.03
      end repeat
    end tell
    return ""
  end run' "$nonce" 2>/dev/null)
  printf '\e]7;file://%s%s\a' "$host" "$cwd" >> "$tty"
  print -r -- "$id"
}

# Sets claude_pid and tty by walking up from our parent to the nearest claude process.
# Hooks are direct children of claude, so this normally stops at $PPID; the walk covers
# an intermediate shell. ($CLAUDE_PID is not trusted on its own: a claude started from
# inside another session's Bash tool could inherit the outer session's value.)
# Native installs exec ~/.local/share/claude/versions/<ver> (ucomm is the version
# string, argv0 is "claude"); npm installs run node on @anthropic-ai/claude-code.
find_claude() {
  claude_pid="" tty=""
  local p=${CLAUDE_WATCHER_CLAUDE_PID:-$PPID} depth=0 line ppid t ucomm args
  while (( depth < 12 )) && [[ $p == <2-> ]]; do
    line=$(ps -o ppid= -o tty= -o ucomm= -o args= -p "$p" 2>/dev/null) || return 1
    [[ -n $line ]] || return 1
    read -r ppid t ucomm args <<< "$line"
    if [[ -n ${CLAUDE_WATCHER_CLAUDE_PID:-} \
       || $ucomm == claude || $ucomm == <->.<->.<->* \
       || ${${args%% *}:t} == claude \
       || $args == */claude/versions/* || $args == *@anthropic-ai/claude-code* ]]; then
      claude_pid=$p
      [[ -n $t && $t != '??' && $t != - ]] && tty="/dev/${t#/dev/}"
      return 0
    fi
    p=$ppid
    (( depth++ ))
  done
  return 1
}

# At most every 10 minutes: drop state files whose claude_pid is dead (or reused by a
# non-claude process) and tombstones older than an hour.
maybe_gc() {
  local dir=$1 stamp="$1/.gc-stamp"
  local -a recent=( $stamp(Nmm-10) )
  (( ${#recent} )) && return 0
  : >| "$stamp"
  local f content pid
  local -A file_for_pid
  for f in $dir/[^.]*.json(N); do
    content=$(<"$f")
    if [[ $content =~ '"claude_pid":([0-9]+)' ]]; then
      pid=$match[1]
      if kill -0 "$pid" 2>/dev/null; then
        file_for_pid[$pid]+="$f"$'\n'
      else
        zf_rm -f "$f"
      fi
    fi
  done
  if (( ${#file_for_pid} )); then
    local alive=$(ps -o pid= -o ucomm= -o args= -p "${(j:,:)${(k)file_for_pid}}" 2>/dev/null)
    local l lpid lucomm largs
    local -A ok
    for l in ${(f)alive}; do
      read -r lpid lucomm largs <<< "$l"
      if [[ $lucomm == claude || $lucomm == <->.<->.<->* || ${${largs%% *}:t} == claude \
         || $largs == */claude/versions/* || $largs == *@anthropic-ai/claude-code* ]]; then
        ok[$lpid]=1
      fi
    done
    for pid in ${(k)file_for_pid}; do
      [[ -n ${ok[$pid]} ]] && continue
      for f in ${(f)file_for_pid[$pid]}; do zf_rm -f "$f"; done
    done
  fi
  for f in $dir/*.ended(Nmh+1); do zf_rm -f "$f"; done
  for f in $dir/.*.tmp.*(Nmh+1); do zf_rm -f "$f"; done
}

# --- pure-zsh JSON helpers (fallback when jq is unavailable) -------------------
# Raw (still JSON-escaped) contents of a top-level-ish string field "key":"...".
json_raw_string() {
  local s=$1 key=$2
  if [[ $s =~ "\"$key\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\"" ]]; then
    print -r -- "$match[1]"
  fi
}
# Decoded-enough value of a string field (ids contain no escapes), else nothing.
json_string_value() {
  local v
  v=$(json_raw_string "$1" "$2")
  [[ $v == *\\* ]] && return 0
  print -r -- "$v"
}
json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  print -r -- "$s"
}
# Arg is already JSON-escaped string content.
json_str_or_null() {
  if [[ -n $1 ]]; then print -r -- "\"$1\""; else print -r -- null; fi
}

main
exit 0
