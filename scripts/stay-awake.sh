#!/bin/sh
# Stay Awake for Claude Code
#
# Keeps macOS awake while Claude Code is actively working and lets the Mac
# sleep normally when Claude is idle or waiting for you. Driven by the plugin's
# hooks (hooks/hooks.json) and the /stay-awake:* slash commands.
#
# States
#   acquire  -> start `caffeinate <flags> -w <claude pid>` in the background.
#               `-w` ties the assertion to the Claude Code process, so it dies
#               with Claude even if no hook ever runs again.
#   waiting  -> Claude is blocked on you (permission prompt, question, plan
#               approval): drop the assertion and start a tiny poller ("guard")
#               that re-acquires the moment a shell command starts running.
#   release  -> the turn ended: drop the assertion. If Bash commands Claude
#               backgrounded are still running, a watchdog keeps the Mac awake
#               until they finish (capped by STAY_AWAKE_BACKGROUND_MAX_HOURS).
#   end      -> SessionEnd: release everything.
#   start    -> SessionStart: restore lid sleep a crashed session left disabled.
#
# Closed-lid mode (STAY_AWAKE_LID=1): `caffeinate` cannot stop a MacBook from
# sleeping when the lid is closed. The only switch that can is the system-wide
# `pmset disablesleep`, which needs root. In this mode the hooks turn it on
# while an assertion is held (main or background watchdog) and back off as soon
# as Claude is idle, waiting for you, or gone, through a narrow passwordless
# sudo rule installed once with /stay-awake:lid-setup. A "lidwatch" process
# bound to the Claude pid restores it if Claude crashes.
#
# Rules for hook mode (acquire/waiting/release/end/start):
#   * never write to stdout  (hook stdout can be injected into Claude's context)
#   * never exit non-zero    (a failing hook is shown to the user as an error)
#   * return fast            (hooks block Claude until they exit)
#
# Configuration (environment variables; set them in the "env" block of
# ~/.claude/settings.json or export them before launching Claude Code):
#   STAY_AWAKE_DISABLED=1              inert: never hold an assertion
#   STAY_AWAKE_FLAGS="-i -s"           caffeinate assertion flags (default "-i -s":
#                                         -i prevents idle sleep, -s prevents system
#                                         sleep on AC power). Add -d to also keep the
#                                         display awake, e.g. "-i -s -d".
#   STAY_AWAKE_MAX_HOURS=0             hard cap for one acquire, in hours (decimals
#                                         ok); 0 = until released
#   STAY_AWAKE_BACKGROUND=1            stay awake for Bash tasks Claude backgrounded
#   STAY_AWAKE_BACKGROUND_MAX_HOURS=4  cap for that background watchdog
#   STAY_AWAKE_LID=1                   closed-lid mode (see above; needs /stay-awake:lid-setup)
#   STAY_AWAKE_DEBUG=1                append a log to STAY_AWAKE_LOG
#   STAY_AWAKE_LOG=<path>              default: $TMPDIR/claude-stay-awake/stay-awake.log
#   STAY_AWAKE_STATE_DIR=<dir>         where the per-session off marker (and default log)
#                                      live; default $TMPDIR/claude-stay-awake
#
# Only the main assertion is bound with -w. The background watchdog notices a
# vanished Claude within ~10 s; the rare no-pid fallback is time-boxed (2 h).

set -u

CMD=${1:-}
PID_ARG=${2:-}   # watchdog/guard: the Claude pid (captured before `set --` below)
SELF=$0
case "$(printf '%s' "${STAY_AWAKE_BACKGROUND:-1}" | tr '[:upper:]' '[:lower:]')" in
  0|false|no|off) BG_ENABLED=0 ;;
  *)              BG_ENABLED=1 ;;
esac
case "$(printf '%s' "${STAY_AWAKE_LID:-0}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on) LID_ENABLED=1 ;;
  *)             LID_ENABLED=0 ;;
