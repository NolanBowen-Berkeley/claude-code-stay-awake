# Stay Awake for Claude Code

[![tests](https://github.com/NolanBowen-Berkeley/claude-code-stay-awake/actions/workflows/test.yml/badge.svg)](https://github.com/NolanBowen-Berkeley/claude-code-stay-awake/actions/workflows/test.yml)

A Claude Code plugin that keeps your Mac awake **while Claude is actually working**
(running a tool, a long shell command, or a command it backgrounded) and lets the
Mac sleep normally as soon as Claude is idle or waiting for you.

It uses macOS's built-in `caffeinate`. No daemons, no dependencies, nothing to
build. macOS only; on other platforms the plugin is inert.

## How it works

Claude Code fires hooks at each stage of a turn. The plugin's hooks call
`scripts/stay-awake.sh`, which starts and stops a `caffeinate` process:

| Claude Code event | What the plugin does |
| --- | --- |
| `UserPromptSubmit` (you send a prompt) | **Acquire**: start `caffeinate -i -s -w <Claude pid>` |
| `PreToolUse` (every tool call, incl. subagents) | Acquire if not already held (idempotent) |
| `PreToolUse` for `AskUserQuestion` / `ExitPlanMode`, or a `permission_prompt` / `elicitation_dialog` / `elicitation_url_dialog` notification (permission prompt or MCP dialog) | **Waiting**: Claude is blocked on you. Drop the assertion and start a tiny poller that checks every few seconds and re-acquires as soon as a shell command is running (so a long command you approve is still covered) |
| `PostToolUse` for `AskUserQuestion` / `ExitPlanMode` (you answered) | Acquire |
| `Stop` / `StopFailure` (the turn ends) | **Release**: stop `caffeinate`. If Bash commands Claude started in the background are still running, a watchdog keeps the Mac awake until they finish |
| `Notification: idle_prompt` (Claude has waited 60s for you) | Release (safety net for turns you interrupted, which fire no `Stop`) |
| `SessionEnd` (`/exit`, window closed) | Release everything and forget `/stay-awake:off`. On `/clear` the off switch is kept |
| Claude Code crashes or is killed | Nothing to do: `caffeinate -w` exits by itself the moment the Claude process is gone |

`-i` prevents idle system sleep. `-s` additionally prevents system sleep while on
AC power. The display is still allowed to sleep by default (see configuration).

## Install

From inside Claude Code:

```
/plugin marketplace add NolanBowen-Berkeley/claude-code-stay-awake
/plugin install stay-awake@claude-code-stay-awake
```

Or from a terminal (needs the `claude` CLI on your PATH; if you only use the
VS Code extension, use the slash-command form above):

```sh
claude plugin marketplace add NolanBowen-Berkeley/claude-code-stay-awake
claude plugin install stay-awake@claude-code-stay-awake
```

Restart Claude Code (or run `/reload-plugins`) so the hooks are loaded.

From a local clone: `/plugin marketplace add /path/to/claude-code-stay-awake`,
then the same `/plugin install stay-awake@claude-code-stay-awake` (the marketplace
name comes from `.claude-plugin/marketplace.json`, not from the path). To try it
for a single session without installing:

```sh
claude --plugin-dir /path/to/claude-code-stay-awake
```

To update later: `/plugin update stay-awake@claude-code-stay-awake` (or
`claude plugin update ...`), then restart Claude Code or run `/reload-plugins`.

## Slash commands

| Command | Effect |
| --- | --- |
| `/stay-awake:status` | Show the plugin state: which `caffeinate` holds the assertion, background tasks, watchdog, config, and the matching `pmset` lines. Because submitting the command is itself a prompt, the assertion is always held while it runs; to observe the idle state use the `pmset` snippet below from another terminal |
| `/stay-awake:off` | Let the Mac sleep normally for the rest of this Claude Code session (survives `/clear`, reset when Claude Code exits) |
| `/stay-awake:on` | Re-enable it |

## Verify it yourself

While Claude is running a command, in another terminal:

```sh
pmset -g assertions | grep -A2 caffeinate
```

You should see `PreventUserIdleSystemSleep` ... `caffeinate asserting on behalf
of Process ID <Claude's pid>`. When Claude finishes its turn the line disappears.

## Configuration

Set environment variables in the `env` block of `~/.claude/settings.json`
(or export them before launching Claude Code):

```json
{
  "env": {
    "STAY_AWAKE_FLAGS": "-i -s -d"
  }
}
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `STAY_AWAKE_FLAGS` | `-i -s` | Flags passed to `caffeinate`. Add `-d` to also keep the display awake. |
| `STAY_AWAKE_MAX_HOURS` | `0` | Hard cap (hours, decimals ok) on one acquire; `0` means "until released". |
| `STAY_AWAKE_BACKGROUND` | `1` | Keep the Mac awake for Bash commands Claude backgrounded, after the turn ends. `0`, `false`, `no` or `off` disables it. |
| `STAY_AWAKE_BACKGROUND_MAX_HOURS` | `4` | Cap for that background watchdog (so a dev server left running doesn't keep the Mac awake forever). `0` means no cap. |
| `STAY_AWAKE_DISABLED` | unset | Set `1` to make the plugin inert without uninstalling it. |
| `STAY_AWAKE_DEBUG` | unset | Set `1` to append a log of every acquire/release. |
| `STAY_AWAKE_LOG` | `$TMPDIR/claude-stay-awake/stay-awake.log` | Where that log goes. |
| `STAY_AWAKE_STATE_DIR` | `$TMPDIR/claude-stay-awake` | Directory for the per-session off marker (and the default log). |

Invalid hour values (for example `2h`) fall back to the default; `/stay-awake:status` points them out.

## Limitations

- **Closing the lid** still sleeps a MacBook. `caffeinate` cannot override that
  (unless the Mac is on power with an external display, i.e. clamshell mode).
- `-s` only applies on AC power; on battery, `-i` still prevents idle sleep.
- If you interrupt Claude mid-turn (Escape / Ctrl+C), Claude Code fires no
  `Stop` hook. The assertion is then released by the `idle_prompt` notification
  (about a minute later), by the end of your next turn, or when Claude exits.
- While Claude waits for a permission answer, the poller only notices *shell*
  commands starting. A long-running non-shell tool approved after a wait runs
  without an assertion until the next tool call; in practice those tools take seconds.
- Parallel tool calls can occasionally start two `caffeinate` processes. Both are
  bound to the Claude pid and both are released together; this is harmless.
- While waiting for you, the poller checks for shell commands every few seconds
  and gives up after 24 hours.
- The background watchdog's `caffeinate` is not bound with `-w`; it notices a
  vanished Claude within about ten seconds.
- Very rarely the Claude pid cannot be determined (no `CLAUDE_PID` in the
  environment and no `claude` or `node .../claude-code/cli.js` ancestor process).
  The plugin then falls back to a two-hour time-boxed assertion, the only kind
  that can outlive Claude Code; in that state the waiting-on-you poller and the
  background watchdog are unavailable.

## Tests

```sh
sh tests/run-tests.sh                                  # unit tests, fake Claude processes, no API usage
CLAUDE_BIN=/path/to/claude sh tests/integration.sh     # real headless Claude sessions (a few cents; needs python3;
                                                       # CLAUDE_BIN defaults to `claude` on PATH)
claude plugin validate . --strict                      # manifest / hooks validation
shellcheck -s sh scripts/stay-awake.sh tests/*.sh      # same lint as CI
```

The integration test loads the plugin with `--plugin-dir`, runs a `sleep 6`
through Claude, samples `pgrep` while it runs, and checks that the assertion
appeared during the command and was gone afterwards. It also exercises the
`/stay-awake:status` and `/stay-awake:off` commands.

## Layout

```
.claude-plugin/plugin.json       plugin manifest
.claude-plugin/marketplace.json  lets this folder be added as a marketplace
hooks/hooks.json                 which events call the script
scripts/stay-awake.sh            all the logic (POSIX sh)
commands/{status,on,off}.md      slash commands
tests/                           unit + integration tests
```

## Uninstall

```
/plugin uninstall stay-awake@claude-code-stay-awake
/plugin marketplace remove claude-code-stay-awake
```

(or the same with `claude plugin ...` from a terminal.)

Any `caffeinate` bound to Claude with `-w` exits on its own when Claude Code exits.
