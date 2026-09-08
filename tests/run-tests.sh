#!/bin/sh
# Unit tests for scripts/stay-awake.sh. Uses fake "Claude" processes, so no
# real Claude Code session (or API usage) is needed. macOS only.
#   sh tests/run-tests.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
S="$ROOT/scripts/stay-awake.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/stay-awake-ut.XXXXXX")
unset STAY_AWAKE_DISABLED STAY_AWAKE_FLAGS STAY_AWAKE_MAX_HOURS STAY_AWAKE_BACKGROUND STAY_AWAKE_BACKGROUND_MAX_HOURS
export STAY_AWAKE_STATE_DIR="$WORK/state" STAY_AWAKE_DEBUG=1 STAY_AWAKE_LOG="$WORK/log"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $*"; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || bad "$3 (expected '$2', got '$1')"; }
held()      { pgrep -f -- "^caffeinate .*-w $1\$" 2>/dev/null | wc -l | tr -d ' '; }
watchdogs() { pgrep -f -- "stay-awake\.sh watchdog $1\$" 2>/dev/null | wc -l | tr -d ' '; }
guards()    { pgrep -f -- "stay-awake\.sh guard $1\$" 2>/dev/null | wc -l | tr -d ' '; }
asserting() { pmset -g assertions 2>/dev/null | grep -c "pid $1(caffeinate)" | tr -d ' '; }
# Some VMs (CI runners) do not report per-process assertions in pmset; probe once
# and turn the pmset-based checks into SKIPs there instead of failures.
PROBE=$( (caffeinate -i -w $$ </dev/null >/dev/null 2>&1 & echo $!) ); sleep 0.3
if pmset -g assertions 2>/dev/null | grep -q "pid $PROBE(caffeinate)"; then PMSET_OK=1; else PMSET_OK=0; fi
kill "$PROBE" 2>/dev/null
[ "$PMSET_OK" = 1 ] || echo "NOTE: pmset does not report caffeinate assertions here; pmset checks will be skipped"
skip_or() { [ "$PMSET_OK" = 1 ] && return 0; echo "  SKIP: $* (pmset does not report assertions here)"; return 1; }
wait_for()  { # $1 = expected, $2 = command producing a value, $3 = max half-seconds
  i=0; while [ "$(eval "$2")" != "$1" ] && [ "$i" -lt "$3" ]; do sleep 0.5; i=$((i + 1)); done; }
# hook <subcommand> [VAR=value ...]: run as Claude Code would (JSON on stdin), print stdout
hook()  { sub=$1; shift; printf '{"session_id":"t","hook_event_name":"Test"}' | env CLAUDE_PID="$FAKE" "$@" sh "$S" "$sub"; }
hookj() { sub=$1; json=$2; shift 2; printf '%s' "$json" | env CLAUDE_PID="$FAKE" "$@" sh "$S" "$sub"; }
cmd()   { sub=$1; shift; env CLAUDE_PID="$FAKE" "$@" sh "$S" "$sub" </dev/null; }

# A controllable fake Claude: touching $WORK/spawn makes it start a child that
# looks like a Claude Code tool shell (its args mention shell-snapshots/snapshot-).
sh -c 'while :; do if [ -e "$1/spawn" ]; then rm -f "$1/spawn"; sh -c "sleep 296; sleep 0 # shell-snapshots/snapshot-unit-test" & fi; sleep 0.3; done' fakeclaude "$WORK" 2>/dev/null &
FAKE=$!
tasks()      { ps -axww -o pid=,ppid=,args= | awk -v p="$FAKE" '$2 == p && /snapshot-unit-test/ { print $1 }'; }
spawn_task() { touch "$WORK/spawn"; wait_for 1 "tasks | wc -l | tr -d ' '" 10; }
kill_tasks() { for t in $(tasks); do kill "$t" 2>/dev/null; done; pkill -xf 'sleep 296' 2>/dev/null; sleep 0.3; }
cleanup() {
  kill_tasks; kill "$FAKE" 2>/dev/null; [ -n "${FAKE3:-}" ] && kill "$FAKE3" 2>/dev/null
  pkill -xf 'sleep 297' 2>/dev/null
  pkill -f -- "^caffeinate .*-w ($FAKE|${FAKE3:-0})\$" 2>/dev/null
  pkill -f -- '^caffeinate -i -s -t 7200$' 2>/dev/null
  pkill -f -- "stay-awake\.sh (watchdog|guard) ($FAKE|${FAKE3:-0})\$" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM
sleep 0.3; echo "Fake Claude pid: $FAKE"

echo "== hook subcommands are silent and exit 0"
for sub in acquire waiting release end; do
  out=$(hook "$sub"); rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] && ok "$sub: no stdout, exit 0" || bad "$sub: rc=$rc stdout='$out'"
