---
description: Let this Mac sleep normally for the rest of this Claude Code session
allowed-tools: Bash(sh "*/scripts/stay-awake.sh" off)
---
!`sh "${CLAUDE_PLUGIN_ROOT}/scripts/stay-awake.sh" off`

Tell the user, in one sentence, that Stay Awake is now off for this session (the Mac may sleep while Claude works) and that /stay-awake:on turns it back on. Do not run any tools.
