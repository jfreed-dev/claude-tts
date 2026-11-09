#!/usr/bin/env bash
# tts-worker.sh — Background worker: clean text, call TTS provider, queue audio.
# Providers are defined in providers.sh; local system TTS is the fallback.
# Usage: tts-worker.sh <temp-message-file>

set -uo pipefail

# Source cross-platform abstraction layer
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/platform.sh"
source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/providers.sh"

TEMP_FILE="${1:-}"
if [[ -z "$TEMP_FILE" || ! -f "$TEMP_FILE" ]]; then
  exit 1
fi

# Register this worker so tts-stop.sh can find and kill it
mkdir -p "$TTS_QUEUE_DIR"
WORKER_PID_FILE=$(tts_worker_pid_file $$)
echo "$$" > "$WORKER_PID_FILE"
# Also remove the message file, in case stop kills the worker before it reads it
trap 'rm -f "$WORKER_PID_FILE" "$TEMP_FILE"; tts_synth_cleanup' EXIT

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
tts_load_config
PROVIDER="$TTS_CFG_PROVIDER"
API_KEY="$TTS_CFG_API_KEY"
VOICE_ID="$TTS_CFG_VOICE_ID"
MODEL_ID="$TTS_CFG_MODEL_ID"

# --- Provider Defaults ---
[[ -z "$VOICE_ID" ]] && VOICE_ID=$(tts_provider_default voice "$PROVIDER")
[[ -z "$MODEL_ID" ]] && MODEL_ID=$(tts_provider_default model "$PROVIDER")

# --- Queue Setup ---
mkdir -p "$TTS_QUEUE_DIR"

acquire_lock() {
  local attempts=0
  while ! mkdir "$TTS_SEQ_LOCK" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [[ $attempts -ge 50 ]]; then
      rm -rf "$TTS_SEQ_LOCK"
    fi
    sleep 0.1
  done
}

release_lock() {
  rm -rf "$TTS_SEQ_LOCK"
}

acquire_lock
SEQ=$(cat "$TTS_SEQ_FILE" 2>/dev/null || echo "0")
SEQ=$((SEQ + 1))
printf "%d" "$SEQ" > "$TTS_SEQ_FILE"
release_lock

SEQ_PADDED=$(printf "%06d" "$SEQ")
AUDIO_FILE=""
USE_FALLBACK=false

tts_local_fallback() {
  if ! check_local_tts; then
    return 1
  fi
  AUDIO_FILE="${TTS_QUEUE_DIR}/${SEQ_PADDED}.wav"
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
  AUDIO_FILE="${TTS_QUEUE_DIR}/${SEQ_PADDED}.$(tts_provider_audio_ext "$PROVIDER")"
  tts_synth "$PROVIDER" "$AUDIO_FILE" "$CLEANED" "$VOICE_ID" "$MODEL_ID" "$API_KEY" || USE_FALLBACK=true
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
DAEMON_RUNNING=false

if [[ -f "$TTS_DAEMON_PID_FILE" ]]; then
  DAEMON_PID=$(cat "$TTS_DAEMON_PID_FILE" 2>/dev/null || echo "0")
  if kill -0 "$DAEMON_PID" 2>/dev/null; then
    DAEMON_RUNNING=true
  else
    rm -f "$TTS_DAEMON_PID_FILE"
  fi
fi

if [[ "$DAEMON_RUNNING" == false ]]; then
  "${SCRIPT_DIR}/tts-queue-daemon.sh" &>/dev/null & disown
fi

# Release hook lock now that audio is queued
rm -rf "$TTS_HOOK_LOCK" 2>/dev/null || true

exit 0
