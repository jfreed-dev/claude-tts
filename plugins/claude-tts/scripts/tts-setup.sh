#!/usr/bin/env bash
# tts-setup.sh — Set up Claude TTS plugin with a provider
# Usage: tts-setup.sh <provider> [api-key]

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Source cross-platform abstraction layer
source "${PLUGIN_ROOT}/hooks/scripts/platform.sh"
source "${PLUGIN_ROOT}/hooks/scripts/common.sh"
source "${PLUGIN_ROOT}/hooks/scripts/providers.sh"

PROVIDER="${1:-}"
API_KEY="${2:-}"

# Backward compat: map "say" → "local"
[[ "$PROVIDER" == "say" ]] && PROVIDER="local"

if [[ -z "$PROVIDER" ]]; then
  echo "=== Claude TTS Setup ==="
  echo ""
  echo "Usage: tts-setup <provider> [api-key]"
  echo ""
  echo "Providers:"
  for p in $TTS_PROVIDERS; do printf '  %-12s— %s\n' "$p" "$(tts_provider_summary "$p")"; done
  echo ""
  echo "Examples:"
  echo "  /claude-tts:tts-setup elevenlabs sk_abc123"
  echo "  /claude-tts:tts-setup openai sk-abc123"
  echo "  /claude-tts:tts-setup tada"
  echo "  /claude-tts:tts-setup local"
  exit 1
fi

# Validate provider
if ! tts_provider_is_valid "$PROVIDER"; then
  echo "ERROR: Unknown provider '$PROVIDER'"
  echo "Valid providers: $TTS_PROVIDERS"
  exit 1
fi

# Check jq
if ! command -v jq &>/dev/null; then
  echo "WARNING: jq is not installed. It is required for the TTS hook."
  echo "Install with: $(install_hint jq)"
  echo ""
fi

# Require API key for cloud providers
if tts_provider_needs_key "$PROVIDER" && [[ -z "$API_KEY" ]]; then
  echo "ERROR: API key required for $PROVIDER"
  echo ""
  KEY_URL=$(tts_provider_key_url "$PROVIDER")
  if [[ -n "$KEY_URL" ]]; then echo "Get your key at: $KEY_URL"; fi
  exit 1
fi

# Write config file
mkdir -p "$TTS_CLAUDE_DIR"
CONFIG_VOICE=$(tts_provider_default voice "$PROVIDER")
if [[ "$PROVIDER" == "tada" ]]; then
  # Second arg (API_KEY) is repurposed as reference audio path for TADA
  ref_audio="${API_KEY:-$HOME/.claude/tada-reference.wav}"
  # Generate default reference audio if none provided
  if [[ ! -f "$ref_audio" && "$ref_audio" == "$HOME/.claude/tada-reference.wav" ]]; then
    if check_local_tts; then
      echo "Generating default reference audio..."
      tts_local "The quick brown fox jumps over the lazy dog near the river bank on a warm summer day." "$ref_audio"
      if [[ ! -f "$ref_audio" ]]; then
        echo "WARNING: Could not generate default reference audio."
      fi
    else
      echo "WARNING: No reference audio provided and local TTS unavailable."
      echo "Provide a reference WAV file: /claude-tts:tts-setup tada /path/to/voice.wav"
    fi
  fi
  # Remove stale prompt cache when reference changes
  rm -f "$TTS_TADA_CACHE"
  CONFIG_VOICE="$ref_audio"
fi
{
  echo "---"
  printf 'provider: "%s"\n' "$PROVIDER"
  if tts_provider_needs_key "$PROVIDER"; then printf 'api_key: "%s"\n' "$API_KEY"; fi
  for field in $(tts_provider_config_fields "$PROVIDER"); do
    case "$field" in
      voice) printf 'voice_id: "%s"\n' "$CONFIG_VOICE" ;;
      model) printf 'model_id: "%s"\n' "$(tts_provider_default model "$PROVIDER")" ;;
    esac
  done
  echo "---"
  echo ""
  tts_provider_config_notes "$PROVIDER"
} > "$TTS_CONFIG_FILE"

echo "Config written to: $TTS_CONFIG_FILE"

# Enable TTS
touch "$TTS_ENABLED_FLAG"
echo "TTS enabled with provider: $PROVIDER"

# Make scripts executable
chmod +x "${PLUGIN_ROOT}/hooks/scripts/"*.sh
chmod +x "${PLUGIN_ROOT}/scripts/"*.sh

# Test with sample phrase
echo ""
echo "Testing TTS pipeline..."

mkdir -p "$TTS_QUEUE_DIR"
TEST_TEXT="Claude TTS is now set up and working."
TEST_FILE="${TTS_QUEUE_DIR}/test_setup.$(tts_provider_audio_ext "$PROVIDER")"
TEST_VOICE=$(tts_provider_default voice "$PROVIDER")
TEST_MODEL=$(tts_provider_default model "$PROVIDER")
HTTP_CODE="000"
RUN_TEST=true