esac
STATE_DIR=${STAY_AWAKE_STATE_DIR:-"${TMPDIR:-/tmp}/claude-stay-awake"}
LOG_FILE=${STAY_AWAKE_LOG:-"$STATE_DIR/stay-awake.log"}
FALLBACK_SECS=7200      # only used when the Claude pid cannot be determined
GUARD_MAX_SECS=86400    # backstop for the waiting-on-user poller
POLL_SECS=3             # how often the guard looks for a running command
LID_POLL_SECS=5         # how often the lid watcher checks that something is still held
SUDOERS_FILE=/etc/sudoers.d/claude-stay-awake

# Normalise the flag list once, so the string we start caffeinate with and the
# one ps shows are identical (single spaces, no glob expansion).
set -f
# shellcheck disable=SC2086  # word-splitting is the point here
set -- ${STAY_AWAKE_FLAGS:-"-i -s"}
set +f
FLAGS=$*
[ -n "$FLAGS" ] || FLAGS="-i -s"

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

# Print the pid of the Claude Code process this script serves.
# Claude Code exports CLAUDE_PID to hooks and slash-command shells; otherwise
# walk up the process tree to the nearest `claude` binary (or `node .../claude-code/cli.js`).
find_claude_pid() {
  pid=${CLAUDE_PID:-}
  case "$pid" in ''|*[!0-9]*|0|1) pid= ;; esac
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "$pid"; return 0
  fi
  pid=$PPID; depth=0
  while [ "${pid:-0}" -gt 1 ] 2>/dev/null && [ "$depth" -lt 15 ]; do
    args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
    set -f
    # shellcheck disable=SC2086
    set -- $args
    set +f
    case "${1:-}" in */claude|claude) echo "$pid"; return 0 ;; esac
    case "${2:-}" in */claude-code/cli.js|*/claude-code/cli.mjs) echo "$pid"; return 0 ;; esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    depth=$((depth + 1))
  done
  return 1
}

main_args() {  # $1 = claude pid -> caffeinate arguments for a new assertion
  if [ "$MAX_SECS" -gt 0 ]; then
    printf '%s -t %s -w %s' "$FLAGS" "$MAX_SECS" "$1"
  else
    printf '%s -w %s' "$FLAGS" "$1"
  fi
}
# Running assertions are identified by their pid binding, so a change of flags
# or cap between acquire and release cannot make them invisible.
main_pids()     { pgrep -f -- "^caffeinate .*-w $1\$" 2>/dev/null; }
is_held()       { main_pids "$1" >/dev/null; }
fallback_pids() { pgrep -f -- "^caffeinate .*-t $FALLBACK_SECS\$" 2>/dev/null; }
watchdog_pids() { pgrep -f -- "stay-awake\.sh watchdog $1\$" 2>/dev/null; }
guard_pids()    { pgrep -f -- "stay-awake\.sh guard $1\$" 2>/dev/null; }

# /stay-awake:off writes a marker holding the Claude process's start time,
# so a marker left behind by a crashed process is ignored if the pid is reused.
marker()       { printf '%s/disabled-%s' "$STATE_DIR" "$1"; }
claude_start() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'; }
turned_off()   {  # $1 = claude pid
  [ -n "${1:-}" ] && [ -e "$(marker "$1")" ] || return 1
  [ "$(cat "$(marker "$1")" 2>/dev/null)" = "$(claude_start "$1")" ]
}
enabled() {  # $1 = claude pid (may be empty)
  [ "${STAY_AWAKE_DISABLED:-0}" != 1 ] || return 1
  ! turned_off "${1:-}"
}

# Shell commands Claude runs (foreground or background) are children of the
# Claude process whose command line sources ~/.claude/shell-snapshots/snapshot-*.
# The caller's own ancestors are excluded (slash-command bash runs in such a shell).
own_ancestors() {
  p=$$
  while [ "${p:-0}" -gt 1 ] 2>/dev/null; do
    echo "$p"; p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
}
shell_task_count() {  # $1 = claude pid
  ex=$(own_ancestors | paste -s -d ',' -)
  ps -axww -o pid=,ppid=,args= 2>/dev/null | awk -v p="$1" -v ex="$ex," '
    BEGIN { n = split(ex, a, ","); for (i = 1; i <= n; i++) skip[a[i]] = 1 }
    $2 == p && !($1 in skip) && index($0, "shell-snapshots/snapshot-") { c++ }
    END { print c + 0 }'
}
has_shell_tasks() { [ "$(shell_task_count "$1")" -gt 0 ]; }

