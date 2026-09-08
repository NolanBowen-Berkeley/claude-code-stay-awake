# Changelog

## 1.0.0

- Initial release: holds a `caffeinate` assertion while Claude Code is working,
  releases it when Claude is idle or waiting for you.
- Follows backgrounded Bash commands after the turn ends (capped, configurable).
- `/stay-awake:status`, `/stay-awake:on`, `/stay-awake:off` slash commands.
- Unit tests against fake Claude processes; integration test against real
  headless sessions.