done
sleep 0.3

echo "== acquire / release"
hook acquire; sleep 0.3
assert_eq "$(held "$FAKE")" 1 "acquire starts one caffeinate bound to the Claude pid"
cp=$(pgrep -f -- "^caffeinate -i -s -w $FAKE\$" | head -1)
[ -n "$cp" ] && ok "caffeinate runs with the default flags -i -s" || bad "expected 'caffeinate -i -s -w $FAKE'"
skip_or "pmset assertions" && assert_eq "$(asserting "$cp")" 2 "pmset shows the -i and -s assertions for caffeinate pid $cp"
hook acquire; sleep 0.3
assert_eq "$(held "$FAKE")" 1 "second acquire is idempotent"
hook release; sleep 0.3
assert_eq "$(held "$FAKE")" 0 "release kills it"
skip_or "pmset assertion gone" && assert_eq "$(asserting "$cp")" 0 "pmset assertion is gone"

echo "== flags / cap mismatches cannot hide a running assertion"
hook acquire STAY_AWAKE_FLAGS="-i  -s"; hook acquire STAY_AWAKE_FLAGS=" -i -s "; sleep 0.3
assert_eq "$(held "$FAKE")" 1 "irregular whitespace in STAY_AWAKE_FLAGS is normalised (still one process)"
hook release STAY_AWAKE_FLAGS="-i -s -d"; sleep 0.3
assert_eq "$(held "$FAKE")" 0 "release with different flags still finds it"
hook acquire STAY_AWAKE_MAX_HOURS=1; sleep 0.3
assert_eq "$(pgrep -f -- "^caffeinate -i -s -t 3600 -w $FAKE\$" | wc -l | tr -d ' ')" 1 "STAY_AWAKE_MAX_HOURS adds a -t cap"
hook acquire; sleep 0.3
assert_eq "$(held "$FAKE")" 1 "acquire without the cap sees the capped one as held"
hook release; sleep 0.3
assert_eq "$(held "$FAKE")" 0 "release without the cap kills the capped one"

echo "== configuration"
hook acquire STAY_AWAKE_DISABLED=1; sleep 0.3
assert_eq "$(held "$FAKE")" 0 "STAY_AWAKE_DISABLED=1 never acquires"
hook acquire STAY_AWAKE_FLAGS="-i -s -d"; sleep 0.3
cp=$(pgrep -f -- "^caffeinate -i -s -d -w $FAKE\$" | head -1)
[ -n "$cp" ] && ok "custom flags (-d) are passed to caffeinate" || bad "no 'caffeinate -i -s -d -w $FAKE'"
skip_or "display assertion" && { pmset -g assertions | grep "pid $cp(caffeinate)" | grep -q PreventUserIdleDisplaySleep && ok "display-sleep assertion present with -d" || bad "no display assertion"; }
hook release; sleep 0.3
hook acquire STAY_AWAKE_MAX_HOURS=0.5; sleep 0.3
assert_eq "$(pgrep -f -- "^caffeinate -i -s -t 1800 -w $FAKE\$" | wc -l | tr -d ' ')" 1 "decimal hours work (0.5h = -t 1800)"
hook release; sleep 0.3
hook acquire STAY_AWAKE_MAX_HOURS=abc; sleep 0.3
assert_eq "$(pgrep -f -- "^caffeinate -i -s -w $FAKE\$" | wc -l | tr -d ' ')" 1 "invalid MAX_HOURS falls back to the default (no cap)"
hook release; sleep 0.3
cmd status STAY_AWAKE_BACKGROUND_MAX_HOURS=2h | grep -q 'BACKGROUND_MAX_HOURS=2h (invalid, using 4)' && ok "status flags an invalid BACKGROUND_MAX_HOURS" || bad "status did not flag invalid value"
hook release; sleep 0.3

