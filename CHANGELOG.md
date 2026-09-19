# Changelog

## 1.1.0

- Closed-lid mode (`STAY_AWAKE_LID=1`): keeps a MacBook awake with the lid
  closed by disabling lid sleep (`pmset disablesleep`) only while Claude is
  working, through a narrow passwordless sudo rule installed once with
  `/stay-awake:lid-setup`. Restored as soon as Claude is idle, waiting for you,
  or gone; a watcher restores it if Claude crashes, and a `SessionStart` hook
  cleans up after a crash.
- `/stay-awake:status` shows the closed-lid state.
- CI: silence ShellCheck SC2329 for the indirectly dispatched functions and
  validate the plugin manifest as well as the marketplace manifest.

## 1.0.0

- Initial release: holds a `caffeinate` assertion while Claude Code is working,
  releases it when Claude is idle or waiting for you.
- Follows backgrounded Bash commands after the turn ends (capped, configurable).
- `/stay-awake:status`, `/stay-awake:on`, `/stay-awake:off` slash commands.
- Unit tests against fake Claude processes; integration test against real
  headless sessions.
