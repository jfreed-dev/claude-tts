#!/usr/bin/env bash
# tts-hook.sh — Stop hook entry point for Claude TTS plugin.
# Reads the last assistant message and forks a background TTS worker.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Check toggle
if [[ ! -f "$TTS_ENABLED_FLAG" ]]; then
  exit 0
fi

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Extract last assistant message
MESSAGE=$(echo "$HOOK_INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null)
if [[ -z "$MESSAGE" ]]; then
  exit 0
fi

# Content-based deduplication: hash the message and use atomic mkdir to
# prevent the same text from being spoken twice (e.g., if Stop fires twice
# for the same turn, or the plugin is registered in multiple locations).
MSG_HASH=$(printf '%s' "$MESSAGE" | md5 2>/dev/null || printf '%s' "$MESSAGE" | md5sum 2>/dev/null | cut -d' ' -f1)
DEDUP_DIR="${TTS_TMP_DIR}/claude_tts_dedup_${MSG_HASH}"
if ! mkdir "$DEDUP_DIR" 2>/dev/null; then
  # Another invocation already claimed this exact message
  exit 0
fi
# Clean up previous dedup markers (keep only current)
find "${TTS_TMP_DIR}" -maxdepth 1 -name "claude_tts_dedup_*" -not -name "claude_tts_dedup_${MSG_HASH}" -exec rm -rf {} + 2>/dev/null || true

# Hook lock: serializes the stop-then-spawn section below so two hooks
# cannot both start workers. Only a running tts-hook.sh holds it, from here
# until it exits. A hook that finds the lock held waits for it, then stops the
# holder's audio and speaks its own message: the newest reply wins.
acquire_hook_lock() {
  local tries=0 pidless=0
  while (( tries < 50 )); do
    tries=$((tries + 1))
    if mkdir "$TTS_HOOK_LOCK" 2>/dev/null; then
      echo $$ > "$TTS_HOOK_LOCK/pid"
      return 0
    fi
    if tts_hook_lock_live; then
      pidless=0
    elif [[ -f "$TTS_HOOK_LOCK/pid" ]]; then
      # The holder died or its PID now belongs to another program
      rm -rf "$TTS_HOOK_LOCK"
      continue
    else
      # No pid file: the holder may be between mkdir and writing its PID.
      # Treat the lock as abandoned only if it is still missing next poll.
      pidless=$((pidless + 1))
      if (( pidless >= 2 )); then
        rm -rf "$TTS_HOOK_LOCK"
        pidless=0
        continue
      fi
    fi
    sleep 0.1
  done
  return 1
}

release_hook_lock() {
  if [[ "$(cat "$TTS_HOOK_LOCK/pid" 2>/dev/null)" == "$$" ]]; then
    rm -rf "$TTS_HOOK_LOCK"
  fi
  return 0
}

# Give up after about 5 s, well inside the hook's 10 s timeout
acquire_hook_lock || exit 0
trap release_hook_lock EXIT

# Stop any currently playing TTS before starting new
"${SCRIPT_DIR}/tts-stop.sh" &>/dev/null || true

# Write message to temp file for the worker
TEMP_FILE=$(mktemp "${TTS_TMP_DIR}/claude_tts_msg.XXXXXX")
echo "$MESSAGE" > "$TEMP_FILE"

# Fork background worker and exit immediately
"${SCRIPT_DIR}/tts-worker.sh" "$TEMP_FILE" &>/dev/null & disown

exit 0
