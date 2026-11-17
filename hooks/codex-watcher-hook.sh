#!/bin/zsh -f
# codex-watcher-hook.sh: Codex CLI hook for ClaudeWatcher.
# codex-watcher-hook-version: 1
#
# Codex never persists approval requests to its rollout files, so this hook records the
# last lifecycle event per session; ClaudeWatcher reads PermissionRequest as "waiting".
#
# Codex runs hooks inside its shared app-server daemon, as `$SHELL -lc "<command>"` in a new
# session (no controlling tty), with the hook JSON on stdin. So unlike the Claude hook this
# one can't see the TUI's pid or tty: the app joins its state to a live Codex TUI by thread
# id, after discovery matched the TUI to its thread.
#
# Input: hook JSON on stdin (session_id = root thread id, hook_event_name, turn_id,
#        agent_id for subagent events, cwd, ...).
# Output, in $STATE_DIR:
#   <sid>.json   written atomically (temp file + rename) by every event except SessionEnd:
#                {"session_id":"…","last_event":"PermissionRequest","turn_id":"…",
#                 "agent_id":null,"cwd":"…","updated_at":1792680000000}
#   SessionEnd removes <sid>.json. Files untouched for 2 days are garbage-collected.
#
# Contract: never block or fail Codex. Always exit 0, print nothing on stdout (SessionStart
# stdout would become model context; Stop's exit code has control effects), swallow errors.
#
# Env overrides (tests/debugging):
#   CODEX_WATCHER_STATE_DIR   state directory
#   CODEX_WATCHER_NO_JQ=1     force the pure-zsh fallback even when jq exists

exec >/dev/null 2>&1
setopt no_nomatch extended_glob
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$PATH"
zmodload zsh/datetime 2>/dev/null
zmodload -F zsh/files b:zf_mv b:zf_rm b:zf_mkdir 2>/dev/null

main() {
  local input
  input=$(cat) || return 0
  [[ -n $input ]] || return 0

  local state_dir=${CODEX_WATCHER_STATE_DIR:-"$HOME/Library/Application Support/ClaudeWatcher/codex-hook-state"}
  [[ -d $state_dir ]] || zf_mkdir -p "$state_dir" || mkdir -p "$state_dir" || return 0

  local use_jq=0
  if [[ ${CODEX_WATCHER_NO_JQ:-0} != 1 ]] && command -v jq >/dev/null; then use_jq=1; fi

  local sid event turn agent
  if (( use_jq )); then
    local -a fields
    fields=( "${(@f)$(print -r -- "$input" | jq -r 'def s: if type == "string" then . else "" end;
      (.session_id | s), (.hook_event_name | s), (.turn_id | s), (.agent_id | s)')}" ) || return 0
    sid=${fields[1]} event=${fields[2]} turn=${fields[3]} agent=${fields[4]}
  else
    sid=$(json_string_value "$input" session_id)
    event=$(json_string_value "$input" hook_event_name)
    turn=$(json_string_value "$input" turn_id)
    agent=$(json_string_value "$input" agent_id)
  fi
  # session_id becomes a filename: allow only a conservative character set.
  [[ $sid == [A-Za-z0-9][A-Za-z0-9._-]# ]] || return 0
  [[ $event == [A-Za-z]## ]] || event=unknown
  [[ $turn == [A-Za-z0-9._:-]## ]] || turn=""
  [[ $agent == [A-Za-z0-9._:/-]## ]] || agent=""

  local state_file="$state_dir/$sid.json"
  maybe_gc "$state_dir"

  if [[ $event == SessionEnd ]]; then
    zf_rm -f "$state_file"
    return 0
  fi

  local now_ms=$(( ${EPOCHREALTIME:-$(date +%s)} * 1000 ))
  now_ms=${now_ms%%.*}

  local tmp="$state_dir/.$sid.json.tmp.$$"
  if (( use_jq )); then
    print -r -- "$input" | jq -c \
      --arg sid "$sid" \
      --arg event "$event" \
      --arg turn "$turn" \
      --arg agent "$agent" \
      --argjson now "$now_ms" \
      '{session_id: $sid,
        last_event: $event,
        turn_id: (if $turn == "" then null else $turn end),
        agent_id: (if $agent == "" then null else $agent end),
        cwd: (if (.cwd | type) == "string" then .cwd else null end),
        updated_at: $now}' >| "$tmp" || { zf_rm -f "$tmp"; return 0; }
  else
    local cwd_json
    cwd_json=$(json_raw_string "$input" cwd)
    print -r -- "{\"session_id\":\"$sid\",\"last_event\":\"$event\",\"turn_id\":$(json_str_or_null "$turn"),\"agent_id\":$(json_str_or_null "$agent"),\"cwd\":$(json_str_or_null "$cwd_json"),\"updated_at\":$now_ms}" >| "$tmp" || { zf_rm -f "$tmp"; return 0; }
  fi
  zf_mv -f "$tmp" "$state_file" 2>/dev/null || mv -f "$tmp" "$state_file" || zf_rm -f "$tmp"
}

# At most every 10 minutes: drop state files untouched for 2 days (ended or abandoned
# sessions whose SessionEnd never ran) and leftover temp files.
maybe_gc() {
  local dir=$1 stamp="$1/.gc-stamp"
  local -a recent=( $stamp(Nmm-10) )
  (( ${#recent} )) && return 0
  : >| "$stamp"
  local f
  for f in $dir/[^.]*.json(Nmh+48); do zf_rm -f "$f"; done
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
# Arg is already JSON-escaped string content.
json_str_or_null() {
  if [[ -n $1 ]]; then print -r -- "\"$1\""; else print -r -- null; fi
}

main
exit 0