echo "== off / on (per-session switch)"
out=$(cmd off); echo "$out" | grep -q 'OFF' && ok "off prints confirmation" || bad "off output: $out"
[ -s "$WORK/state/disabled-$FAKE" ] && ok "off writes a marker holding the process start time" || bad "marker missing/empty"
hook acquire; sleep 0.3; assert_eq "$(held "$FAKE")" 0 "acquire is a no-op while off"
cmd status | grep -q 'turned off with /stay-awake:off' && ok "status explains why it is off" || bad "status did not explain off state"
hookj end '{"hook_event_name":"SessionEnd","reason":"clear"}'
[ -e "$WORK/state/disabled-$FAKE" ] && ok "/clear (SessionEnd reason=clear) keeps the off switch" || bad "marker removed on clear"
hookj end '{"hook_event_name":"SessionEnd","reason":"prompt_input_exit"}'
[ ! -e "$WORK/state/disabled-$FAKE" ] && ok "a real SessionEnd removes the marker" || bad "marker survived session end"
echo "bogus start time" > "$WORK/state/disabled-$FAKE"
hook acquire; sleep 0.3; assert_eq "$(held "$FAKE")" 1 "a stale marker from a previous process with the same pid is ignored"
hook release; sleep 0.3
cmd off >/dev/null; out=$(cmd on); sleep 0.3
[ ! -e "$WORK/state/disabled-$FAKE" ] && ok "on removes the marker" || bad "marker still present"
assert_eq "$(held "$FAKE")" 1 "on acquires immediately"
echo "$out" | grep -q 'is ON' && ok "on confirms" || bad "on output: $out"
out=$(cmd on STAY_AWAKE_DISABLED=1); echo "$out" | grep -q 'stays OFF' && ok "on explains STAY_AWAKE_DISABLED=1" || bad "on output: $out"
hook release; sleep 0.3

echo "== status"
hook acquire; sleep 0.3
st=$(cmd status)
echo "$st" | grep -q "Claude process:  *$FAKE (via CLAUDE_PID)" && ok "status shows the Claude pid" || bad "status pid line: $(echo "$st" | grep 'Claude process')"
echo "$st" | grep -q 'Assertion held now:  *yes' && ok "status reports the held assertion" || bad "status held line: $(echo "$st" | grep 'held')"
echo "$st" | grep -q "caffeinate -i -s -w $FAKE" && ok "status shows the caffeinate command line" || bad "no caffeinate args line"
skip_or "status pmset line" && { echo "$st" | grep -q 'PreventUserIdleSystemSleep' && ok "status lists the pmset assertion" || bad "status has no pmset line"; }
hook release; sleep 0.3

