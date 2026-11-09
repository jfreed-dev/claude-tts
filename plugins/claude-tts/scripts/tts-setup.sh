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
  echo "  elevenlabs  — ElevenLabs TTS (high quality)"
  echo "  openai      — OpenAI TTS"
  echo "  google      — Google Cloud Text-to-Speech"
  echo "  amazon      — Amazon Polly (uses AWS CLI creds)"
  echo "  edge        — Microsoft Edge TTS (free, no key needed)"
  echo "  kitten      — Kitten TTS V0.8 (free, local, no key needed)"
  echo "  mimo        — Xiaomi MiMo-V2-TTS (expressive, free limited time)"
  echo "  tada        — Hume TADA (open-source, GPU recommended, optional voice cloning)"
  echo "  fish        — Fish Audio TTS (high quality, multilingual, voice cloning)"
  echo "  gemini      — Google Gemini 3.1 Flash TTS (70+ languages, multi-speaker)"
  echo "  local       — System built-in TTS (free, no key needed)"
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
  case "$PROVIDER" in
    elevenlabs) echo "Get your key at: https://elevenlabs.io/app/settings/api-keys" ;;
    openai)     echo "Get your key at: https://platform.openai.com/api-keys" ;;
    google)     echo "Get your key at: https://console.cloud.google.com/apis/credentials" ;;
    mimo)       echo "Get your key at: https://platform.xiaomimimo.com/#/console/api-keys" ;;
    fish)       echo "Get your key at: https://fish.audio (Dashboard → API Keys)" ;;
    gemini)     echo "Get your key at: https://aistudio.google.com/apikey" ;;
  esac
  exit 1
fi

# Write config file
mkdir -p "$TTS_CLAUDE_DIR"
if [[ "$PROVIDER" == "local" ]]; then
  cat > "$TTS_CONFIG_FILE" << EOF
---
provider: "local"
---

Claude TTS configuration. Provider: local system TTS.
EOF
elif [[ "$PROVIDER" == "amazon" ]]; then
  cat > "$TTS_CONFIG_FILE" << EOF
---
provider: "amazon"
---

Claude TTS configuration. Provider: Amazon Polly.
Uses AWS CLI credentials (aws configure).
EOF
elif [[ "$PROVIDER" == "edge" ]]; then
  cat > "$TTS_CONFIG_FILE" << EOF
---
provider: "edge"
---

Claude TTS configuration. Provider: Microsoft Edge TTS.
Requires: pip install edge-tts
EOF
elif [[ "$PROVIDER" == "kitten" ]]; then
  cat > "$TTS_CONFIG_FILE" << EOF
---
provider: "kitten"
voice_id: "expr-voice-2-f"
---

Claude TTS configuration. Provider: Kitten TTS V0.8.
Requires: pip install KittenTTS soundfile
System dep: espeak (brew install espeak / apt install espeak)
Voices: expr-voice-2-m, expr-voice-2-f, expr-voice-3-m, expr-voice-3-f, expr-voice-4-m, expr-voice-4-f, expr-voice-5-m, expr-voice-5-f
EOF
elif [[ "$PROVIDER" == "mimo" ]]; then
  cat > "$TTS_CONFIG_FILE" << EOF
---
provider: "mimo"
api_key: "${API_KEY}"
voice_id: "mimo_default"
model_id: "mimo-v2-tts"
---

Claude TTS configuration. Provider: Xiaomi MiMo-V2-TTS.
Voices: mimo_default, default_zh (Chinese female), default_en (English female)
Style: prefix text with <style>Happy</style> etc. for expressive speech.
EOF
elif [[ "$PROVIDER" == "fish" ]]; then
  cat > "$TTS_CONFIG_FILE" << EOF
---
provider: "fish"
api_key: "${API_KEY}"
voice_id: ""
model_id: "s2-pro"
---

Claude TTS configuration. Provider: Fish Audio.
voice_id: reference voice ID (leave empty for default, or use a voice ID from fish.audio)
model_id: s2-pro (flagship) or s2 (faster)
Supports 80+ languages, voice cloning, and emotional tags like [excited] [whisper].
EOF
elif [[ "$PROVIDER" == "gemini" ]]; then
  cat > "$TTS_CONFIG_FILE" << EOF
---
provider: "gemini"
api_key: "${API_KEY}"
voice_id: "Kore"
model_id: "gemini-3.1-flash-tts-preview"
---

Claude TTS configuration. Provider: Google Gemini 3.1 Flash TTS.
voice_id: Kore (default). Available voices: Zephyr, Puck, Charon, Kore, Fenrir, Leda, Orus, Aoede, Callirrhoe, Autonoe, Enceladus, Iapetus, Umbriel, Algieba, Despina, Erinome, Algenib, Rasalgethi, Laomedeia, Achernar, Alnilam, Schedar, Gacrux, Pulcherrima, Achird, Zubenelgenubi, Vindemiatrix, Sadachbia, Sadaltager, Sulafat
model_id: gemini-3.1-flash-tts-preview (latest) or gemini-2.5-flash-preview-tts or gemini-2.5-pro-preview-tts
Supports 70+ languages, multi-speaker dialogue, and audio tags like [whispers] [laughs].
EOF
elif [[ "$PROVIDER" == "tada" ]]; then
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
  cat > "$TTS_CONFIG_FILE" << EOF
---
provider: "tada"
voice_id: "${ref_audio}"
model_id: "tada-1b"
---

Claude TTS configuration. Provider: Hume TADA (open-source voice cloning).
Requires: pip install hume-tada
voice_id: path to reference WAV file (voice to clone)
model_id: tada-1b (English, smaller) or tada-3b-ml (multilingual, larger)
GPU recommended (CUDA or Apple MPS). CPU works but is slow.
EOF
else
  cat > "$TTS_CONFIG_FILE" << EOF
---
provider: "${PROVIDER}"
api_key: "${API_KEY}"
---

Claude TTS configuration. Provider: ${PROVIDER}.
Edit voice_id and model_id above to customize.
EOF
fi

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
