#!/bin/sh
# Unit tests for the Windows backend (scripts/stay-awake-windows.sh). Run under
# Git Bash on Windows (CI: windows-latest with `shell: bash`). Uses a fake
# "Claude" PowerShell process, so no real Claude Code session is needed.
#   sh tests/run-tests-windows.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
S="$ROOT/scripts/stay-awake.sh"
export MSYS_NO_PATHCONV=1
PS=$(command -v powershell.exe 2>/dev/null || true)
[ -n "$PS" ] || { echo "SKIP: powershell.exe not found (this suite runs on Windows only)"; exit 2; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/stay-awake-wt.XXXXXX")
unset STAY_AWAKE_DISABLED STAY_AWAKE_FLAGS STAY_AWAKE_MAX_HOURS STAY_AWAKE_BACKGROUND STAY_AWAKE_BACKGROUND_MAX_HOURS STAY_AWAKE_LID
export STAY_AWAKE_STATE_DIR="$WORK/state" STAY_AWAKE_DEBUG=1 STAY_AWAKE_LOG="$WORK/log"
ST="$WORK/state"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $*"; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || bad "$3 (expected '$2', got '$1')"; }
wait_for()  { # $1 = expected, $2 = command producing a value, $3 = max half-seconds
  i=0; while [ "$(eval "$2")" != "$1" ] && [ "$i" -lt "$3" ]; do sleep 0.5; i=$((i + 1)); done; }
win_alive() { [ -n "${1:-}" ] && tasklist.exe /FI "PID eq $1" /NH 2>/dev/null | grep -q "^[^ ]* *$1 "; }
read_pid()  { [ -f "$1" ] || return 0; tr -d ' \r\n' < "$1"; }
keeper()    { p=$(read_pid "$ST/main-keeper-$1.pid"); if win_alive "$p"; then echo 1; else echo 0; fi; }
bgkeeper()  { p=$(read_pid "$ST/bg-keeper-$1.pid"); if win_alive "$p"; then echo 1; else echo 0; fi; }
shalive()   { p=$(read_pid "$ST/$1-$2.pid"); if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo 1; else echo 0; fi; }
# powercfg /requests needs an elevated shell (GitHub runners are elevated); skip those checks otherwise.
if powercfg.exe /requests >/dev/null 2>&1; then REQ_OK=1; else REQ_OK=0; echo "NOTE: powercfg /requests not available (not elevated); those checks will be skipped"; fi
skip_or()  { [ "$REQ_OK" = 1 ] && return 0; echo "  SKIP: $* (powercfg /requests not available)"; return 1; }
requests() { powercfg.exe /requests 2>/dev/null | tr -d '\r' | awk -v s="$1" '$0 == s ":" { on = 1; next } /^[A-Z]+:$/ { on = 0 } on && /powershell/ { c++ } END { print c + 0 }'; }
hook()  { sub=$1; shift; printf '{"session_id":"t","hook_event_name":"Test"}' | env CLAUDE_PID="$FAKE" "$@" sh "$S" "$sub"; }
hookj() { sub=$1; json=$2; shift 2; printf '%s' "$json" | env CLAUDE_PID="$FAKE" "$@" sh "$S" "$sub"; }
cmd()   { sub=$1; shift; env CLAUDE_PID="$FAKE" "$@" sh "$S" "$sub" </dev/null; }

# A controllable fake Claude (a real Windows process): touching $WORK/spawn makes
# it start a child that looks like a Claude Code tool shell (its command line
# mentions shell-snapshots/snapshot-).
cat > "$WORK/fakeclaude.ps1" <<'EOF'
param([string]$Spawn)
while ($true) {
  if (Test-Path -LiteralPath $Spawn) {
    Remove-Item -LiteralPath $Spawn -Force
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-NonInteractive','-Command','Start-Sleep 296 # shell-snapshots/snapshot-unit-test'
  }
  Start-Sleep -Milliseconds 300
}
EOF
FAKE=$("$PS" -NoProfile -NonInteractive -Command "(Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$(cygpath -w "$WORK/fakeclaude.ps1")','$(cygpath -w "$WORK/spawn")').Id" | tr -d ' \r\n')
case "$FAKE" in ''|*[!0-9]*) echo "could not start the fake Claude process: '$FAKE'"; exit 1 ;; esac
tasks()      { "$PS" -NoProfile -NonInteractive -Command "(Get-CimInstance Win32_Process -Filter 'ParentProcessId=$FAKE' | Where-Object { \$_.CommandLine -like '*snapshot-unit-test*' } | Measure-Object).Count" | tr -d ' \r\n'; }
spawn_task() { touch "$WORK/spawn"; wait_for 1 "tasks" 20; }
kill_tasks() { "$PS" -NoProfile -NonInteractive -Command "Get-CimInstance Win32_Process -Filter 'ParentProcessId=$FAKE' | Where-Object { \$_.CommandLine -like '*snapshot-unit-test*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }" >/dev/null 2>&1; sleep 0.5; }
cleanup() {
  kill_tasks
  for f in "$ST"/guard-*.pid "$ST"/watchdog-*.pid "$ST"/binder-*.pid; do p=$(read_pid "$f"); [ -n "$p" ] && kill "$p" 2>/dev/null; done
  for f in "$ST"/*-keeper-*.pid; do p=$(read_pid "$f"); [ -n "$p" ] && taskkill.exe /PID "$p" /F >/dev/null 2>&1; done
  taskkill.exe /PID "$FAKE" /T /F >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM
sleep 0.5; win_alive "$FAKE" && echo "Fake Claude pid: $FAKE" || { echo "fake Claude did not start"; exit 1; }

echo "== hook subcommands are silent and exit 0"
for sub in acquire waiting release end start; do
  out=$(hook "$sub"); rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] && ok "$sub: no stdout, exit 0" || bad "$sub: rc=$rc stdout='$out'"
done
sleep 0.5

echo "== acquire / release"
hook acquire; wait_for 1 "keeper $FAKE" 30
assert_eq "$(keeper "$FAKE")" 1 "acquire starts a keeper bound to the Claude pid (~$((i / 2))s)"
kp=$(read_pid "$ST/main-keeper-$FAKE.pid")
skip_or "powercfg SYSTEM request" && assert_eq "$(requests SYSTEM)" 1 "powercfg /requests shows the keeper's SYSTEM request"
skip_or "no DISPLAY request by default" && assert_eq "$(requests DISPLAY)" 0 "no DISPLAY request by default"
hook acquire; sleep 0.5
assert_eq "$(read_pid "$ST/main-keeper-$FAKE.pid")" "$kp" "second acquire is idempotent (same keeper)"
hook release; wait_for 0 "keeper $FAKE" 10
assert_eq "$(keeper "$FAKE")" 0 "release stops the keeper"
[ ! -e "$ST/main-keeper-$FAKE.pid" ] && ok "release removes the pid file" || bad "pid file still present"
skip_or "request gone" && assert_eq "$(requests SYSTEM)" 0 "the SYSTEM request is gone"

echo "== configuration"
hook acquire STAY_AWAKE_DISABLED=1; sleep 1
assert_eq "$(keeper "$FAKE")" 0 "STAY_AWAKE_DISABLED=1 never acquires"
hook acquire STAY_AWAKE_FLAGS="-i -s -d"; wait_for 1 "keeper $FAKE" 30
assert_eq "$(keeper "$FAKE")" 1 "keeper started with -d"
skip_or "DISPLAY request with -d" && assert_eq "$(requests DISPLAY)" 1 "-d adds a DISPLAY request"
hook release; wait_for 0 "keeper $FAKE" 10
hook acquire STAY_AWAKE_MAX_HOURS=0.001; wait_for 1 "keeper $FAKE" 30
grep -q 'max=3 ' "$WORK/log" && ok "STAY_AWAKE_MAX_HOURS is passed as a cap (0.001h = 3s)" || bad "no max=3 in log: $(grep 'keeper started' "$WORK/log" | tail -1)"
wait_for 0 "keeper $FAKE" 30
assert_eq "$(keeper "$FAKE")" 0 "the keeper exits by itself when the cap is reached (~$((i / 2))s)"
cmd status STAY_AWAKE_BACKGROUND_MAX_HOURS=2h | grep -q 'BACKGROUND_MAX_HOURS=2h (invalid, using 4)' && ok "status flags an invalid BACKGROUND_MAX_HOURS" || bad "status did not flag invalid value"
hook release; wait_for 0 "keeper $FAKE" 10

echo "== off / on / status"
out=$(cmd off); echo "$out" | grep -q 'OFF' && ok "off prints confirmation" || bad "off output: $out"
[ -e "$ST/disabled-$FAKE" ] && ok "off writes a marker" || bad "marker missing"
hook acquire; sleep 1; assert_eq "$(keeper "$FAKE")" 0 "acquire is a no-op while off"
cmd status | grep -q 'turned off with /stay-awake:off' && ok "status explains why it is off" || bad "status did not explain off state"
hookj end '{"hook_event_name":"SessionEnd","reason":"clear"}'
[ -e "$ST/disabled-$FAKE" ] && ok "/clear keeps the off switch" || bad "marker removed on clear"
hookj end '{"hook_event_name":"SessionEnd","reason":"prompt_input_exit"}'
[ ! -e "$ST/disabled-$FAKE" ] && ok "a real SessionEnd removes the marker" || bad "marker survived session end"
cmd off >/dev/null; out=$(cmd on); wait_for 1 "keeper $FAKE" 30
[ ! -e "$ST/disabled-$FAKE" ] && ok "on removes the marker" || bad "marker still present"
assert_eq "$(keeper "$FAKE")" 1 "on acquires immediately"
echo "$out" | grep -q 'is ON' && ok "on confirms" || bad "on output: $out"
st=$(cmd status)
echo "$st" | grep -q "Claude process:  *$FAKE (via CLAUDE_PID)" && ok "status shows the Claude pid" || bad "status pid line: $(echo "$st" | grep 'Claude process')"
echo "$st" | grep -q 'Assertion held now:  *yes (keeper powershell pid' && ok "status reports the held request" || bad "status held line: $(echo "$st" | grep 'held')"
hook release; wait_for 0 "keeper $FAKE" 10

echo "== waiting on the user (permission prompt / AskUserQuestion)"
hook acquire; wait_for 1 "keeper $FAKE" 30
hook waiting; wait_for 0 "keeper $FAKE" 10
assert_eq "$(keeper "$FAKE")" 0 "waiting stops the keeper"
assert_eq "$(shalive guard "$FAKE")" 1 "waiting starts a guard"
gp=$(read_pid "$ST/guard-$FAKE.pid"); hook waiting; sleep 0.5
assert_eq "$(read_pid "$ST/guard-$FAKE.pid")" "$gp" "second waiting does not start a second guard"
spawn_task
wait_for 1 "keeper $FAKE" 40
assert_eq "$(keeper "$FAKE")" 1 "guard re-acquires once a command is running (~$((i / 2))s)"
wait_for 0 "shalive guard $FAKE" 6
assert_eq "$(shalive guard "$FAKE")" 0 "guard exits after re-acquiring"
kill_tasks; hook release; wait_for 0 "keeper $FAKE" 10
hookj acquire '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{}}'; sleep 1
assert_eq "$(keeper "$FAKE")" 0 "PreToolUse for AskUserQuestion is treated as waiting"
assert_eq "$(shalive guard "$FAKE")" 1 "...and starts a guard"
hookj acquire '{"hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","tool_response":{}}'; wait_for 1 "keeper $FAKE" 30
assert_eq "$(keeper "$FAKE")" 1 "PostToolUse (question answered) acquires again"
assert_eq "$(shalive guard "$FAKE")" 0 "...and stops the guard"
hook release; wait_for 0 "keeper $FAKE" 10

echo "== background-task watchdog"
spawn_task
st=$(cmd status); echo "$st" | grep -q 'Background Bash tasks: 1' && ok "status counts the backgrounded shell" || bad "bg count line: $(echo "$st" | grep 'Background Bash')"
hook release; wait_for 1 "bgkeeper $FAKE" 30
assert_eq "$(keeper "$FAKE")" 0 "release stops the main keeper"
assert_eq "$(shalive watchdog "$FAKE")" 1 "release hands off to a watchdog while the background task runs"
assert_eq "$(bgkeeper "$FAKE")" 1 "the watchdog holds its own keeper"
wp=$(read_pid "$ST/watchdog-$FAKE.pid"); hook release; sleep 0.5
assert_eq "$(read_pid "$ST/watchdog-$FAKE.pid")" "$wp" "second release does not start a second watchdog"
kill_tasks
wait_for 0 "bgkeeper $FAKE" 40
assert_eq "$(bgkeeper "$FAKE")" 0 "watchdog releases by itself once the background task ends (~$((i / 2))s)"
spawn_task; hook release; wait_for 1 "bgkeeper $FAKE" 30
assert_eq "$(bgkeeper "$FAKE")" 1 "watchdog started again for a new background task"
hookj end '{"reason":"other"}'; wait_for 0 "bgkeeper $FAKE" 10
assert_eq "$(bgkeeper "$FAKE")" 0 "end (SessionEnd) stops the watchdog immediately"
hook release STAY_AWAKE_BACKGROUND=0; sleep 1
assert_eq "$(shalive watchdog "$FAKE")" 0 "STAY_AWAKE_BACKGROUND=0 disables the watchdog"
kill_tasks

echo "== the keeper dies with the Claude process"
hook acquire; wait_for 1 "keeper $FAKE" 30
assert_eq "$(keeper "$FAKE")" 1 "acquired"
taskkill.exe /PID "$FAKE" /T /F >/dev/null 2>&1
wait_for 0 "keeper $FAKE" 20
assert_eq "$(keeper "$FAKE")" 0 "the keeper exited on its own when the Claude pid died (~$((i / 2))s)"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
