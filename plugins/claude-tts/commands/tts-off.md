---
description: Disable text-to-speech for Claude responses
allowed-tools: [Bash]
---

Run this exact command:

```bash
rm -f ~/.claude/tts-enabled && bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/tts-stop.sh" && echo "TTS disabled. Claude responses will no longer be spoken."
```