echo "== waiting on the user (permission prompt / AskUserQuestion)"
hook acquire; sleep 0.3
hook waiting; sleep 0.3
assert_eq "$(held "$FAKE")" 0 "waiting drops the assertion"
[ "$(guards "$FAKE")" -ge 1 ] && ok "waiting starts a guard" || bad "no guard running"
hook waiting; sleep 0.3
[ "$(guards "$FAKE")" -le 1 ] && ok "second waiting does not start a second guard" || bad "guards: $(guards "$FAKE")"
spawn_task
wait_for 1 "held $FAKE" 16
assert_eq "$(held "$FAKE")" 1 "guard re-acquires once a command is running (~$((i / 2))s)"
wait_for 0 "guards $FAKE" 6
assert_eq "$(guards "$FAKE")" 0 "guard exits after re-acquiring"
kill_tasks; hook release; sleep 0.3
hookj acquire '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{}}'; sleep 0.3
assert_eq "$(held "$FAKE")" 0 "PreToolUse for AskUserQuestion is treated as waiting"
[ "$(guards "$FAKE")" -ge 1 ] && ok "...and starts a guard" || bad "no guard"
hookj acquire '{"hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","tool_response":{}}'; sleep 0.3
assert_eq "$(held "$FAKE")" 1 "PostToolUse (question answered) acquires again"
assert_eq "$(guards "$FAKE")" 0 "...and stops the guard"
hook waiting; sleep 0.3; hook release; sleep 0.3
assert_eq "$(guards "$FAKE")" 0 "release stops the guard"
hook waiting STAY_AWAKE_DISABLED=1; sleep 0.3
assert_eq "$(guards "$FAKE")" 0 "no guard when disabled"

echo "== background-task watchdog"
spawn_task
st=$(cmd status); echo "$st" | grep -q 'Background Bash tasks: 1' && ok "status counts the backgrounded shell" || bad "bg count line: $(echo "$st" | grep 'Background Bash')"
hook release; sleep 0.5
assert_eq "$(held "$FAKE")" 0 "release drops the main assertion"
[ "$(watchdogs "$FAKE")" -ge 1 ] && ok "release hands off to a watchdog while the background task runs" || bad "no watchdog started"
wcp=$(pgrep -f -- "^caffeinate -i -s /bin/sh .*stay-awake\.sh watchdog $FAKE\$" | head -1)
[ -n "$wcp" ] && ok "watchdog runs under caffeinate (pid $wcp)" || bad "watchdog caffeinate not found"
skip_or "watchdog assertion" && { [ "$(asserting "$wcp")" -ge 1 ] && ok "watchdog caffeinate holds an assertion" || bad "watchdog assertion missing"; }
hook release; sleep 0.3
[ "$(watchdogs "$FAKE")" -le 2 ] && ok "second release does not start a second watchdog" || bad "duplicate watchdogs: $(watchdogs "$FAKE")"
kill_tasks
wait_for 0 "watchdogs $FAKE" 30
assert_eq "$(watchdogs "$FAKE")" 0 "watchdog exits by itself once the background task ends (~$((i / 2))s)"
spawn_task; hook release; sleep 0.5
[ "$(watchdogs "$FAKE")" -ge 1 ] && ok "watchdog started again for a new background task" || bad "no watchdog"
hookj end '{"reason":"clear"}'; sleep 0.3
[ "$(watchdogs "$FAKE")" -ge 1 ] && ok "/clear leaves the watchdog to finish on its own" || bad "watchdog killed on clear"
hookj end '{"reason":"other"}'; sleep 0.5
assert_eq "$(watchdogs "$FAKE")" 0 "end (SessionEnd) stops the watchdog immediately"
hook release STAY_AWAKE_BACKGROUND=0; sleep 0.5
assert_eq "$(watchdogs "$FAKE")" 0 "STAY_AWAKE_BACKGROUND=0 disables the watchdog"
kill_tasks

echo "== -w: assertion dies with the Claude process"
sleep 297 & FAKE3=$!
printf '{}' | env CLAUDE_PID="$FAKE3" sh "$S" acquire; sleep 0.3
assert_eq "$(held "$FAKE3")" 1 "acquired for a second fake Claude"
kill "$FAKE3"; sleep 1.5
assert_eq "$(held "$FAKE3")" 0 "caffeinate exited on its own when the Claude pid died"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
