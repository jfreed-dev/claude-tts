#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034
# common.sh: path constants and the config reader shared by every script.
# Top level holds only assignments and function definitions, so it is safe
# to source under set -euo pipefail. It depends on nothing else.

TTS_TMP_DIR="${TMPDIR:-/tmp}"
TTS_QUEUE_DIR="${TTS_TMP_DIR}/claude_tts_queue"
TTS_HOOK_LOCK="${TTS_TMP_DIR}/claude_tts_hook.pid"
TTS_HOOK_BREAKER="${TTS_TMP_DIR}/claude_tts_hook.break"
TTS_DAEMON_PID_FILE="${TTS_QUEUE_DIR}/daemon.pid"
TTS_DAEMON_LOCK="${TTS_QUEUE_DIR}/.daemon_lock"
TTS_SEQ_FILE="${TTS_QUEUE_DIR}/.seq"
TTS_SEQ_LOCK="${TTS_QUEUE_DIR}/.lock"
TTS_CLAUDE_DIR="$HOME/.claude"
TTS_ENABLED_FLAG="${TTS_CLAUDE_DIR}/tts-enabled"
TTS_CONFIG_FILE="${TTS_CLAUDE_DIR}/claude-tts.local.md"

# tts_config_get KEY [FILE]: value of the first "KEY:" line, quotes stripped; empty if file/key missing.
# Always returns 0 (safe in X=$(...) and as a bare command under set -euo pipefail). KEY matches [a-z_]+.
tts_config_get() {
  local key="$1" file="${2:-$TTS_CONFIG_FILE}"
  [[ -f "$file" ]] || return 0
  grep "^${key}:" "$file" | head -1 | sed -E "s/^${key}:[[:space:]]*\"?([^\"]*)\"?/\1/" || true
  return 0
}

# tts_load_config: resolve the provider, API key, voice and model from the
# config file and the environment into TTS_CFG_PROVIDER, TTS_CFG_API_KEY,
# TTS_CFG_VOICE_ID and TTS_CFG_MODEL_ID. Always returns 0.
tts_load_config() {
  local legacy_key
  TTS_CFG_PROVIDER=""
  TTS_CFG_API_KEY=""
  TTS_CFG_VOICE_ID=""
  TTS_CFG_MODEL_ID=""

  if [[ -f "$TTS_CONFIG_FILE" ]]; then
    TTS_CFG_PROVIDER=$(tts_config_get provider)
    TTS_CFG_API_KEY=$(tts_config_get api_key)
    TTS_CFG_VOICE_ID=$(tts_config_get voice_id)
    TTS_CFG_MODEL_ID=$(tts_config_get model_id)

    # Legacy migration: elevenlabs_api_key without provider means elevenlabs
    if [[ -z "$TTS_CFG_PROVIDER" ]]; then
      legacy_key=$(tts_config_get elevenlabs_api_key)
      if [[ -n "$legacy_key" ]]; then
        TTS_CFG_PROVIDER="elevenlabs"
        TTS_CFG_API_KEY="$legacy_key"
      fi
    fi
  fi

  # Env var overrides: generic first, then legacy elevenlabs-specific
  if [[ -n "${CLAUDE_TTS_API_KEY:-}" ]]; then
    TTS_CFG_API_KEY="$CLAUDE_TTS_API_KEY"
  elif [[ -n "${ELEVENLABS_API_KEY:-}" && ("$TTS_CFG_PROVIDER" == "elevenlabs" || -z "$TTS_CFG_PROVIDER") ]]; then
    TTS_CFG_API_KEY="$ELEVENLABS_API_KEY"
    if [[ -z "$TTS_CFG_PROVIDER" ]]; then
      TTS_CFG_PROVIDER="elevenlabs"
    fi
  fi

  # Backward compat: map "say" to "local"
  if [[ "$TTS_CFG_PROVIDER" == "say" ]]; then
    TTS_CFG_PROVIDER="local"
  fi

  # Default to local if no provider configured
  if [[ -z "$TTS_CFG_PROVIDER" ]]; then
    TTS_CFG_PROVIDER="local"
  fi
  return 0
}

# --- Process tracking for tts-stop.sh ---
# The daemon records its play subshell in TTS_PLAYER_PID_FILE, and each
# worker records itself in tts_worker_pid_file. Stop kills only these.

