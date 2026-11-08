#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034
# common.sh: path constants and the config reader shared by every script.
# Top level holds only assignments and function definitions, so it is safe
# to source under set -euo pipefail. It depends on nothing else.

TTS_TMP_DIR="${TMPDIR:-/tmp}"
TTS_QUEUE_DIR="${TTS_TMP_DIR}/claude_tts_queue"
TTS_HOOK_LOCK="${TTS_TMP_DIR}/claude_tts_hook.lock"
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