drop_main() {  # $1 = claude pid (may be empty)
  if [ -n "$1" ]; then
    pkill -f -- "^caffeinate .*-w $1\$" >/dev/null 2>&1 && log "released (claude=$1)"
  else
    pkill -f -- "^caffeinate .*-t $FALLBACK_SECS\$" >/dev/null 2>&1 && log "released fallback"
  fi
  return 0
}
drop_watchdog() {
  [ -n "${1:-}" ] || return 0
  pkill -f -- "stay-awake\.sh watchdog $1\$" >/dev/null 2>&1 && log "stopped background watchdog (claude=$1)"
  return 0
}
drop_guard() {
  [ -n "${1:-}" ] || return 0
  pkill -f -- "stay-awake\.sh guard $1\$" >/dev/null 2>&1 && log "stopped guard (claude=$1)"
  return 0
}

# ---- closed-lid mode -------------------------------------------------------
# `pmset disablesleep` is system-wide, so one global marker is shared by all
# sessions and lid sleep is only restored once no session holds an assertion.
lid_mark()       { printf '%s/lid-disabled' "$STATE_DIR"; }
sleep_disabled() { pmset -g 2>/dev/null | awk '$1 == "SleepDisabled" { print $2; exit }'; }
lid_rule_ok()    { sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1; }
lidwatch_pids()  { pgrep -f -- "stay-awake\.sh lidwatch $1\$" 2>/dev/null; }
# Any Stay Awake assertion held by any session (main or background watchdog).
# This process, its parent and its children are ignored: a watchdog asks this
# as it exits, and its own `caffeinate` wrapper can be either (caffeinate's
# utility form execs the utility in the original process and keeps the
# assertion in a child).
any_held() {
  ex="-e $$ -e $PPID"
  for c in $(pgrep -P "$$" 2>/dev/null); do ex="$ex -e $c"; done
  # shellcheck disable=SC2086  # $ex is a list of -e <pid> options
  { pgrep -f -- '^caffeinate .*-w [0-9][0-9]*$' 2>/dev/null
    pgrep -f -- 'stay-awake\.sh watchdog [0-9][0-9]*$' 2>/dev/null
  } | grep -v -x $ex | grep -q .
}
start_lidwatch() {  # $1 = claude pid
  /bin/sh "$SELF" lidwatch "$1" </dev/null >/dev/null 2>&1 &
  log "lid: watcher pid=$! (claude=$1)"
}
lid_hold() {  # $1 = claude pid; disable lid sleep while an assertion is held
  [ "$LID_ENABLED" = 1 ] && [ -n "${1:-}" ] || return 0
  if [ -e "$(lid_mark)" ]; then
    lidwatch_pids "$1" >/dev/null || start_lidwatch "$1"
    return 0
  fi
  if [ "$(sleep_disabled)" = 1 ]; then log "lid: sleep already disabled system-wide; leaving it alone"; return 0; fi
  if sudo -n /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1; then
    mkdir -p "$STATE_DIR" 2>/dev/null; printf '%s\n' "$1" > "$(lid_mark)"
    log "lid: lid sleep disabled (claude=$1)"
    start_lidwatch "$1"
  else
    log "lid: cannot disable lid sleep; run /stay-awake:lid-setup once (claude=$1)"
  fi
  return 0
}
lid_release() {  # restore lid sleep if we disabled it and nothing is held any more
  [ -e "$(lid_mark)" ] || return 0
  if any_held; then log "lid: an assertion is still held; keeping lid sleep disabled"; return 0; fi
  if sudo -n /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1; then
    rm -f "$(lid_mark)"; log "lid: lid sleep restored"
  else
    log "lid: FAILED to restore lid sleep; run: sudo pmset -a disablesleep 0"
  fi
  for p in $(pgrep -f -- 'stay-awake\.sh lidwatch [0-9][0-9]*$' 2>/dev/null); do
    [ "$p" = "$$" ] || kill "$p" 2>/dev/null
  done
  return 0
}
lidwatch() {  # restores lid sleep when Claude is gone, nothing is held, or a hook already restored it
  cpid=$1; misses=0
  while [ -e "$(lid_mark)" ] && kill -0 "$cpid" 2>/dev/null; do
    if any_held; then misses=0; else misses=$((misses + 1)); [ "$misses" -lt 2 ] || break; fi
    sleep "$LID_POLL_SECS"
  done
  log "lid: watcher exiting (claude=$cpid)"
  lid_release
}
self_path() { printf '%s/%s' "$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)" "$(basename "$SELF")"; }
lid_setup() {
  if [ "$(id -u)" != 0 ]; then
    if lid_rule_ok; then rule="installed"; else rule="NOT installed"; fi
    cat <<EOF
Closed-lid mode keeps the Mac awake with the lid closed (no external display
needed). caffeinate cannot do that; the only switch that can is the system-wide
"pmset disablesleep", which needs root. Stay Awake turns it on only while Claude
is working and back off as soon as Claude is idle, waiting for you, or gone.

The hooks run without a terminal, so this needs a one-time sudo rule that allows
exactly two commands without a password:
    /usr/bin/pmset -a disablesleep 1
    /usr/bin/pmset -a disablesleep 0

  1. In Terminal, run:
       sudo sh "$(self_path)" lid-setup
  2. Add "STAY_AWAKE_LID": "1" to the "env" block of ~/.claude/settings.json.
  3. Restart Claude Code (or run /reload-plugins).

Current state: sudo rule $rule; STAY_AWAKE_LID=${STAY_AWAKE_LID:-unset}; pmset SleepDisabled=$(sleep_disabled).
To undo:       sudo sh "$(self_path)" lid-remove
Caution: a closed MacBook that stays awake gets warm. Do not put it in a bag
while a long task runs, and expect the battery to drain as if it were open.
EOF
    return 0
  fi
  u=${SUDO_USER:-}
  case "$u" in ''|root) echo "Run this with sudo from your normal user account: sudo sh \"$(self_path)\" lid-setup"; return 1 ;; esac
  tmp=$(mktemp "${TMPDIR:-/tmp}/claude-stay-awake-sudoers.XXXXXX") || return 1
  {
    echo "# Installed by the Claude Code Stay Awake plugin (/stay-awake:lid-setup)."
    echo "# Lets the plugin's hooks toggle lid sleep without a password. Remove with:"
    echo "#   sudo sh \"$(self_path)\" lid-remove"
    echo "$u ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
  } > "$tmp"
  if ! visudo -cf "$tmp" >/dev/null; then echo "Generated sudoers rule failed validation; nothing installed."; rm -f "$tmp"; return 1; fi
  install -m 0440 -o root -g wheel "$tmp" "$SUDOERS_FILE" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  echo "Installed $SUDOERS_FILE for user $u."
  echo "Now add \"STAY_AWAKE_LID\": \"1\" to the \"env\" block of ~/.claude/settings.json and restart Claude Code."
}
lid_remove() {
  if [ "$(id -u)" != 0 ]; then
    echo "Run in Terminal:  sudo sh \"$(self_path)\" lid-remove"
    echo "This deletes $SUDOERS_FILE and re-enables lid sleep (pmset -a disablesleep 0)."
    return 0
  fi
  rm -f "$SUDOERS_FILE"
  /usr/bin/pmset -a disablesleep 0
  rm -f "$(lid_mark)" 2>/dev/null
  echo "Removed $SUDOERS_FILE and re-enabled lid sleep. Unset STAY_AWAKE_LID in ~/.claude/settings.json."
}

