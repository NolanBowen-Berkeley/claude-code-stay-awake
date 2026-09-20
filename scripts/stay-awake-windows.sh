#!/bin/sh
# Stay Awake for Claude Code: Windows backend.
#
# Runs on native Windows (Claude Code with Git for Windows: hooks and slash
# commands go through Git Bash, so this is still POSIX sh) and inside WSL
# (Linux, reaching the Windows side through interop). stay-awake.sh hands over
# to this file on those platforms. Subcommands and configuration are the same
# as on macOS; only the mechanism differs:
#
#   caffeinate           -> a hidden PowerShell "keeper" (stay-awake-keeper.ps1)
#                           holding SetThreadExecutionState(ES_CONTINUOUS |
#                           ES_SYSTEM_REQUIRED [| ES_DISPLAY_REQUIRED]) while
#                           its hold file exists. On native Windows it also exits
#                           when the Claude process is gone (like -w). On WSL the
#                           Claude pid is a Linux pid the keeper cannot see, so a
#                           small sh "binder" watches it instead.
#   pgrep/pkill          -> pid files in STATE_DIR, tasklist/taskkill for Windows
#                           pids and kill for sh pids
#   pmset -g assertions  -> powercfg /requests (needs an elevated shell)
#
# Closed-lid mode is not automated on Windows: the lid action is a power-plan
# setting (powercfg ... LIDACTION) that needs an elevated shell every time it
# changes. The README describes the one-time manual setting.
set -u

CMD=${1:-}
PID_ARG=${2:-}
SELF=$0
HERE=$(cd "$(dirname "$SELF")" && pwd)
KEEPER=$HERE/stay-awake-keeper.ps1
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) WIN=native ;;
  *)                    WIN=wsl ;;
esac
export MSYS_NO_PATHCONV=1   # Git Bash: leave Windows paths in arguments alone
PS=$(command -v powershell.exe 2>/dev/null || true)
if [ -z "$PS" ]; then
  for c in /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe /c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe; do
    if [ -x "$c" ]; then PS=$c; break; fi
  done
fi

case "$(printf '%s' "${STAY_AWAKE_BACKGROUND:-1}" | tr '[:upper:]' '[:lower:]')" in
  0|false|no|off) BG_ENABLED=0 ;;
  *)              BG_ENABLED=1 ;;
esac
STATE_DIR=${STAY_AWAKE_STATE_DIR:-"${TMPDIR:-/tmp}/claude-stay-awake"}
LOG_FILE=${STAY_AWAKE_LOG:-"$STATE_DIR/stay-awake.log"}
FALLBACK_SECS=7200      # only used when the Claude pid cannot be determined
GUARD_MAX_SECS=86400    # backstop for the waiting-on-user poller
POLL_SECS=3             # how often the guard looks for a running command
DISPLAY_REQ=0           # STAY_AWAKE_FLAGS containing -d keeps the display on too
case " ${STAY_AWAKE_FLAGS:-} " in *" -d "*) DISPLAY_REQ=1 ;; esac

# ---- helpers ---------------------------------------------------------------

valid_hours() {  # non-negative number, decimals allowed
  case "$(printf '%s' "$1" | tr -d ' \t')" in
    ''|*[!0-9.]*|.|*.*.*) return 1 ;;
  esac
}
hours_to_secs() {  # $1 = value, $2 = default hours; prints whole seconds
  v=$(printf '%s' "$1" | tr -d ' \t')
  valid_hours "$v" || v=$2
  awk -v h="$v" 'BEGIN { printf "%d", h * 3600 }'
}
MAX_SECS=$(hours_to_secs "${STAY_AWAKE_MAX_HOURS:-0}" 0)
BG_MAX_SECS=$(hours_to_secs "${STAY_AWAKE_BACKGROUND_MAX_HOURS:-4}" 4)

log() {
  [ "${STAY_AWAKE_DEBUG:-0}" = 1 ] || return 0
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
  printf '%s [%s %s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "$CMD" "$*" >> "$LOG_FILE" 2>/dev/null
}