TTS_PLAYER_PID_FILE="${TTS_QUEUE_DIR}/player.pid"

# tts_worker_pid_file PID: print the pid file path for the worker PID.
tts_worker_pid_file() {
  printf '%s' "${TTS_QUEUE_DIR}/worker.${1}.pid"
}

# tts_read_pid FILE: print the PID if FILE holds a positive integer, else return 1.
tts_read_pid() {
  local p
  p=$(cat "$1" 2>/dev/null) || return 1
  case "$p" in
    ''|0*|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$p"
}

# tts_pid_matches PID PATTERN: 0 if PID is alive and its command line contains PATTERN.
# No pipeline: grep -q under pipefail gives false negatives through SIGPIPE.
tts_pid_matches() {
  local cmd
  cmd=$(ps -p "$1" -o command= 2>/dev/null) || return 1
  [[ "$cmd" == *"$2"* ]]
}

# --- Hook lock ---
# TTS_HOOK_LOCK is a file holding the PID of the tts-hook.sh that owns it. A
# hook holds it while it stops old audio and starts its worker, and releases
# it on exit. Lock files are written to a temp file and hard-linked into
# place: ln fails if the target exists, so a lock never exists without its
# PID. Hard links rather than symlinks, because Git Bash on Windows copies
# files for ln -s.

# tts_hook_lock_live [FILE]: 0 if FILE (default TTS_HOOK_LOCK) holds the PID
# of a running tts-hook.sh.
tts_hook_lock_live() {
  local pid
  pid=$(tts_read_pid "${1:-$TTS_HOOK_LOCK}") || return 1
  tts_pid_matches "$pid" tts-hook.sh
}

# tts_hook_lock_clear_stale: remove the hook lock if no running tts-hook.sh
# owns it. Returns 0 if it removed one.
# The removal runs under a second lock, TTS_HOOK_BREAKER, held for a few
# milliseconds, and rechecks the hook lock there. While the breaker is held
# the hook lock can only be created (when absent) or released by its live
# owner, so a lock found stale under the breaker is still stale when removed.
# Without the breaker, two hooks could both see the same stale lock and the
# second removal could delete the lock the first had just taken.
tts_hook_lock_clear_stale() {
  local tmp pid removed=1
  [[ -e "$TTS_HOOK_LOCK" ]] || return 1
  tts_hook_lock_live && return 1
  tmp=$(mktemp "${TTS_TMP_DIR}/claude_tts_hook.XXXXXX") || return 1
  echo $$ > "$tmp"
  if ln "$tmp" "$TTS_HOOK_BREAKER" 2>/dev/null; then
    if [[ -e "$TTS_HOOK_LOCK" ]] && ! tts_hook_lock_live; then
      rm -f "$TTS_HOOK_LOCK"
      removed=0
    fi
    rm -f "$TTS_HOOK_BREAKER"
  elif pid=$(tts_read_pid "$TTS_HOOK_BREAKER") &&
    ! tts_pid_matches "$pid" tts-hook.sh && ! tts_pid_matches "$pid" tts-stop.sh; then
    # The breaker's holder died inside those milliseconds. Remove the
    # breaker so the next call can proceed.
    rm -f "$TTS_HOOK_BREAKER"
  fi
  rm -f "$tmp"
  return $removed
}

# tts_kill_tree PID: SIGSTOP PID so it cannot fork, kill its descendants
# depth-first, then SIGTERM and SIGCONT PID. Never signals $$. Returns 0.
tts_kill_tree() {
  local pid="$1" c kids
  if [[ "$pid" == "$$" ]]; then
    return 0
  fi
  kill -STOP "$pid" 2>/dev/null || return 0
  kids=$(pgrep -P "$pid" 2>/dev/null) || true
  for c in $kids; do
    tts_kill_tree "$c"
  done
  kill -TERM "$pid" 2>/dev/null
  kill -CONT "$pid" 2>/dev/null
  return 0
}

# tts_kill_children PID: tts_kill_tree on each direct child of PID. Returns 0.
tts_kill_children() {
  local c kids
  kids=$(pgrep -P "$1" 2>/dev/null) || true
  for c in $kids; do
    tts_kill_tree "$c"
  done
  return 0
}
