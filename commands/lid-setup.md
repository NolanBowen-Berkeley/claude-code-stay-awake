---
description: Keep the Mac awake with the lid closed while Claude works (one-time sudo setup)
allowed-tools: Bash(sh "*/scripts/stay-awake.sh" lid-setup)
---
Closed-lid mode setup:

```
!`sh "${CLAUDE_PLUGIN_ROOT}/scripts/stay-awake.sh" lid-setup`
```

Show the block above to the user exactly as-is inside a code block, then at most two plain sentences: the sudo rule only allows the two `pmset` commands shown, and a closed MacBook that stays awake gets warm, so it should not go in a bag while a task runs. Do not run any tools.
