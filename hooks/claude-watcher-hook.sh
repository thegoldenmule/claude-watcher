#!/bin/zsh -f
# claude-watcher-hook.sh: Claude Code hook for ClaudeWatcher.
# claude-watcher-hook-version: 2
#
# Records what ~/.claude/sessions/<pid>.json lacks, so ClaudeWatcher can focus the
# right terminal: the claude PID <-> session_id link (found by walking up our own
# process tree), the controlling tty, TERM_PROGRAM and (eventually) the Ghostty
# terminal id.
#
# Input: hook JSON on stdin (session_id, cwd, transcript_path, hook_event_name, ...).
# Output, in $STATE_DIR:
#   <sid>.json     written atomically (temp file + rename) by every event, never read back:
#                  {"session_id":"…","claude_pid":123,"tty":"/dev/ttys001","term_program":"ghostty",
#                   "cwd":"…","transcript_path":"…","last_event":"Stop","updated_at":1792680000000}
#   <sid>.ghostty  sidecar holding just the Ghostty terminal id (temp file + rename). Written
#                  only by the detached OSC 7 probe and by SessionStart inheriting a /clear
#                  predecessor's id, so a hook rewriting <sid>.json can never drop it.
#   <sid>.ended    SessionEnd renames <sid>.json to this short-lived tombstone so a slow async
#                  hook from the same session cannot resurrect it. The sidecar stays next to
#                  it until GC, for a /clear successor (same pid + tty) to inherit.
#   .probe-<ttyname>.lock/owner   per-tty lock shared with the app's own OSC 7 probe (both
#                  rewrite that terminal's pwd); see probe_lock_acquire.
#
# Contract: never block or fail Claude. Always exit 0, print nothing on stdout,
# swallow errors. Only the detached probe ever waits.
#
# Env overrides (tests/debugging):
#   CLAUDE_WATCHER_STATE_DIR   state directory
#   CLAUDE_WATCHER_CLAUDE_PID  skip the process-tree walk and use this pid
#   CLAUDE_WATCHER_WALK_FROM   start the process-tree walk at this pid instead of $PPID
#   CLAUDE_WATCHER_NO_JQ=1     force the pure-zsh fallback even when jq exists
#   CLAUDE_WATCHER_NO_GHOSTTY_PROBE=1  skip the Ghostty terminal-id probe
#   CLAUDE_WATCHER_TTY         use this path as claude's tty (tests: a regular file or FIFO)
#   CLAUDE_WATCHER_OSASCRIPT   osascript command used by the probe (tests: a stub)
#   CLAUDE_WATCHER_TEST_BEFORE_LOCK_BREAK  command the probe runs after judging a probe lock
#                              stale and before renaming it aside (tests: simulate a race)

exec >/dev/null 2>&1
setopt no_nomatch extended_glob
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$PATH"
zmodload zsh/datetime 2>/dev/null
zmodload zsh/system 2>/dev/null
zmodload -F zsh/files b:zf_mv b:zf_rm b:zf_mkdir b:zf_rmdir 2>/dev/null