# ---- actions ---------------------------------------------------------------

acquire() {
  cpid=$(find_claude_pid) || cpid=
  if ! enabled "$cpid"; then log "disabled; not acquiring (claude=$cpid)"; return 0; fi
  drop_guard "$cpid"
  if [ -n "$cpid" ]; then
    if is_held "$cpid"; then log "already held (claude=$cpid)"; lid_hold "$cpid"; return 0; fi
    # shellcheck disable=SC2046  # word-splitting main_args into arguments is intended
    caffeinate $(main_args "$cpid") </dev/null >/dev/null 2>&1 &
    log "acquired: caffeinate pid=$! claude=$cpid args='$(main_args "$cpid")'"
    lid_hold "$cpid"
  else
    if fallback_pids >/dev/null; then log "fallback already held"; return 0; fi
    # shellcheck disable=SC2086
    caffeinate $FLAGS -t "$FALLBACK_SECS" </dev/null >/dev/null 2>&1 &
    log "acquired fallback (no Claude pid found): caffeinate pid=$! for ${FALLBACK_SECS}s"
  fi
}

waiting() {  # Claude is blocked on the user; let the Mac sleep, but watch for a command starting
  cpid=$(find_claude_pid) || cpid=
  drop_main "$cpid"
  lid_release
  [ -n "$cpid" ] && enabled "$cpid" || return 0
  if guard_pids "$cpid" >/dev/null; then log "guard already running (claude=$cpid)"; return 0; fi
  /bin/sh "$SELF" guard "$cpid" </dev/null >/dev/null 2>&1 &
  log "waiting on user: released; guard pid=$! (claude=$cpid)"
}

