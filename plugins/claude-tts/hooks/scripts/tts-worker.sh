#!/usr/bin/env bash
# tts-worker.sh — Background worker: clean text, call TTS provider, queue audio.
# Providers are defined in providers.sh; local system TTS is the fallback.
# Usage: tts-worker.sh <temp-message-file>

set -uo pipefail

# Source cross-platform abstraction layer
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/platform.sh"
source "${SCRIPT_DIR}/providers.sh"

TEMP_FILE="${1:-}"
if [[ -z "$TEMP_FILE" || ! -f "$TEMP_FILE" ]]; then
  exit 1
fi

RAW_TEXT=$(cat "$TEMP_FILE")
rm -f "$TEMP_FILE"

# --- Text Cleaning ---
CLEANED=$(echo "$RAW_TEXT" | sed -E '
  /^```/,/^```/d
  s/`[^`]+`//g
  s|https?://[^ ]*||g
  s|[[:space:]]/?[a-zA-Z0-9_./-]+\.[a-zA-Z]{1,10}||g
  s/^#{1,6}[[:space:]]+//
  s/\*{1,3}//g
  s/_{1,3}//g
  s/^[[:space:]]*[-*+][[:space:]]+//
  s/^[[:space:]]*[0-9]+\.[[:space:]]+//
  /^[[:space:]]*\|.*[-]{3,}/d
  s/\|/ /g
  s/\[([^]]*)\]\([^)]*\)/\1/g
  s/[[:space:]]+/ /g
')

CLEANED=$(echo "$CLEANED" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ +//; s/ +$//')
CLEANED="${CLEANED:0:5000}"

if [[ ${#CLEANED} -lt 5 ]]; then
  exit 0
fi

# --- Config ---
CONFIG_FILE="$HOME/.claude/claude-tts.local.md"

PROVIDER=""
API_KEY=""
VOICE_ID=""
MODEL_ID=""
REGION=""

# Parse config file
if [[ -f "$CONFIG_FILE" ]]; then
  PROVIDER=$(grep '^provider:' "$CONFIG_FILE" | head -1 | sed -E 's/^provider:[[:space:]]*"?([^"]*)"?/\1/')
  API_KEY=$(grep '^api_key:' "$CONFIG_FILE" | head -1 | sed -E 's/^api_key:[[:space:]]*"?([^"]*)"?/\1/')
  VOICE_ID=$(grep '^voice_id:' "$CONFIG_FILE" | head -1 | sed -E 's/^voice_id:[[:space:]]*"?([^"]*)"?/\1/')
  MODEL_ID=$(grep '^model_id:' "$CONFIG_FILE" | head -1 | sed -E 's/^model_id:[[:space:]]*"?([^"]*)"?/\1/')
  REGION=$(grep '^region:' "$CONFIG_FILE" | head -1 | sed -E 's/^region:[[:space:]]*"?([^"]*)"?/\1/')

  # Legacy migration: elevenlabs_api_key without provider → elevenlabs
  if [[ -z "$PROVIDER" ]]; then
    LEGACY_KEY=$(grep '^elevenlabs_api_key:' "$CONFIG_FILE" | head -1 | sed -E 's/^elevenlabs_api_key:[[:space:]]*"?([^"]*)"?/\1/')
    if [[ -n "$LEGACY_KEY" ]]; then
      PROVIDER="elevenlabs"
      API_KEY="$LEGACY_KEY"
    fi
  fi
fi

# Env var overrides: generic first, then legacy elevenlabs-specific
if [[ -n "${CLAUDE_TTS_API_KEY:-}" ]]; then
  API_KEY="$CLAUDE_TTS_API_KEY"
elif [[ -n "${ELEVENLABS_API_KEY:-}" && ("$PROVIDER" == "elevenlabs" || -z "$PROVIDER") ]]; then
  API_KEY="$ELEVENLABS_API_KEY"
  [[ -z "$PROVIDER" ]] && PROVIDER="elevenlabs"
fi

# Backward compat: map "say" → "local"
[[ "$PROVIDER" == "say" ]] && PROVIDER="local"

# Default to local if no provider configured
[[ -z "$PROVIDER" ]] && PROVIDER="local"

# --- Provider Defaults ---
[[ -z "$VOICE_ID" ]] && VOICE_ID=$(tts_provider_default voice "$PROVIDER")
[[ -z "$MODEL_ID" ]] && MODEL_ID=$(tts_provider_default model "$PROVIDER")
[[ -z "$REGION" ]] && REGION=$(tts_provider_default region "$PROVIDER")

# --- Queue Setup ---
QUEUE_DIR="${TMPDIR:-/tmp}/claude_tts_queue"
mkdir -p "$QUEUE_DIR"

LOCK_DIR="${QUEUE_DIR}/.lock"
SEQ_FILE="${QUEUE_DIR}/.seq"

acquire_lock() {
  local attempts=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [[ $attempts -ge 50 ]]; then
      rm -rf "$LOCK_DIR"
    fi
    sleep 0.1
  done
}

release_lock() {
  rm -rf "$LOCK_DIR"
}

acquire_lock
SEQ=$(cat "$SEQ_FILE" 2>/dev/null || echo "0")
SEQ=$((SEQ + 1))
printf "%d" "$SEQ" > "$SEQ_FILE"
release_lock

SEQ_PADDED=$(printf "%06d" "$SEQ")
AUDIO_FILE=""
USE_FALLBACK=false

tts_local_fallback() {
  if ! check_local_tts; then
    return 1
  fi
  AUDIO_FILE="${QUEUE_DIR}/${SEQ_PADDED}.wav"
  local local_text="${CLEANED:0:2000}"
  tts_local "$local_text" "$AUDIO_FILE"
  if [[ ! -f "$AUDIO_FILE" || $(file_size "$AUDIO_FILE") -lt 100 ]]; then
    rm -f "$AUDIO_FILE"
    return 1
  fi
  return 0
}

# --- Provider Dispatch ---
if [[ "$PROVIDER" != "local" ]] && { [[ -n "$API_KEY" ]] || ! tts_provider_needs_key "$PROVIDER"; }; then
  AUDIO_FILE="${QUEUE_DIR}/${SEQ_PADDED}.$(tts_provider_audio_ext "$PROVIDER")"
  tts_synth "$PROVIDER" "$AUDIO_FILE" "$CLEANED" "$VOICE_ID" "$MODEL_ID" "$REGION" "$API_KEY" || USE_FALLBACK=true
else
  USE_FALLBACK=true
fi

# --- Local TTS Fallback ---
if [[ "$USE_FALLBACK" == true ]]; then
  if ! tts_local_fallback; then
    echo "[claude-tts] All TTS backends failed" >&2
    exit 1
  fi
fi

# --- Start Queue Daemon if Not Running ---
DAEMON_PID_FILE="${QUEUE_DIR}/daemon.pid"
DAEMON_RUNNING=false

if [[ -f "$DAEMON_PID_FILE" ]]; then
  DAEMON_PID=$(cat "$DAEMON_PID_FILE" 2>/dev/null || echo "0")
  if kill -0 "$DAEMON_PID" 2>/dev/null; then
    DAEMON_RUNNING=true
  else
    rm -f "$DAEMON_PID_FILE"
  fi
fi

if [[ "$DAEMON_RUNNING" == false ]]; then
  "${SCRIPT_DIR}/tts-queue-daemon.sh" &>/dev/null & disown
fi

# Release hook lock now that audio is queued
rm -rf "${TMPDIR:-/tmp}/claude_tts_hook.lock" 2>/dev/null || true

exit 0
