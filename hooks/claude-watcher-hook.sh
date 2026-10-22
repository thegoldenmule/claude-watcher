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
# SessionEnd deletes the file (and leaves a short-lived "<session_id>.ended" tombstone
# so a slow async hook from the same session cannot resurrect it).
#
# Contract: never block or fail Claude. Always exit 0, print nothing on stdout,
# swallow errors.
#
# Env overrides (tests/debugging):
#   CLAUDE_WATCHER_STATE_DIR   state directory
#   CLAUDE_WATCHER_CLAUDE_PID  skip the process-tree walk and use this pid
#   CLAUDE_WATCHER_NO_JQ=1     force the pure-zsh fallback even when jq exists

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

  local sid event
  if (( use_jq )); then
    local fields
    fields=$(print -r -- "$input" | jq -r '[.session_id // "", .hook_event_name // ""] | @tsv') || return 0
    sid=${fields%%$'\t'*}
    event=${fields#*$'\t'}
  else
    sid=$(json_raw_string "$input" session_id)
    event=$(json_raw_string "$input" hook_event_name)
  fi
  # session_id becomes a filename: allow only a conservative character set.
  [[ $sid == [A-Za-z0-9][A-Za-z0-9._-]# ]] || return 0
  [[ $event == [A-Za-z]## ]] || event=unknown

  local state_file="$state_dir/$sid.json"
  local tombstone="$state_dir/$sid.ended"

  if [[ $event == SessionEnd ]]; then
    : >| "$tombstone"
    zf_rm -f "$state_file" || rm -f "$state_file"
    return 0
  fi
  # A (re)started session supersedes any earlier end of the same id (e.g. --resume).
  [[ $event == SessionStart ]] && zf_rm -f "$tombstone"

  maybe_gc "$state_dir"

  local claude_pid tty
  find_claude || return 0   # not under a claude process: nothing useful to record

  local term_program=${TERM_PROGRAM:-}
  local now_ms=$(( ${EPOCHREALTIME:-$(date +%s)} * 1000 ))
  now_ms=${now_ms%%.*}

  local old=""
  [[ -f $state_file ]] && old=$(<"$state_file")

  # ---------------------------------------------------------------------------
  # HOOK POINT: resolve Ghostty terminal id
  # Keep an id we already resolved; otherwise try to resolve it now.
  local ghostty_id=""
  if (( use_jq )); then
    [[ -n $old ]] && ghostty_id=$(print -r -- "$old" | jq -r '.ghostty_terminal_id // empty' 2>/dev/null)
  else
    ghostty_id=$(json_string_value "$old" ghostty_terminal_id)
  fi
  if [[ -z $ghostty_id && $term_program == ghostty && $event == SessionStart ]]; then
    ghostty_id=$(resolve_ghostty_terminal_id "$claude_pid" "$tty")
  fi
  # ---------------------------------------------------------------------------

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
    local cwd_raw tp_raw
    cwd_raw=$(json_raw_string "$input" cwd)
    tp_raw=$(json_raw_string "$input" transcript_path)
    print -r -- "{\"session_id\":\"$sid\",\"claude_pid\":$claude_pid,\"tty\":$(json_str_or_null "$tty"),\"term_program\":$(json_str_or_null "$(json_escape "$term_program")"),\"cwd\":$(json_str_or_null "$cwd_raw"),\"transcript_path\":$(json_str_or_null "$tp_raw"),\"last_event\":\"$event\",\"ghostty_terminal_id\":$(json_str_or_null "$(json_escape "$ghostty_id")"),\"updated_at\":$now_ms}" >| "$tmp" || { zf_rm -f "$tmp"; return 0; }
  fi

  # SessionEnd may have run while we were working (async hooks race it).
  if [[ -e $tombstone ]]; then
    zf_rm -f "$tmp"
    return 0
  fi
  zf_mv -f "$tmp" "$state_file" || mv -f "$tmp" "$state_file" || zf_rm -f "$tmp"
  return 0
}

# HOOK POINT (Ghostty terminal id): print the Ghostty AppleScript terminal id that
# hosts this session, or nothing. Args: claude_pid, tty ("/dev/ttysNNN" or "").
# Called only on SessionStart, only under Ghostty, and only while no id is known.
# Hooks run async, so a slower lookup (osascript) is acceptable here.
resolve_ghostty_terminal_id() {
  return 0
}

# Sets claude_pid and tty by walking up from our parent to the nearest claude process.
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