winpath() { if [ "$WIN" = native ]; then cygpath -w "$1"; else wslpath -w "$1"; fi; }
# Windows pids (Claude on native Windows, keepers) are checked with tasklist;
# sh pids (guard, watchdog, binder; Claude inside WSL) with kill -0.
win_alive()    { [ -n "${1:-}" ] && tasklist.exe /FI "PID eq $1" /NH 2>/dev/null | grep -q "^[^ ]* *$1 "; }
claude_alive() { if [ "$WIN" = native ]; then win_alive "$1"; else kill -0 "$1" 2>/dev/null; fi; }

# Claude Code exports CLAUDE_PID to hooks and slash-command shells.
find_claude_pid() {
  pid=${CLAUDE_PID:-}
  case "$pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
  claude_alive "$pid" || return 1
  echo "$pid"
}

# Everything lives in STATE_DIR: $tag-hold-<pid> (the keeper runs while it
# exists), $tag-keeper-<pid>.pid (the keeper's Windows pid), <name>-<pid>.pid
# (sh helpers), disabled-<pid> (the /stay-awake:off switch).
f_hold()   { printf '%s/%s-hold-%s' "$STATE_DIR" "$1" "$2"; }
f_kpid()   { printf '%s/%s-keeper-%s.pid' "$STATE_DIR" "$1" "$2"; }
f_spid()   { printf '%s/%s-%s.pid' "$STATE_DIR" "$1" "$2"; }
marker()   { printf '%s/disabled-%s' "$STATE_DIR" "$1"; }
read_pid() { [ -f "$1" ] || return 0; tr -d ' \r\n' < "$1"; }
keeper_pid()   { read_pid "$(f_kpid "$1" "$2")"; }
keeper_alive() { p=$(keeper_pid "$1" "$2"); [ -n "$p" ] && win_alive "$p"; }
sh_alive()     { p=$(read_pid "$(f_spid "$1" "$2")"); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

enabled() {  # $1 = claude pid (may be empty)
  [ "${STAY_AWAKE_DISABLED:-0}" != 1 ] || return 1
  [ -z "${1:-}" ] || [ ! -e "$(marker "$1")" ]
}

# Shell commands Claude runs are children of the Claude process whose command
# line mentions ~/.claude/shell-snapshots/snapshot-*. The plugin's own shells
# are excluded (their command lines mention stay-awake).
shell_task_count() {  # $1 = claude pid
  if [ "$WIN" = native ]; then
    "$PS" -NoProfile -NonInteractive -Command \
      "(Get-CimInstance Win32_Process -Filter 'ParentProcessId=$1' | Where-Object { \$_.CommandLine -like '*shell-snapshots*' -and \$_.CommandLine -notlike '*stay-awake*' } | Measure-Object).Count" 2>/dev/null | tr -d ' \r\n'
  else
    ps -e -o pid=,ppid=,args= 2>/dev/null | awk -v p="$1" '
      $2 == p && index($0, "shell-snapshots/snapshot-") && !index($0, "stay-awake") { c++ }
      END { print c + 0 }'
  fi
}
has_shell_tasks() { n=$(shell_task_count "$1"); [ "${n:-0}" -gt 0 ] 2>/dev/null; }

start_keeper() {  # $1 = tag (main|bg), $2 = claude pid (0 = none), $3 = max secs (0 = none)
  mkdir -p "$STATE_DIR" 2>/dev/null
  : > "$(f_hold "$1" "$2")"; : > "$(f_kpid "$1" "$2")"
  watch=0
  if [ "$WIN" = native ] && [ "$2" != 0 ]; then watch=$2; fi
  "$PS" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$(winpath "$KEEPER")" \
    "$(winpath "$(f_hold "$1" "$2")")" "$(winpath "$(f_kpid "$1" "$2")")" "$watch" "$3" "$DISPLAY_REQ" \
    </dev/null >/dev/null 2>&1 &
  i=0; while [ ! -s "$(f_kpid "$1" "$2")" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  log "keeper started: tag=$1 claude=$2 pid=$(keeper_pid "$1" "$2") watch=$watch max=$3 display=$DISPLAY_REQ"
  if [ "$WIN" = wsl ] && [ "$1" = main ] && [ "$2" != 0 ]; then start_sh binder "$2"; fi
}
stop_keeper() {  # $1 = tag, $2 = claude pid
  rm -f "$(f_hold "$1" "$2")"
  p=$(keeper_pid "$1" "$2")
  if [ -n "$p" ]; then
    taskkill.exe /PID "$p" /F >/dev/null 2>&1
    log "keeper stopped: tag=$1 claude=$2 pid=$p"
  fi
  rm -f "$(f_kpid "$1" "$2")"
  [ "$1" != main ] || stop_sh binder "$2"
  return 0
}
start_sh() {  # $1 = guard|watchdog|binder, $2 = claude pid
  sh "$SELF" "$1" "$2" </dev/null >/dev/null 2>&1 &
  echo "$!" > "$(f_spid "$1" "$2")"
  log "$1 started (pid $!, claude=$2)"
}
stop_sh() {  # $1 = name, $2 = claude pid; never kills the caller itself
  p=$(read_pid "$(f_spid "$1" "$2")")
  if [ -n "$p" ] && [ "$p" != "$$" ] && kill -0 "$p" 2>/dev/null; then
    kill "$p" 2>/dev/null; log "$1 stopped (pid $p, claude=$2)"
  fi
  rm -f "$(f_spid "$1" "$2")"
  return 0
}
drop_watchdog() { stop_sh watchdog "$1"; stop_keeper bg "$1"; }

# ---- actions ---------------------------------------------------------------

acquire() {
  cpid=$(find_claude_pid) || cpid=
  if ! enabled "$cpid"; then log "disabled; not acquiring (claude=$cpid)"; return 0; fi
  cp=${cpid:-0}
  stop_sh guard "$cp"
  if keeper_alive main "$cp"; then log "already held (claude=$cp)"; return 0; fi
  max=$MAX_SECS; [ "$cp" != 0 ] || max=$FALLBACK_SECS
  start_keeper main "$cp" "$max"
}

waiting() {  # Claude is blocked on the user; let the PC sleep, but watch for a command starting
  cpid=$(find_claude_pid) || cpid=
  stop_keeper main "${cpid:-0}"
  [ -n "$cpid" ] && enabled "$cpid" || return 0
  if sh_alive guard "$cpid"; then log "guard already running (claude=$cpid)"; return 0; fi
  start_sh guard "$cpid"
}

guard() {  # polls until a shell command is running again (re-acquire) or the next hook stops it
  cpid=$1; waited=0
  while claude_alive "$cpid" && [ "$waited" -lt "$GUARD_MAX_SECS" ]; do
    if has_shell_tasks "$cpid"; then
      log "guard: command running again (claude=$cpid); re-acquiring"
      rm -f "$(f_spid guard "$cpid")"
      acquire; return 0
    fi
    sleep "$POLL_SECS"; waited=$((waited + POLL_SECS))
  done
  rm -f "$(f_spid guard "$cpid")"
  log "guard: exiting (claude=$cpid, waited ${waited}s)"
}

binder() {  # WSL only: the keeper cannot see a Linux pid, so stop it when Claude is gone
  cpid=$1
  while kill -0 "$cpid" 2>/dev/null && [ -e "$(f_hold main "$cpid")" ]; do sleep 5; done
  log "binder: claude=$cpid gone or released; stopping keeper"
  stop_keeper main "$cpid"
}

release() {
  cpid=$(find_claude_pid) || cpid=
  stop_keeper main "${cpid:-0}"
  [ -n "$cpid" ] || return 0
  stop_sh guard "$cpid"
  if enabled "$cpid" && [ "$BG_ENABLED" = 1 ] && has_shell_tasks "$cpid"; then
    if sh_alive watchdog "$cpid"; then
      log "background watchdog already running (claude=$cpid)"
    else
      log "background tasks still running ($(shell_task_count "$cpid")); starting watchdog (claude=$cpid, max ${BG_MAX_SECS}s)"
      start_sh watchdog "$cpid"
    fi
  fi
}

watchdog() {  # holds a keeper while the backgrounded shells (and Claude) are alive
  cpid=$1; waited=0
  start_keeper bg "$cpid" "$BG_MAX_SECS"
  while claude_alive "$cpid" && has_shell_tasks "$cpid"; do
    if [ "$BG_MAX_SECS" -gt 0 ] && [ "$waited" -ge "$BG_MAX_SECS" ]; then
      log "watchdog: cap of ${BG_MAX_SECS}s reached (claude=$cpid)"; break
    fi
    sleep 10; waited=$((waited + 10))
  done
  stop_keeper bg "$cpid"
  rm -f "$(f_spid watchdog "$cpid")"
  log "watchdog: exiting (claude=$cpid, waited ${waited}s)"
}

end() {  # $1 = hook payload (SessionEnd carries "reason")
  cpid=$(find_claude_pid) || cpid=
  stop_keeper main "${cpid:-0}"
  [ -z "$cpid" ] || stop_sh guard "$cpid"
  reason=$(printf '%s' "${1:-}" | sed -n 's/.*"reason" *: *"\([^"]*\)".*/\1/p' | head -1)
  if [ "$reason" = clear ]; then
    log "session cleared (claude=$cpid); keeping off switch"; return 0
  fi
  if [ -n "$cpid" ]; then drop_watchdog "$cpid"; rm -f "$(marker "$cpid")" 2>/dev/null; fi
  log "session ended (reason=${reason:-?}, claude=$cpid)"
  return 0
}

on() {
  cpid=$(find_claude_pid) || cpid=
  [ -z "$cpid" ] || rm -f "$(marker "$cpid")" 2>/dev/null
  if [ "${STAY_AWAKE_DISABLED:-0}" = 1 ]; then
    echo "Stay Awake stays OFF: STAY_AWAKE_DISABLED=1 is set in Claude Code's environment. Unset it and restart Claude Code to use the plugin."
    return 0
  fi
  acquire
  if keeper_alive main "${cpid:-0}"; then
    echo "Stay Awake is ON for this session (Claude pid ${cpid:-unknown}). The PC will stay awake while Claude works."
  else
    echo "Stay Awake is ON for this session (Claude pid ${cpid:-unknown}), but no power request could be started. Run /stay-awake:status for details."
  fi
}

off() {
  cpid=$(find_claude_pid) || cpid=
  if [ -n "$cpid" ]; then mkdir -p "$STATE_DIR" 2>/dev/null && echo "$cpid" > "$(marker "$cpid")"; fi
  stop_keeper main "${cpid:-0}"
  if [ -n "$cpid" ]; then stop_sh guard "$cpid"; drop_watchdog "$cpid"; fi
  echo "Stay Awake is OFF for this session (Claude pid ${cpid:-unknown}). The PC may sleep normally, even while Claude works. Run /stay-awake:on to re-enable; it comes back on when Claude Code restarts."
}

status() {
  cpid=$(find_claude_pid) || cpid=
  # A prompt was just submitted, so Claude is about to work: acquire (idempotent).
  [ -n "$cpid" ] && enabled "$cpid" && acquire
  cp=${cpid:-0}
  if [ -n "$cpid" ]; then claude_line="$cpid (via CLAUDE_PID)"; else claude_line="not found (falling back to time-boxed ${FALLBACK_SECS}s requests)"; fi
  if enabled "$cpid"; then en="yes"
  elif [ "${STAY_AWAKE_DISABLED:-0}" = 1 ]; then en="no (STAY_AWAKE_DISABLED=1)"
  else en="no (turned off with /stay-awake:off)"; fi
  if keeper_alive main "$cp"; then held="yes (keeper powershell pid $(keeper_pid main "$cp"))"; else held="no"; fi
  if sh_alive guard "$cp"; then gd="waiting for a command to start (pid $(read_pid "$(f_spid guard "$cp")"))"; else gd="not running"; fi
  if sh_alive watchdog "$cp"; then wd="running (pid $(read_pid "$(f_spid watchdog "$cp")"), keeper pid $(keeper_pid bg "$cp"))"; else wd="not running"; fi
  bg="n/a"; [ -z "$cpid" ] || bg=$(shell_task_count "$cpid")
  echo "Stay Awake status (Windows, $WIN)"
  echo "  Claude process:        $claude_line"
  echo "  Enabled:               $en"
  echo "  Assertion held now:    $held"
  echo "  Guard (waiting on you): $gd"
  echo "  Background watchdog:   $wd"
  echo "  Background Bash tasks: ${bg:-?}"
  req=$(powercfg.exe /requests 2>/dev/null | grep -i -A1 -E '^(SYSTEM|DISPLAY):' | grep -i powershell | sed 's/^ */    /' | cut -c1-120)
  if [ -n "$req" ]; then echo "  powercfg /requests held by Stay Awake:"; echo "$req"
  elif powercfg.exe /requests >/dev/null 2>&1; then echo "  powercfg /requests held by Stay Awake: none"
  else echo "  powercfg /requests: not available (run 'powercfg /requests' in an elevated shell to see them)"; fi
  echo "  Closed-lid mode:       not automated on Windows; see README (powercfg lid action)"
  mh=${STAY_AWAKE_MAX_HOURS:-0}; valid_hours "$mh" || mh="$mh (invalid, using 0)"
  bh=${STAY_AWAKE_BACKGROUND_MAX_HOURS:-4}; valid_hours "$bh" || bh="$bh (invalid, using 4)"
  echo "  Config: FLAGS='${STAY_AWAKE_FLAGS:--i -s}' (display=$DISPLAY_REQ) MAX_HOURS=$mh BACKGROUND=$BG_ENABLED BACKGROUND_MAX_HOURS=$bh DEBUG=${STAY_AWAKE_DEBUG:-0}"
}

# ---- dispatch --------------------------------------------------------------

case "$CMD" in
  acquire|waiting|release|end|start)
    # Hook mode: read the JSON Claude Code sends on stdin, then go silent.
    INPUT=; [ -t 0 ] || INPUT=$(cat 2>/dev/null)
    exec </dev/null >/dev/null 2>&1
    [ -n "$PS" ] || exit 0
    case "$CMD" in
      acquire)
        if printf '%s' "$INPUT" | grep -Eq '"hook_event_name" *: *"PreToolUse"' &&
           printf '%s' "$INPUT" | grep -Eq '"tool_name" *: *"(AskUserQuestion|ExitPlanMode)"'; then
          waiting
        else
          acquire
        fi ;;
      end)   end "$INPUT" ;;
      start) : ;;   # nothing to clean up on Windows (no closed-lid mode)
      *)     "$CMD" ;;
    esac
    exit 0
    ;;
  guard|watchdog|binder)
    exec </dev/null >/dev/null 2>&1
    [ -n "$PID_ARG" ] || exit 0
    "$CMD" "$PID_ARG"
    exit 0
    ;;
  status|on|off)
    if [ -z "$PS" ]; then echo "Stay Awake: powershell.exe not found; cannot hold a power request."; exit 0; fi
    "$CMD"
    exit 0
    ;;
  lid-setup|lid-remove)
    echo "Closed-lid mode is not automated on Windows. To keep a laptop awake with the lid closed, set the lid action to"
    echo "'Do nothing' once, in an elevated PowerShell (this is a permanent power-plan setting, so remember to undo it):"
    echo "  powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0; powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0; powercfg /setactive SCHEME_CURRENT"
    echo "Undo with the same commands and LIDACTION 1 (sleep). Stay Awake then keeps the PC awake while Claude works, lid open or closed."
    exit 0
    ;;
  *)
    echo "usage: $(basename "$SELF") acquire|waiting|release|end|start|status|on|off" >&2
    exit 0
    ;;
esac
