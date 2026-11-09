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
# See "Hook lock" in common.sh for the lock file and stale-lock removal.
HOOK_LOCK_TMP=""

acquire_hook_lock() {
  local tries=0
  HOOK_LOCK_TMP=$(mktemp "${TTS_TMP_DIR}/claude_tts_hook.XXXXXX") || return 1
  echo $$ > "$HOOK_LOCK_TMP"
  while (( tries < 50 )); do
    tries=$((tries + 1))
    if ln "$HOOK_LOCK_TMP" "$TTS_HOOK_LOCK" 2>/dev/null; then
      return 0
    fi
    # The owner died, or its PID now belongs to another program
    if tts_hook_lock_clear_stale; then
      continue
    fi
    sleep 0.1
  done
  return 1
}

release_hook_lock() {
  if [[ "$(cat "$TTS_HOOK_LOCK" 2>/dev/null)" == "$$" ]]; then
    rm -f "$TTS_HOOK_LOCK"
  fi
  rm -f "$HOOK_LOCK_TMP"
  return 0
}

trap release_hook_lock EXIT

# Give up after about 5 s, well inside the hook's 10 s timeout. Drop the
# dedup marker so a retry of this message is not treated as a duplicate.
if ! acquire_hook_lock; then
  rm -rf "$DEDUP_DIR"
  exit 0
fi

# Stop any currently playing TTS before starting new
"${SCRIPT_DIR}/tts-stop.sh" &>/dev/null || true

# Write message to temp file for the worker
TEMP_FILE=$(mktemp "${TTS_TMP_DIR}/claude_tts_msg.XXXXXX")
echo "$MESSAGE" > "$TEMP_FILE"

# Fork background worker
"${SCRIPT_DIR}/tts-worker.sh" "$TEMP_FILE" &>/dev/null & disown
WORKER_PID=$!

# Keep the lock until the worker has written its pid file (up to 2 s), so the
# tts-stop.sh run by the next hook finds this worker and stops it.
WORKER_PID_FILE=$(tts_worker_pid_file "$WORKER_PID")
waits=0
while (( waits < 40 )) && [[ ! -f "$WORKER_PID_FILE" ]] && kill -0 "$WORKER_PID" 2>/dev/null; do
  sleep 0.05
  waits=$((waits + 1))
done

exit 0