test_passed=false

# Setup-only checks and installs before the shared provider call
case "$PROVIDER" in
  amazon)
    if ! command -v aws &>/dev/null; then
      echo "AWS CLI not found. Install with: $(install_hint awscli)"
      RUN_TEST=false
    fi
    ;;
  edge)
    if ! command -v edge-tts &>/dev/null; then
      echo "edge-tts not found. Install with: pip install edge-tts"
      RUN_TEST=false
    fi
    ;;
  kitten)
    # Auto-install espeak system dependency if missing
    if ! command -v espeak &>/dev/null && ! command -v espeak-ng &>/dev/null; then
      echo "Installing espeak (required by Kitten TTS)..."
      case "$CLAUDE_TTS_OS" in
        macos)   brew install espeak 2>/dev/null ;;
        linux)
          if command -v apt-get &>/dev/null; then sudo apt-get install -y espeak-ng 2>/dev/null
          elif command -v dnf &>/dev/null; then sudo dnf install -y espeak-ng 2>/dev/null
          elif command -v pacman &>/dev/null; then sudo pacman -S --noconfirm espeak-ng 2>/dev/null
          fi ;;
      esac
      if ! command -v espeak &>/dev/null && ! command -v espeak-ng &>/dev/null; then
        echo "WARNING: Could not install espeak. Install manually: $(install_hint espeak)"
      else
        echo "espeak: OK"
      fi
    fi
    # Auto-install Python packages if missing
    if ! python3 -c "import kittentts" &>/dev/null; then
      echo "Installing KittenTTS and soundfile..."
      pip install KittenTTS soundfile 2>&1 | tail -1
    fi
    if ! python3 -c "import kittentts" &>/dev/null; then
      echo "ERROR: Failed to install KittenTTS. Try manually: pip install KittenTTS soundfile"
      RUN_TEST=false
    fi
    ;;
  tada)
    # Auto-install hume-tada if missing
    if ! python3 -c "import tada" &>/dev/null; then
      echo "Installing hume-tada (this may take a while, includes PyTorch)..."
      pip install hume-tada 2>&1 | tail -3
    fi
    if ! python3 -c "import tada" &>/dev/null; then
      echo "ERROR: Failed to install hume-tada. Try manually: pip install hume-tada"
      RUN_TEST=false
    elif [[ ! -f "$ref_audio" ]]; then
      echo "ERROR: Reference audio not found at: $ref_audio"
      RUN_TEST=false
    else
      echo "Loading model and generating test audio (first run downloads ~2-4 GB)..."
      TEST_VOICE="$ref_audio"
    fi
    ;;
  local)
    if check_local_tts; then
      tts_local_speak "$TEST_TEXT" && test_passed=true || true
      echo "Local TTS ($CLAUDE_TTS_OS): OK"
      echo ""
      echo "Setup complete!"
      exit 0
    else
      echo "Local TTS: NOT AVAILABLE"
      case "$CLAUDE_TTS_OS" in
        linux)   echo "Install with: $(install_hint espeak-ng)" ;;
        windows) echo "Windows SAPI should be available. Check PowerShell." ;;
      esac
      exit 1
    fi
    ;;
esac

if [[ "$RUN_TEST" == true ]]; then
  # shellcheck disable=SC2034
  TTS_CURL_MAX_TIME=15
  # shellcheck disable=SC2034
  TTS_SYNTH_VERBOSE=1
  tts_synth "$PROVIDER" "$TEST_FILE" "$TEST_TEXT" "$TEST_VOICE" "$TEST_MODEL" "$API_KEY" || true
  HTTP_CODE="$TTS_HTTP_CODE"
fi

if [[ "$HTTP_CODE" == "200" && -f "$TEST_FILE" ]]; then
  FILE_SIZE=$(file_size "$TEST_FILE")
  if [[ "$FILE_SIZE" -gt 1024 ]]; then
    echo "$PROVIDER API: OK (${FILE_SIZE} bytes)"
    if check_audio_player; then
      echo "Playing test audio..."
      play_audio "$TEST_FILE" 2>/dev/null || true
    else
      echo "No audio player found — skipping playback test."
      case "$CLAUDE_TTS_OS" in
        linux) echo "Install with: $(install_hint mpv)" ;;
      esac
    fi
    rm -f "$TEST_FILE"
    echo ""
    echo "Setup complete! TTS is ready."
    exit 0
  fi
fi

rm -f "$TEST_FILE"
echo "$PROVIDER API: FAILED (HTTP ${HTTP_CODE:-000})"
echo "Check your API key and try again."
echo ""

# Fallback test
if check_local_tts; then
  echo "Falling back to local TTS..."
  tts_local_speak "$TEST_TEXT" && echo "Local TTS: OK" || echo "Local TTS: FAILED"
fi

echo ""
echo "Setup complete (with warnings). Check your API key if $PROVIDER didn't work."
exit 0