guard() {  # polls until a shell command is running again (re-acquire) or we are killed by the next hook
  cpid=$1; waited=0
  while kill -0 "$cpid" 2>/dev/null && [ "$waited" -lt "$GUARD_MAX_SECS" ]; do
    if has_shell_tasks "$cpid"; then
      log "guard: command running again (claude=$cpid); re-acquiring"
      acquire; return 0
    fi
    sleep "$POLL_SECS"; waited=$((waited + POLL_SECS))
  done
  log "guard: exiting (claude=$cpid, waited ${waited}s)"
}

release() {
  cpid=$(find_claude_pid) || cpid=
  drop_main "$cpid"
  [ -n "$cpid" ] || { lid_release; return 0; }
  drop_guard "$cpid"
  keep_lid=0
  if enabled "$cpid" && [ "$BG_ENABLED" = 1 ] && has_shell_tasks "$cpid"; then
    keep_lid=1
    if watchdog_pids "$cpid" >/dev/null; then
      log "background watchdog already running (claude=$cpid)"
    else
      # Utility form: the assertion lasts exactly as long as the watchdog runs.
      # shellcheck disable=SC2086
      caffeinate $FLAGS /bin/sh "$SELF" watchdog "$cpid" </dev/null >/dev/null 2>&1 &
      log "background tasks still running ($(shell_task_count "$cpid")); watchdog caffeinate pid=$! (claude=$cpid, max ${BG_MAX_SECS}s)"
    fi
  fi
  # A watchdog started a moment ago may not have exec'd yet, so any_held()
  # could miss it: keep lid sleep disabled whenever a watchdog is wanted.
  [ "$keep_lid" = 1 ] || lid_release
}

watchdog() {  # runs under `caffeinate`; exits when the background tasks (or Claude) are gone
  cpid=$1; waited=0
  while kill -0 "$cpid" 2>/dev/null && has_shell_tasks "$cpid"; do
    if [ "$BG_MAX_SECS" -gt 0 ] && [ "$waited" -ge "$BG_MAX_SECS" ]; then
      log "watchdog: cap of ${BG_MAX_SECS}s reached (claude=$cpid)"; break
    fi
    sleep 10; waited=$((waited + 10))
  done
  log "watchdog: exiting (claude=$cpid, waited ${waited}s)"
  lid_release
}

