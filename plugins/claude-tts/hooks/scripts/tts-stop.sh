#!/usr/bin/env bash
# tts-stop.sh: stop the audio and synthesis this plugin started and clear the
# queue. Can be called from hooks, commands, or directly.
# It kills only processes recorded in the plugin's pid files (workers, the
# queue daemon and its player), each with all its descendants, after checking
# the command line. It never matches processes by name.
# It prints nothing on stdout: the UserPromptSubmit hook adds hook stdout to
# the model's context.

set -uo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

# stop_registered FILE PATTERN: if FILE holds the PID of a live process whose
# command line contains PATTERN, kill it and its descendants. Remove FILE in
# every case.
stop_registered() {
  local file="$1" pattern="$2" pid
  if [[ ! -f "$file" ]]; then
    return 0
  fi
  if pid=$(tts_read_pid "$file") && tts_pid_matches "$pid" "$pattern"; then
    tts_kill_tree "$pid"
  fi
  rm -f "$file"
}

# Workers (synthesis in progress), with their curl/python3/espeak children
for f in "$TTS_QUEUE_DIR"/worker.*.pid; do
  stop_registered "$f" tts-worker.sh
done

# The queue daemon and its player subtree
stop_registered "$TTS_DAEMON_PID_FILE" tts-queue-daemon.sh

# The player, in case the daemon died without its cleanup. The play subshell
# is a fork of the daemon, so it has the daemon's command line.
stop_registered "$TTS_PLAYER_PID_FILE" tts-queue-daemon.sh

# Remove the daemon lock so a new daemon can start, and the seq lock a killed
# worker may have been holding
rm -rf "$TTS_DAEMON_LOCK" "$TTS_SEQ_LOCK"

# Clear remaining queued audio files and reset sequence counter
# Use find instead of glob to avoid zsh nomatch errors
find "${TTS_QUEUE_DIR}" -maxdepth 1 -type f \( -name "*.mp3" -o -name "*.wav" -o -name ".seq" \) -delete 2>/dev/null || true

# Remove a hook lock left by a hook that died. A live hook holds the lock
# while it runs this script, so leave that one alone.
tts_hook_breaker_clear_stale
tts_hook_lock_clear_stale || true
# Temp PID files from hooks killed before they could delete them. Live ones
# exist for at most a few seconds, so anything over a minute old is orphaned.
find "${TTS_TMP_DIR}" -maxdepth 1 -type f -name 'claude_tts_hook.??????' -mmin +1 -delete 2>/dev/null || true

exit 0
