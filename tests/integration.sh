#!/bin/sh
# End-to-end test: runs real headless Claude Code sessions with this plugin
# loaded via --plugin-dir and checks that a sleep assertion is held while a
# Bash command runs and released afterwards.
#
# Requirements: macOS, an authenticated Claude Code install. Costs a few cents.
#   CLAUDE_BIN=/path/to/claude   (default: `claude` on PATH)
#   CLAUDE_MODEL=haiku           (default)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=${CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}
[ -n "$BIN" ] || { echo "SKIP: claude binary not found (set CLAUDE_BIN)"; exit 2; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/stay-awake-it.XXXXXX"); mkdir -p "$WORK/proj"
SAMPLES=$WORK/samples.txt
fail=0
ok()   { echo "  PASS: $*"; }
bad()  { echo "  FAIL: $*"; fail=1; }

run_claude() {  # $1 = prompt, $2 = output file; hook log goes to $2.log
  LOG=$2.log
  printf '%s' "$1" | (
    cd "$WORK/proj" && env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_MESSAGING_SOCKET \
      -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CLAUDE_CODE_ENTRYPOINT \
      STAY_AWAKE_DEBUG=1 STAY_AWAKE_LOG="$LOG" STAY_AWAKE_STATE_DIR="$WORK/state" \
      "$BIN" -p --plugin-dir "$ROOT" --model "${CLAUDE_MODEL:-haiku}" --max-turns 6 --output-format json \
      --allowedTools "Bash(sleep:*)" "Bash(echo:*)" > "$2" 2> "$2.err"
  )
}
result_of()  { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("result",""))' "$1" 2>/dev/null; }
session_of() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("session_id",""))' "$1" 2>/dev/null; }
transcript_has() {  # $1 = run json, $2 = text: search that session's transcript
  sid=$(session_of "$1"); [ -n "$sid" ] && grep -q -- "$2" "$HOME"/.claude/projects/*/"$sid".jsonl 2>/dev/null; }

echo "== Run 1: assertion held during a Bash command, released after"
( while :; do pgrep -fl '^caffeinate -i -s -w ' >> "$SAMPLES" 2>/dev/null; sleep 0.5; done ) & SAMPLER=$!
run_claude "Use the Bash tool to run exactly this command: sleep 6 && echo stay-awake-ok . When it finishes, reply with exactly DONE." "$WORK/run1.json"; rc=$?
LOG=$WORK/run1.json.log
kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null
[ "$rc" -eq 0 ] && ok "claude exited 0" || bad "claude exited $rc (see $WORK/run1.json.err)"
cpid=$(sed -n 's/.*acquired: caffeinate pid=[0-9]* claude=\([0-9]*\).*/\1/p' "$LOG" 2>/dev/null | head -1)
[ -n "$cpid" ] && ok "hook acquired an assertion for Claude pid $cpid" || bad "no 'acquired' line in $LOG"
grep -q "released (claude=$cpid)" "$LOG" 2>/dev/null && ok "hook released it on Stop/SessionEnd" || bad "no 'released' line in $LOG"
grep -q -- "-w $cpid\$" "$SAMPLES" 2>/dev/null && ok "caffeinate bound to pid $cpid was observed while the session ran" || bad "sampler never saw caffeinate -w $cpid"
if pgrep -f -- "^caffeinate -i -s -w $cpid\$" >/dev/null 2>&1; then bad "caffeinate still running after session exit"; else ok "no caffeinate left after session exit"; fi
transcript_has "$WORK/run1.json" 'stay-awake-ok' && ok "the Bash command actually ran (output is in the transcript)" || bad "command output not found in the session transcript"
n_acq=$(grep -c 'acquired: caffeinate' "$LOG"); [ "$n_acq" -eq 1 ] && ok "exactly one acquire for the turn (PreToolUse was idempotent)" || echo "  NOTE: $n_acq acquires (parallel hooks may race; harmless)"

echo "== Run 2: /stay-awake:status slash command"
run_claude "/stay-awake:status" "$WORK/run2.json"; rc=$?
res=$(result_of "$WORK/run2.json")
echo "$res" | grep -q 'Stay Awake status' && ok "status command expanded" || bad "status output missing; result: $(printf '%s' "$res" | head -c 300)"
echo "$res" | grep -q 'Assertion held now:  *yes' && ok "assertion was held while the command ran" || bad "status did not report a held assertion: $(printf '%s' "$res" | grep -i 'held' | head -1)"

echo "== Run 3: /stay-awake:off, then a fresh session must be enabled again"
run_claude "/stay-awake:off" "$WORK/run3a.json"
res=$(result_of "$WORK/run3a.json"); echo "$res" | grep -qi 'off' && ok "off command ran" || bad "off command output unexpected: $(printf '%s' "$res" | head -c 200)"
# The off marker is per Claude pid and cleared at SessionEnd, so a *new* session must start enabled again:
run_claude "Use the Bash tool to run exactly: sleep 2 && echo again . Then reply DONE." "$WORK/run3b.json"
grep -q 'acquired: caffeinate' "$WORK/run3b.json.log" && ok "a fresh session is enabled again (off is per-session)" || bad "fresh session did not acquire"
grep -q 'disabled; not acquiring' "$WORK/run3a.json.log" && ok "hooks stayed inert for the rest of the off session" || echo "  NOTE: no hook ran after off in run 3a (nothing to check)"

if [ "$fail" -eq 0 ]; then echo "ALL INTEGRATION TESTS PASSED"; rm -rf "$WORK"; exit 0; fi
echo "FAILURES; artifacts kept in $WORK"; exit 1