end() {  # $1 = hook payload (SessionEnd carries "reason")
  cpid=$(find_claude_pid) || cpid=
  drop_main "$cpid"; drop_guard "$cpid"
  reason=$(printf '%s' "${1:-}" | sed -n 's/.*"reason" *: *"\([^"]*\)".*/\1/p' | head -1)
  if [ "$reason" = clear ]; then
    # /clear keeps the same Claude process: keep the user's off switch and let
    # the background watchdog finish on its own (it restores lid sleep itself).
    watchdog_pids "${cpid:-0}" >/dev/null || lid_release
    log "session cleared (claude=$cpid); keeping off switch"; return 0
  fi
  drop_watchdog "$cpid"
  lid_release
  [ -n "$cpid" ] && rm -f "$(marker "$cpid")" 2>/dev/null
  log "session ended (reason=${reason:-?}, claude=$cpid)"
  return 0
}

on() {
  cpid=$(find_claude_pid) || cpid=
  [ -n "$cpid" ] && rm -f "$(marker "$cpid")" 2>/dev/null
  if [ "${STAY_AWAKE_DISABLED:-0}" = 1 ]; then
    echo "Stay Awake stays OFF: STAY_AWAKE_DISABLED=1 is set in Claude Code's environment. Unset it and restart Claude Code to use the plugin."
    return 0
  fi
  acquire; sleep 0.2
  if [ -n "$cpid" ] && is_held "$cpid"; then
    echo "Stay Awake is ON for this session (Claude pid $cpid). The Mac will stay awake while Claude works."
  else
    echo "Stay Awake is ON for this session (Claude pid ${cpid:-unknown}), but no assertion could be started. Run /stay-awake:status for details."
  fi
}

