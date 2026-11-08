#!/usr/bin/env bash
# tts-queue-daemon.sh — Persistent audio queue player.
# Plays queued audio files sequentially, exits after 30s idle.

set -uo pipefail

# Source cross-platform abstraction layer and shared paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/platform.sh"
source "${SCRIPT_DIR}/common.sh"

mkdir -p "$TTS_QUEUE_DIR"

# Ensure only one daemon instance runs at a time (atomic lock)
if ! mkdir "$TTS_DAEMON_LOCK" 2>/dev/null; then
  exit 0
fi

echo $$ > "$TTS_DAEMON_PID_FILE"

cleanup() {
  # Kill the whole subtree: the play subshell and the audio player under it
  tts_kill_children $$
  rm -f "$TTS_PLAYER_PID_FILE"
  # Remove the pid file, lock and queued audio only while the pid file still
  # names this daemon, so a late cleanup cannot undo a newer daemon's state
  if [[ "$(tts_read_pid "$TTS_DAEMON_PID_FILE")" == "$$" ]]; then
    rm -f "$TTS_DAEMON_PID_FILE"
    rm -rf "$TTS_DAEMON_LOCK"
    # Clear remaining queued audio files (use find to avoid zsh glob issues)
    find "${TTS_QUEUE_DIR}" -maxdepth 1 -type f \( -name "*.mp3" -o -name "*.wav" \) -delete 2>/dev/null || true
  fi
}
# A TERM or INT trap without exit would resume the loop, so exit explicitly;
# the EXIT trap then runs cleanup.
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

IDLE=0

while true; do
  # Find the next audio file (mp3 or wav, sorted by name for sequence order)
  NEXT=$(ls -1 "${TTS_QUEUE_DIR}/"*.mp3 "${TTS_QUEUE_DIR}/"*.wav 2>/dev/null | sort | head -1 || true)

  if [[ -n "$NEXT" && -f "$NEXT" ]]; then
    IDLE=0
    # Play audio in background so signals can interrupt it
    play_audio "$NEXT" 2>/dev/null &
    PLAY_PID=$!
    echo "$PLAY_PID" > "$TTS_PLAYER_PID_FILE"
    wait "$PLAY_PID" 2>/dev/null || true
    rm -f "$TTS_PLAYER_PID_FILE"
    # Remove after playing
    rm -f "$NEXT"
  else
    IDLE=$((IDLE + 1))
    sleep 1
    # Exit after 30 seconds idle
    if [[ $IDLE -ge 30 ]]; then
      exit 0
    fi
  fi
done