main() {
  local input
  input=$(cat) || return 0
  [[ -n $input ]] || return 0

  local state_dir=${CLAUDE_WATCHER_STATE_DIR:-"$HOME/Library/Application Support/ClaudeWatcher/hook-state"}
  [[ -d $state_dir ]] || zf_mkdir -p "$state_dir" || mkdir -p "$state_dir" || return 0

  local use_jq=0
  if [[ ${CLAUDE_WATCHER_NO_JQ:-0} != 1 ]] && command -v jq >/dev/null; then use_jq=1; fi

  # cwd_url: the cwd percent-encoded for OSC 7 (jq path); cwd_raw: the plain cwd, encoded
  # later by the detached probe (fallback path). Either may be empty: the probe then uses $PWD.
  local sid event cwd_url="" cwd_raw=""
  if (( use_jq )); then
    local -a fields
    fields=( "${(@f)$(print -r -- "$input" | jq -r '.session_id // "", .hook_event_name // "",
      (.cwd // "" | tostring | split("/") | map(@uri) | join("/"))')}" ) || return 0
    sid=${fields[1]} event=${fields[2]} cwd_url=${fields[3]}
  else
    sid=$(json_raw_string "$input" session_id)
    event=$(json_raw_string "$input" hook_event_name)
  fi
  # session_id becomes a filename: allow only a conservative character set.
  [[ $sid == [A-Za-z0-9][A-Za-z0-9._-]# ]] || return 0
  [[ $event == [A-Za-z]## ]] || event=unknown

  local state_file="$state_dir/$sid.json"
  local tombstone="$state_dir/$sid.ended"

  # Hook version 1 kept the Ghostty id inside <sid>.json: move it to the sidecar before this
  # event replaces (or tombstones) that file.
  migrate_v1_id "$state_dir" "$sid"

  if [[ $event == SessionEnd ]]; then
    # Keep the last state as the tombstone: it blocks late async writers for this id and
    # lets a /clear successor in the same process adopt the Ghostty id from <sid>.ghostty.
    if [[ -f $state_file ]]; then
      # rename keeps the JSON's old mtime: touch it, or GC could take a fresh tombstone (and
      # its sidecar) for an hour old before the successor adopts the id.
      atomic_mv "$state_file" "$tombstone" && touch -c "$tombstone"
    else
      : >| "$tombstone"
    fi
    return 0
  fi

  local claude_pid tty
  find_claude || return 0   # not under a claude process: nothing useful to record
  [[ -n ${CLAUDE_WATCHER_TTY:-} ]] && tty=$CLAUDE_WATCHER_TTY

  local term_program=${TERM_PROGRAM:-}
  local now_ms=$(( ${EPOCHREALTIME:-$(date +%s)} * 1000 ))
  now_ms=${now_ms%%.*}

  # No read-modify-write here: the Ghostty id lives in the <sid>.ghostty sidecar, so every
  # event just replaces <sid>.json wholesale and concurrent hooks need no lock.
  local ghostty_id=""
  if [[ $event == SessionStart ]]; then
    # /clear and in-process /resume start a new session_id in the same claude process:
    # drop the predecessor's state and adopt its Ghostty id (same pid + tty => same terminal).
    adopt_ghostty_id "$state_dir"
  fi
  # After adoption, so GC can't drop a predecessor's tombstone and sidecar first.
  maybe_gc "$state_dir"
  # A (re)started session supersedes any earlier end of the same id (e.g. --resume). After GC,
  # which would otherwise take our kept sidecar for an orphan (neither .json nor .ended).
  [[ $event == SessionStart ]] && zf_rm -f "$tombstone"

  local tmp="$state_dir/.$sid.json.tmp.$$"
  if (( use_jq )); then
    print -r -- "$input" | jq -c \
      --argjson pid "$claude_pid" \
      --arg tty "$tty" \
      --arg term "$term_program" \
      --arg event "$event" \
      --argjson now "$now_ms" \
      '{session_id: .session_id,
        claude_pid: $pid,
        tty: (if $tty == "" then null else $tty end),
        term_program: (if $term == "" then null else $term end),
        cwd: .cwd,
        transcript_path: .transcript_path,
        last_event: $event,
        updated_at: $now}' >| "$tmp" || { zf_rm -f "$tmp"; return 0; }
  else
    local tp_raw
    tp_raw=$(json_raw_string "$input" transcript_path)
    local cwd_json
    cwd_json=$(json_raw_string "$input" cwd)
    print -r -- "{\"session_id\":\"$sid\",\"claude_pid\":$claude_pid,\"tty\":$(json_str_or_null "$(json_escape "$tty")"),\"term_program\":$(json_str_or_null "$(json_escape "$term_program")"),\"cwd\":$(json_str_or_null "$cwd_json"),\"transcript_path\":$(json_str_or_null "$tp_raw"),\"last_event\":\"$event\",\"updated_at\":$now_ms}" >| "$tmp" || { zf_rm -f "$tmp"; return 0; }
    # Raw JSON string -> path for the probe: only "\/" is unescaped; any other escape means
    # we are unsure, so leave it empty and let the probe use $PWD (also encoded there).
    cwd_raw=${cwd_json//\\\//\/}
    [[ $cwd_raw == *\\* ]] && cwd_raw=""
  fi

  # SessionEnd may have run while we were working (async hooks race it).
  if [[ -e $tombstone ]]; then
    zf_rm -f "$tmp"
    return 0
  fi
  atomic_mv "$tmp" "$state_file" || { zf_rm -f "$tmp"; return 0; }
  # ...or between the check above and the rename: then the file we just wrote must go.
  [[ -e $tombstone ]] && { zf_rm -f "$state_file"; return 0; }

  # Inherited id: written after <sid>.json so GC never sees it as an orphan.
  [[ -n $ghostty_id ]] && write_sidecar "$state_dir" "$sid" "$ghostty_id"

  # ===========================================================================
  # HOOK POINT: resolve Ghostty terminal id
  # SessionStart (any source), Ghostty only, with a tty, outside tmux, id still unknown.
  # The state file above is already written without the id so pid/tty are available
  # immediately; the probe runs fully detached and writes <sid>.ghostty when it resolves.
  # ===========================================================================
  if [[ $event == SessionStart && -z $ghostty_id && $term_program == ghostty && -n $tty \
        && -z ${TMUX:-} && ${CLAUDE_WATCHER_NO_GHOSTTY_PROBE:-0} != 1 ]]; then
    ( ghostty_probe "$state_dir" "$sid" "$claude_pid" "$tty" "$cwd_url" "$cwd_raw" ) </dev/null >/dev/null 2>&1 &!
  fi
  return 0
}

# On SessionStart: sets ghostty_id to a still-valid id for this session, if any, and drops
# superseded state. Uses caller's: sid, claude_pid, tty, ghostty_id.
# - Our own sidecar is kept only if our last state (live file or tombstone) has the same pid
#   and tty: SessionStart "compact" keeps it, a --resume in another process/terminal drops it.
# - Other state files (and tombstones) of the same claude pid: adopt their sidecar id when the
#   tty matches (/clear successor), and delete the live ones with their sidecars.
adopt_ghostty_id() {
  local dir=$1 f content other tty_json=null
  [[ -n $tty ]] && tty_json="\"$tty\""
  if [[ -f $dir/$sid.ghostty ]]; then
    content=""
    if [[ -f $dir/$sid.json ]]; then content=$(<"$dir/$sid.json")
    elif [[ -f $dir/$sid.ended ]]; then content=$(<"$dir/$sid.ended"); fi
    if [[ $content == *\"claude_pid\":${claude_pid}[,}]* && $content == *\"tty\":${tty_json}[,}]* ]]; then
      ghostty_id=$(read_sidecar "$dir/$sid.ghostty")
    fi
    [[ -n $ghostty_id ]] || zf_rm -f "$dir/$sid.ghostty"
  fi
  for f in $dir/[^.]*.(json|ended)(N); do
    other=${f:t:r}
    [[ $other == $sid ]] && continue
    content=$(<"$f")
    [[ $content == *\"claude_pid\":${claude_pid}[,}]* ]] || continue
    if [[ -z $ghostty_id && $content == *\"tty\":${tty_json}[,}]* ]]; then
      if [[ -f $dir/$other.ghostty ]]; then ghostty_id=$(read_sidecar "$dir/$other.ghostty")
      else ghostty_id=$(v1_ghostty_id "$content"); fi   # predecessor written by hook version 1
    fi
    [[ $f == *.json ]] && zf_rm -f "$f" "$dir/$other.ghostty"
  done
}

# Prints the id in sidecar $1 if it looks like one.
read_sidecar() {
  local v
  [[ -f $1 ]] && v=$(<"$1")
  [[ $v == [A-Za-z0-9-]## ]] && print -r -- "$v"
}

# Prints the Ghostty id a hook-version-1 state JSON ($1) carried inline, if valid.
v1_ghostty_id() {
  [[ $1 == *'"ghostty_terminal_id"'* ]] || return 0
  [[ $1 =~ '"ghostty_terminal_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9-]{1,128})"' ]] \
    && print -r -- "$match[1]"
}

# Writes <dir>/<sid>.ghostty ($1 $2) from an id that <sid>.json still carries inline (hook
# version 1), unless the sidecar exists. Cheap: reads the JSON only while there is no sidecar.
migrate_v1_id() {
  local f="$1/$2.json" content id
  [[ -f $f && ! -e $1/$2.ghostty ]] || return 0
  content=$(<"$f")
  [[ $content == *'"ghostty_terminal_id"'* ]] || return 0
  id=$(v1_ghostty_id "$content")
  [[ -n $id ]] && write_sidecar "$1" "$2" "$id"
}

# Atomically replaces <dir>/<sid>.ghostty ($1 $2) with id $3.
write_sidecar() {
  local tmp="$1/.$2.ghostty.tmp.${sysparams[pid]:-$$}"
  { print -rn -- "$3" >| "$tmp" && atomic_mv "$tmp" "$1/$2.ghostty" } || zf_rm -f "$tmp"
}

atomic_mv() {
  zf_mv -f "$1" "$2" 2>/dev/null || mv -f "$1" "$2"
}

# Detached: resolve the id (serialized per tty with the app's probe) and write the sidecar.
# Args: state dir, session id, claude pid, tty, cwd_url (encoded, may be empty), cwd_raw.
ghostty_probe() {
  local dir=$1 sid=$2 pid=$3 tty=$4 cwd_url=$5 cwd_raw=$6
  [[ -n $cwd_url ]] || cwd_url=$(osc7_encode "${cwd_raw:-$PWD}" /)
  local plock="$dir/.probe-${tty:t}.lock" token id=""
  probe_lock_acquire "$plock" || return 0
  token=$REPLY
  {
    # A /clear predecessor's probe may have handed us the id while we waited.
    [[ -n $(read_sidecar "$dir/$sid.ghostty") ]] && return 0
    id=$(resolve_ghostty_terminal_id "$pid" "$tty" "$cwd_url")
  } always {
    probe_lock_release "$plock" "$token"
  }
  [[ $id == [A-Za-z0-9-]## ]] || return 0
  # Written even if the session ended meanwhile: the sidecar next to the tombstone is what a
  # /clear successor that has not started yet inherits.
  write_sidecar "$dir" "$sid" "$id"
  [[ -f $dir/$sid.json && ! -e $dir/$sid.ended ]] && return 0
  # Ended or superseded (/clear) while we probed: hand the id to a successor that already
  # started in the same process and terminal, unless it has one.
  local f content tty_json="\"$tty\""
  for f in $dir/[^.]*.json(N); do
    [[ ${f:t:r} == $sid || -f ${f:r}.ghostty ]] && continue
    content=$(<"$f")
    [[ $content == *\"claude_pid\":${pid}[,}]* && $content == *\"tty\":${tty_json}[,}]* ]] || continue
    write_sidecar "$dir" "${f:t:r}" "$id"
  done
}

# Per-tty probe lock, shared with the app's Swift OSC7ProbeLock. Protocol v2, same on both
# sides:
# - acquire: mkdir <lock> (atomic), then write "<pid> <token>" to <lock>/owner;
# - held: poll every ~25 ms for at most 1 s, then give up (return 1);
# - stale (probe_lock_stale): owner pid dead; or owner missing/unparseable and the dir older
#   than 10 s; or owner pid alive but the dir older than 120 s (pid reuse cap). The Swift
#   holder touches the dir every ~2 s; we hold it for a few seconds at most (AppleScript times
#   out after 3 s), so our live pid alone keeps it fresh;
# - break (probe_lock_break): rename it to <lock>.stale-<random>, and only if the aside owner
#   is still the one judged stale remove it and retry mkdir; else put it back (it was fresh).
# On success REPLY is the token for probe_lock_release.
probe_lock_acquire() {
  local lock=$1 me=${sysparams[pid]} seen
  local deadline=$(( EPOCHREALTIME + 1.0 ))
  # Our pid must be the detached probe's own (alive while we hold the lock), never $$.
  [[ $me == <1-> ]] && zmodload -e zsh/files && zmodload zsh/zselect 2>/dev/null || return 1
  REPLY="${EPOCHREALTIME/./}$RANDOM$RANDOM"
  while :; do
    if zf_mkdir "$lock" 2>/dev/null; then
      print -r -- "$me $REPLY" >| "$lock/owner" && return 0
      zf_rmdir "$lock" 2>/dev/null
      return 1
    fi
    (( EPOCHREALTIME < deadline )) || return 1
    if probe_lock_stale "$lock"; then
      [[ -n ${CLAUDE_WATCHER_TEST_BEFORE_LOCK_BREAK:-} ]] && "$CLAUDE_WATCHER_TEST_BEFORE_LOCK_BREAK"
      probe_lock_break "$lock" "$seen" && continue
    fi
    zselect -t 2   # ~20 ms (returns 1 on timeout)
  done
}

# True if lock $1 is stale (see probe_lock_acquire). Sets the caller's `seen` to the owner
# content it judged ("" when missing or unreadable).
probe_lock_stale() {
  local lock=$1
  local -a f old
  seen=""
  [[ -d $lock ]] || return 1
  [[ -r $lock/owner ]] && seen=$(<"$lock/owner")
  f=( ${=seen} )
  if (( ${#f} == 2 )) && [[ $f[1] == <1-> ]]; then
    pid_alive "$f[1]" || return 0
    old=( $lock(N/ms+120) )
  else
    old=( $lock(N/ms+10) )
  fi
  (( ${#old} ))
}

# kill -0 fails for a dead pid and (EPERM) for another user's live one; zsh hides errno, so
# ask ps in that rare case.
pid_alive() {
  kill -0 "$1" 2>/dev/null && return 0
  [[ -n $(ps -o pid= -p "$1" 2>/dev/null) ]]
}

# Renames stale lock $1 (owner content $2 when judged) aside. Returns 0 if the lock is gone
# and mkdir should be retried, 1 if it is busy.
probe_lock_break() {
  local lock=$1 seen=$2 grave="$1.stale-${sysparams[pid]}$RANDOM$RANDOM" aside=""
  local -a old
  if ! zf_mv "$lock" "$grave" 2>/dev/null; then
    [[ -e $lock ]] && return 1
    return 0   # already gone: another breaker won, or the holder released it
  fi
  [[ -r $grave/owner ]] && aside=$(<"$grave/owner")
  if [[ $aside == "$seen" ]]; then
    old=( $grave(N/ms+10) )
    # Same owner, or (no owner) still the old dir: the lock we judged. Without an owner, a
    # lock taken in between (mkdir done, owner not yet written) would be young.
    if [[ -n $seen ]] || (( ${#old} )); then
      zf_rm -rf "$grave"
      return 0
    fi
  fi
  # We moved a fresh lock away: put it back. zf_mv moves *into* an existing directory, so
  # never restore over a lock taken meanwhile (and undo it if one appeared in between):
  # then drop the aside dir, as the Swift side's RENAME_EXCL does.
  [[ -e $lock ]] || zf_mv "$grave" "$lock" 2>/dev/null
  [[ -e $grave ]] && zf_rm -rf "$grave"
  [[ -e $lock/${grave:t} ]] && zf_rm -rf "$lock/${grave:t}"
  return 1
}

# Removes the lock only while <lock>/owner still holds our token: if someone broke it as
# stale, the lock there now is theirs.
probe_lock_release() {
  local lock=$1 owner=""
  [[ -f $lock/owner ]] && owner=$(<"$lock/owner")
  [[ $owner == "${sysparams[pid]:-$$} $2" ]] || return 0
  zf_rm -f "$lock/owner"
  zf_rmdir "$lock" 2>/dev/null
}

# HOOK POINT (Ghostty terminal id): print the Ghostty AppleScript terminal id hosting
# claude_pid, or nothing. Args: claude_pid, tty ("/dev/ttysNNN"), cwd (already encoded).
# OSC 7 nonce probe (verified 75-90ms, correct incl. split panes): set the terminal's
# pwd to a unique fake path via claude's tty, ask Ghostty which terminal reports it,
# then restore the real pwd. The hook has no controlling tty, so write to claude's.
# The nonce ends in "-x" so an older, longer nonce can never contain it, and an id is only
# trusted when exactly one terminal reports it.
resolve_ghostty_terminal_id() {
  local pid=$1 tty=$2 cwd=$3
  local host
  host=$(osc7_encode "${HOST:-$(hostname)}")
  local nonce="CW-$pid-$RANDOM$RANDOM-x"
  [[ -w $tty ]] || return 0
  local out="" rc
  osc_send "$tty" $'\e]7;file://'"$host/tmp/$nonce"$'\a'; rc=$?
  (( rc == 1 )) && return 0   # nothing went out: the terminal is untouched
  # rc 2: only part of the nonce went out (now BEL-terminated); just restore.
  (( rc == 0 )) && out=$(${CLAUDE_WATCHER_OSASCRIPT:-osascript} -e 'on run argv
    set n to "/" & (item 1 of argv)
    tell application "Ghostty"
      with timeout of 3 seconds
        repeat 20 times
          set ids to id of every terminal whose working directory contains n
          if (count of ids) > 0 then
            set AppleScript'"'"'s text item delimiters to linefeed
            return ids as text
          end if
          delay 0.03
        end repeat
      end timeout
    end tell
    return ""
  end run' "$nonce" 2>/dev/null)
  osc_send "$tty" $'\e]7;file://'"$host$cwd"$'\a'
  local -a ids=( ${(f)out} )
  (( ${#ids} == 1 )) && print -r -- "$ids[1]"
}

# Percent-encodes $1 for a file URL (like Swift's OSC7Probe.percentEncodePath: urlPathAllowed
# minus %;?#), byte by byte, so the result is printable ASCII: no control byte can end the
# escape sequence early or inject another one. $2 = "/" keeps slashes (paths); the host
# passes nothing, so a "/" in it is encoded too.
osc7_encode() {
  emulate -L zsh
  setopt no_multibyte
  local s=$1 keep=${2:-} out="" c
  local -i i n
  for (( i = 1; i <= ${#s}; i++ )); do
    c=${s[i]}
    if [[ $c == [a-zA-Z0-9._~!\$\&\'\(\)*+,=:@-] || ( -n $keep && $c == $keep ) ]]; then
      out+=$c
    else
      n=$(( #c ))
      (( n < 0 )) && (( n += 256 ))
      out+=%${(l:2::0:)$(( [##16] n ))}
    fi
  done
  print -rn -- "$out"
}

# Writes one BEL-terminated OSC sequence $2 to tty $1. If only a prefix went out, still
# sends the terminating BEL so the terminal is never left inside an unterminated string.
# Returns tty_write's status for the sequence.
osc_send() {
  local rc
  tty_write "$1" "$2"; rc=$?
  (( rc == 2 )) && tty_write "$1" $'\a'
  return $rc
}

# Writes $2 to tty $1 without ever blocking for long: the fd is non-blocking, so a
# flow-controlled (XOFF) tty fails with EAGAIN instead of hanging the detached probe. On
# EAGAIN or a short write it waits for writability (zselect) and retries the remainder, for
# at most ~200 ms in total. Returns 0 if everything was written, 1 if nothing was, 2 if only
# a prefix was. (macOS never makes a tty the controlling terminal on open, so no O_NOCTTY is
# needed; zsh's sysopen does not offer it.) Falls back to a plain append only when
# zsh/system is unavailable.
tty_write() {
  emulate -L zsh
  setopt no_multibyte
  local data=$2 fd deadline
  local -i n sent=0 cs ready=0
  if ! zmodload zsh/system 2>/dev/null; then
    print -rn -- "$data" >> "$1" && return 0
    return 1
  fi
  zmodload zsh/zselect 2>/dev/null || return 1
  sysopen -w -a -o nonblock,cloexec -u fd "$1" || return 1
  deadline=$(( EPOCHREALTIME + 0.2 ))
  while (( sent < ${#data} )); do
    n=0
    syswrite -c n -o $fd -- "${data[sent+1,-1]}" && { sent=${#data}; break; }
    (( sent += n ))
    # zsh exposes no errno here: no progress although zselect said writable is a hard
    # error (EIO, ...), not EAGAIN, so stop instead of spinning.
    (( n > 0 || ! ready )) || break
    (( cs = (deadline - EPOCHREALTIME) * 100 + 1 ))
    (( cs > 1 )) || break
    zselect -t $cs -w $fd && ready=1 || ready=0   # 1 on timeout: one last try, then stop
  done
  exec {fd}>&-
  (( sent == ${#data} )) && return 0
  (( sent > 0 )) && return 2
  return 1
}

# Sets claude_pid and tty by walking up from our parent to the nearest claude process.
# Hooks are direct children of claude, so this normally stops at $PPID; the walk covers
# an intermediate shell. ($CLAUDE_PID is not trusted on its own: a claude started from
# inside another session's Bash tool could inherit the outer session's value.)
find_claude() {
  claude_pid="" tty=""
  local p=${CLAUDE_WATCHER_CLAUDE_PID:-${CLAUDE_WATCHER_WALK_FROM:-$PPID}} depth=0 line ppid t ucomm args
  while (( depth < 12 )) && [[ $p == <2-> ]]; do
    line=$(ps -o ppid= -o tty= -o ucomm= -o args= -p "$p" 2>/dev/null) || return 1
    [[ -n $line ]] || return 1
    read -r ppid t ucomm args <<< "$line"
    if [[ -n ${CLAUDE_WATCHER_CLAUDE_PID:-} ]] || is_claude_process "$ucomm" "$args"; then
      claude_pid=$p
      [[ -n $t && $t != '??' && $t != - ]] && tty="/dev/${t#/dev/}"
      return 0
    fi
    p=$ppid
    (( depth++ ))
  done
  return 1
}

# True if a process with ucomm $1 and command line $2 (ps args) runs Claude Code (mirrors
# Swift's ProcessRules.isClaudeExecutable). Native installs exec
# ~/.local/share/claude/versions/<ver> (ucomm is the version string, argv0 is "claude"),
# Homebrew's cask runs Caskroom/claude-code/…/claude. Newer npm installs exec a native
# …/@anthropic-ai/claude-code/bin/claude.exe (ucomm "claude.exe", argv0 "claude").
# Older npm installs run node on the package:
# argv is "node /opt/homebrew/bin/claude …", where bin/claude is a symlink to
# …/@anthropic-ai/claude-code/cli.js, so for node look at the script (first non-option arg,
# or the one right after `--`, like Swift's ProcessRules.nodeScript): named claude or, if
# absolute, resolving into the package.
is_claude_process() {
  local ucomm=$1 args=$2 a dashdash=0
  [[ $ucomm == claude || $ucomm == <->.<->.<->* || ${${args%% *}:t} == claude \
     || $args == */claude/versions/* || $args == *@anthropic-ai/claude-code* ]] && return 0
  [[ $ucomm == node || ${${args%% *}:t} == node ]] || return 1
  for a in ${${(z)args}[2,-1]}; do
    if (( ! dashdash )); then
      [[ $a == -- ]] && { dashdash=1; continue }
      [[ $a == -* ]] && continue
    fi
    # Realpath only absolute scripts: a relative one is relative to node's cwd, not ours.
    [[ ${a:t} == claude || ( $a == /* && ${a:A} == *@anthropic-ai/claude-code* ) ]]
    return
  done
  return 1
}

# At most every 10 minutes: drop state files whose claude_pid is dead (or reused by a
# non-claude process), tombstones older than an hour, and sidecars left without either.
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
      is_claude_process "$lucomm" "$largs" && ok[$lpid]=1
    done
    for pid in ${(k)file_for_pid}; do
      [[ -n ${ok[$pid]} ]] && continue
      for f in ${(f)file_for_pid[$pid]}; do zf_rm -f "$f"; done
    done
  fi
  for f in $dir/*.ended(Nmh+1); do zf_rm -f "$f"; done
  for f in $dir/[^.]*.ghostty(N); do
    [[ -e ${f:r}.json || -e ${f:r}.ended ]] || zf_rm -f "$f"
  done
  for f in $dir/.*.tmp.*(Nmh+1); do zf_rm -f "$f"; done
  # Broken probe locks whose rm -rf did not finish; per-session locks of hook version 1.
  for f in $dir/.probe-*.lock.stale-*(N/mh+1) $dir/.lock-*(N/mh+1); do zf_rm -rf "$f"; done
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
