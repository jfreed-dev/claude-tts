#!/usr/bin/env bash
# tts-status.sh: print the Claude TTS plugin status for /tts-status.
# Usage: tts-status.sh

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

source "${PLUGIN_ROOT}/hooks/scripts/platform.sh"
source "${PLUGIN_ROOT}/hooks/scripts/common.sh"
source "${PLUGIN_ROOT}/hooks/scripts/providers.sh"

echo "=== Claude TTS Status ==="
echo ""

if [[ -f "$TTS_ENABLED_FLAG" ]]; then
  echo "TTS:      ENABLED"
else
  echo "TTS:      DISABLED"
fi

# Show the configured provider as written, not the resolved one. A legacy
# config is one with a non-empty elevenlabs_api_key and no provider, the same
# rule the worker uses.
PROVIDER="(not configured)"
if [[ -f "$TTS_CONFIG_FILE" ]]; then
  CONFIGURED=$(tts_config_get provider)
  if [[ -n "$CONFIGURED" ]]; then
    PROVIDER="$CONFIGURED"
  elif [[ -n "$(tts_config_get elevenlabs_api_key)" ]]; then
    PROVIDER="elevenlabs (legacy config)"
  fi
fi
echo "Provider: $PROVIDER"

if [[ -n "${CLAUDE_TTS_API_KEY:-}" ]]; then
  echo "API Key:  Set (CLAUDE_TTS_API_KEY env var)"
elif [[ -n "${ELEVENLABS_API_KEY:-}" ]]; then
  echo "API Key:  Set (ELEVENLABS_API_KEY env var)"
elif [[ -n "$(tts_config_get api_key)" ]]; then
  echo "API Key:  Set (config file)"
elif [[ -n "$(tts_config_get elevenlabs_api_key)" ]]; then
  echo "API Key:  Set (config file, legacy)"
elif [[ "$PROVIDER" == "say" ]] || ! tts_provider_needs_key "$PROVIDER"; then
  echo "API Key:  Not needed"
else
  echo "API Key:  NOT SET"
fi

if command -v jq &>/dev/null; then
  echo "jq:       Installed ($(jq --version 2>&1))"
else
  echo "jq:       NOT FOUND (required! see: https://jqlang.github.io/jq/download/)"
fi

echo "Platform: $(uname -s)"

if [[ -f "$TTS_DAEMON_PID_FILE" ]]; then
  PID=$(cat "$TTS_DAEMON_PID_FILE")
  if kill -0 "$PID" 2>/dev/null; then
    echo "Daemon:   Running (PID $PID)"
  else
    echo "Daemon:   Stale PID file (not running)"
  fi
else
  echo "Daemon:   Not running (starts automatically)"
fi

QUEUED=$(ls -1 "$TTS_QUEUE_DIR"/*.mp3 "$TTS_QUEUE_DIR"/*.wav 2>/dev/null | wc -l | tr -d ' ')
echo "Queued:   $QUEUED audio file(s)"