off() {
  cpid=$(find_claude_pid) || cpid=
  if [ -n "$cpid" ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null && claude_start "$cpid" > "$(marker "$cpid")"
  fi
  drop_main "$cpid"; drop_guard "$cpid"; drop_watchdog "$cpid"; lid_release
  echo "Stay Awake is OFF for this session (Claude pid ${cpid:-unknown}). The Mac may sleep normally, even while Claude works. Run /stay-awake:on to re-enable; it comes back on when Claude Code restarts."
}

status() {
  cpid=$(find_claude_pid) || cpid=
  # A slash command's inline bash runs before the UserPromptSubmit hook, but a
  # prompt was just submitted, so Claude is about to work: acquire (idempotent)
  # so the report reflects the state the hooks are about to produce anyway.
  [ -n "$cpid" ] && enabled "$cpid" && acquire
  if [ -n "$cpid" ]; then
    src="CLAUDE_PID"; [ "${CLAUDE_PID:-}" = "$cpid" ] || src="process tree"
    claude_line="$cpid (via $src)"
  else
    claude_line="not found (falling back to time-boxed ${FALLBACK_SECS}s assertions)"
  fi
  if enabled "$cpid"; then en="yes"
  elif [ "${STAY_AWAKE_DISABLED:-0}" = 1 ]; then en="no (STAY_AWAKE_DISABLED=1)"
  else en="no (turned off with /stay-awake:off)"; fi
  if [ -n "$cpid" ]; then mp=$(main_pids "$cpid" | tr '\n' ' '); else mp=$(fallback_pids | tr '\n' ' '); fi
  if [ -n "$mp" ]; then held="yes (caffeinate pid ${mp% })"; else held="no"; fi
  wp=$(watchdog_pids "${cpid:-0}" | tr '\n' ' '); if [ -n "$wp" ]; then wd="running (pids ${wp% })"; else wd="not running"; fi
  gp=$(guard_pids "${cpid:-0}" | tr '\n' ' ');    if [ -n "$gp" ]; then gd="waiting for a command to start (pid ${gp% })"; else gd="not running"; fi
  bg="n/a"; [ -n "$cpid" ] && bg=$(shell_task_count "$cpid")
  echo "Stay Awake status"
  echo "  Claude process:        $claude_line"
  echo "  Enabled:               $en"
  echo "  Assertion held now:    $held"
  for p in $mp; do echo "    caffeinate $p:      $(ps -o args= -p "$p" 2>/dev/null)"; done
  echo "  Guard (waiting on you): $gd"
  echo "  Background watchdog:   $wd"
  echo "  Background Bash tasks: $bg"
  if [ "$LID_ENABLED" = 1 ]; then
    if lid_rule_ok; then lid="on (sudo rule installed)"; else lid="on, but the sudo rule is missing: run /stay-awake:lid-setup"; fi
  else
    lid="off (set STAY_AWAKE_LID=1; see /stay-awake:lid-setup)"
  fi
  sd=$(sleep_disabled); sdby=""
  [ -e "$(lid_mark)" ] && sdby=" (disabled by Stay Awake; restored when Claude is idle)"
  lp=$(lidwatch_pids "${cpid:-0}" | tr '\n' ' '); if [ -n "$lp" ]; then lw="running (pid ${lp% })"; else lw="not running"; fi
  echo "  Closed-lid mode:       $lid"
  echo "  pmset SleepDisabled:   ${sd:-unknown}$sdby"
  echo "  Lid watcher:           $lw"
  allpids=$(printf '%s %s' "$mp" "$wp" | tr ' ' '\n' | grep -E '^[0-9]+$' | paste -s -d '|' -)
  if [ -n "$allpids" ]; then
    echo "  pmset assertions owned by Stay Awake:"
    pmset -g assertions 2>/dev/null | grep -E "pid ($allpids)\(" | sed 's/^ */    /' | cut -c1-120
  else
    echo "  pmset assertions owned by Stay Awake: none"
  fi
  mh=${STAY_AWAKE_MAX_HOURS:-0}; valid_hours "$mh" || mh="$mh (invalid, using 0)"
  bh=${STAY_AWAKE_BACKGROUND_MAX_HOURS:-4}; valid_hours "$bh" || bh="$bh (invalid, using 4)"
  echo "  Config: FLAGS='$FLAGS' MAX_HOURS=$mh BACKGROUND=$BG_ENABLED BACKGROUND_MAX_HOURS=$bh LID=$LID_ENABLED DEBUG=${STAY_AWAKE_DEBUG:-0}"
}

start() {  # SessionStart: a crashed session may have left lid sleep disabled
  if [ -e "$(lid_mark)" ] && [ "$(sleep_disabled)" != 1 ]; then rm -f "$(lid_mark)"; fi  # restored by hand
  lid_release
}

# ---- dispatch --------------------------------------------------------------

case "$CMD" in
  acquire|waiting|release|end|start)
    # Hook mode: read the JSON Claude Code sends on stdin, then go silent.
    INPUT=; [ -t 0 ] || INPUT=$(cat 2>/dev/null)
    exec </dev/null >/dev/null 2>&1
    if [ "$(uname -s 2>/dev/null)" != Darwin ] || ! command -v caffeinate >/dev/null 2>&1; then
      exit 0
    fi
    case "$CMD" in
      acquire)
        # PreToolUse for a tool that blocks on the user is a "waiting" state, not work.
        if printf '%s' "$INPUT" | grep -Eq '"hook_event_name" *: *"PreToolUse"' &&
           printf '%s' "$INPUT" | grep -Eq '"tool_name" *: *"(AskUserQuestion|ExitPlanMode)"'; then
          waiting
        else
          acquire
        fi ;;
      end) end "$INPUT" ;;
      *)   "$CMD" ;;
    esac
    exit 0
    ;;
  watchdog|guard|lidwatch)
    exec </dev/null >/dev/null 2>&1
    [ -n "$PID_ARG" ] || exit 0
    "$CMD" "$PID_ARG"
    exit 0
    ;;
  status|on|off)
    if [ "$(uname -s 2>/dev/null)" != Darwin ] || ! command -v caffeinate >/dev/null 2>&1; then
      echo "Stay Awake: this plugin only works on macOS (caffeinate not found)."; exit 0
    fi
    "$CMD"
    exit 0
    ;;
  lid-setup)  lid_setup ;;
  lid-remove) lid_remove ;;
  *)
    echo "usage: $(basename "$SELF") acquire|waiting|release|end|start|status|on|off|lid-setup|lid-remove" >&2
    exit 0
    ;;
esac
