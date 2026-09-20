# Stay Awake for Claude Code

[![tests](https://github.com/NolanBowen-Berkeley/claude-code-stay-awake/actions/workflows/test.yml/badge.svg)](https://github.com/NolanBowen-Berkeley/claude-code-stay-awake/actions/workflows/test.yml)

A Claude Code plugin that keeps your Mac awake **while Claude is actually working**
(running a tool, a long shell command, or a command it backgrounded) and lets the
Mac sleep normally as soon as Claude is idle or waiting for you.

On macOS it uses the built-in `caffeinate`; on Windows (and WSL) a tiny hidden
PowerShell process holding a power request. No daemons, no dependencies,
nothing to build. See [Platforms](#platforms) for what works where (short
version: macOS fully, Windows and WSL without closed-lid automation, Chromebooks
not at all).

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
| `SessionStart` | Only in closed-lid mode: re-enable lid sleep if a crashed session left it disabled |

`-i` prevents idle system sleep. `-s` additionally prevents system sleep while on
AC power. The display is still allowed to sleep by default (see configuration).
Closing the lid is a separate mechanism; see [Closed-lid mode](#closed-lid-mode).

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
| `/stay-awake:lid-setup` | Print the one-time setup for [closed-lid mode](#closed-lid-mode) and its current state |

## Closed-lid mode

By default, closing a MacBook's lid still puts it to sleep: `caffeinate` cannot
override the lid (only clamshell mode with power and an external display can).
The one switch that can is the system-wide `pmset disablesleep`, which needs root.

Closed-lid mode turns that switch on **only while Claude is working** (an
assertion is held, or the background watchdog is following a backgrounded
command) and back off the moment Claude is idle, waiting for you, or gone. So
you can start a long task, close the lid, and the Mac stays awake until the
task finishes, then sleeps as usual.

Because hooks run without a terminal, it needs a one-time sudo rule allowing
exactly two commands without a password:
`/usr/bin/pmset -a disablesleep 1` and `/usr/bin/pmset -a disablesleep 0`.

1. Run `/stay-awake:lid-setup` in Claude Code; it prints the exact command,
   which is `sudo sh "<plugin dir>/scripts/stay-awake.sh" lid-setup`. Run that
   in Terminal. It writes `/etc/sudoers.d/claude-stay-awake` for your user
   after checking it with `visudo -c`.
2. Add `"STAY_AWAKE_LID": "1"` to the `env` block of `~/.claude/settings.json`.
3. Restart Claude Code (or `/reload-plugins`). `/stay-awake:status` now shows
   `Closed-lid mode: on (sudo rule installed)`.

Safety nets: a small watcher bound to the Claude pid re-enables lid sleep if
Claude crashes; a `SessionStart` hook re-enables it if the watcher was lost too;
`/stay-awake:status` shows the raw `pmset SleepDisabled` value; and if the
plugin ever finds lid sleep already disabled by you, it leaves it alone. To
undo everything: `sudo sh "<plugin dir>/scripts/stay-awake.sh" lid-remove`.
Manual reset at any time: `sudo pmset -a disablesleep 0`.

**Caution:** a closed MacBook that stays awake gets warm and drains the battery
as if it were open. Do not put it in a bag while a task runs. The setting is
system-wide while active, so with the lid closed the Mac will not sleep for any
reason until Stay Awake restores it.

## Platforms

| Platform | Keep awake while Claude works | Closed lid | Notes |
| --- | --- | --- | --- |
| macOS | yes (`caffeinate`) | yes, opt-in ([closed-lid mode](#closed-lid-mode)) | Fully tested (unit + integration tests) |
| Windows 10/11 (Claude Code with Git for Windows) | yes (`SetThreadExecutionState` via a hidden PowerShell "keeper") | manual one-time power-plan setting | Hooks run through Git Bash, so the same `sh` scripts hand over to `scripts/stay-awake-windows.sh`. Tested in CI on `windows-latest` |
| WSL (Claude Code inside WSL) | yes (same keeper, started through WSL interop) | manual, as above | The keeper is a Windows process; a small watcher inside WSL stops it if Claude dies |
| Linux | no (inert) | no | Nothing to build on: sleep prevention is desktop-specific (`systemd-inhibit`) and laptops rarely run Claude Code unattended there. Contributions welcome |
| Chromebook | **no** | **no** | See below |

**Windows details.** The keeper is `scripts/stay-awake-keeper.ps1`, started
hidden with the same acquire/waiting/release states as on macOS. On native
Windows it also exits by itself when the Claude process is gone (like
`caffeinate -w`); `/stay-awake:status` shows its pid and, from an elevated
shell, `powercfg /requests` lists it under `SYSTEM`. `STAY_AWAKE_FLAGS`
containing `-d` also keeps the display on; the other flags are macOS-only and
ignored. Closing the lid is a Windows power-plan setting that needs an elevated
shell each time it changes, so it is not automated. To keep a laptop awake with
the lid closed, run once in an elevated PowerShell (this is permanent until you
undo it, so a closed laptop in a bag will run hot):

```powershell
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
powercfg /setactive SCHEME_CURRENT
```

`LIDACTION 1` restores "sleep". With that set, Stay Awake keeps the PC awake
while Claude works whether the lid is open or closed, and lets it idle to sleep
normally afterwards.

**Chromebooks.** Claude Code is not supported on ChromeOS itself; it can only
run inside the Linux container (Crostini), and nothing inside that container is
allowed to influence the Chromebook's power management. There is no supported
way to prevent idle sleep from Crostini, and closing the lid always suspends a
Chromebook unless an enterprise policy (`LidCloseAction`) says otherwise. So
this plugin cannot work there. What does work: Google's own "Keep Awake"
Chrome extension keeps the Chromebook awake with the lid open while you have it
enabled (manual, not tied to Claude), and on a managed device an admin can set
the lid-close action.

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
| `STAY_AWAKE_LID` | unset | Set `1` for [closed-lid mode](#closed-lid-mode) (needs the one-time `/stay-awake:lid-setup`). |
| `STAY_AWAKE_DISABLED` | unset | Set `1` to make the plugin inert without uninstalling it. |
| `STAY_AWAKE_DEBUG` | unset | Set `1` to append a log of every acquire/release. |
| `STAY_AWAKE_LOG` | `$TMPDIR/claude-stay-awake/stay-awake.log` | Where that log goes. |
| `STAY_AWAKE_STATE_DIR` | `$TMPDIR/claude-stay-awake` | Directory for the per-session off marker (and the default log). |

Invalid hour values (for example `2h`) fall back to the default; `/stay-awake:status` points them out.

## Limitations

- **Closing the lid** still sleeps a MacBook unless you enable
  [closed-lid mode](#closed-lid-mode), which needs a one-time sudo rule.
  `caffeinate` alone cannot override the lid (except in clamshell mode: on
  power with an external display).
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
sh tests/run-tests.sh                                  # macOS unit tests, fake Claude processes, no API usage
sh tests/run-tests-windows.sh                          # Windows unit tests (run from Git Bash on Windows)
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
scripts/stay-awake.sh            all the macOS logic (POSIX sh); hands over to the Windows backend on Windows/WSL
scripts/stay-awake-windows.sh    Windows/WSL backend (POSIX sh, runs under Git Bash or WSL)
scripts/stay-awake-keeper.ps1    the Windows power-request holder
commands/{status,on,off,lid-setup}.md  slash commands
tests/                           unit tests (macOS and Windows) + macOS integration test
```

## Uninstall

```
/plugin uninstall stay-awake@claude-code-stay-awake
/plugin marketplace remove claude-code-stay-awake
```

(or the same with `claude plugin ...` from a terminal.)

Any `caffeinate` bound to Claude with `-w` (or a Windows keeper watching the
Claude pid) exits on its own when Claude Code exits.
