#!/usr/bin/env bash
# capture-requests.sh: run tts-worker.sh, tts-setup.sh and the /tts-status
# command against stubbed commands and print a normalized transcript of
# every external request.
# Usage: capture-requests.sh [--update | --split DIR]
#   (no argument)  print the transcript
#   --split DIR    write DIR/scenarios.txt and DIR/scenarios/<slug>.log
#   --update       rewrite tests/golden the same way
#
# All external commands that could reach the network or change the system
# (curl, aws, edge-tts, python3 model scripts, package managers) are stubs.
# pkill and killall are stubs that log UNEXPECTED, so name-based killing
# shows up in the transcript instead of reaching the real system.
# Each script runs under env -i, so real API keys never reach it.

set -uo pipefail
export LC_ALL=C

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
WORKER="${REPO_ROOT}/plugins/claude-tts/hooks/scripts/tts-worker.sh"
SETUP="${REPO_ROOT}/plugins/claude-tts/scripts/tts-setup.sh"
PLUGIN_ROOT="${REPO_ROOT}/plugins/claude-tts"
STATUS_MD="${PLUGIN_ROOT}/commands/tts-status.md"
GOLDEN_DIR="${TESTS_DIR}/golden"
REAL_PYTHON3="$(command -v python3)"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tts-capture.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
STUBS="${ROOT}/stubs"
RESPONSE="${ROOT}/response.json"
TINY="${ROOT}/tiny.json"
NONJSON="${ROOT}/nonjson.html"
mkdir -p "$STUBS"

MESSAGE='# Build summary

Here is **bold** and _italic_ text with `inline code` and a [docs link](https://example.com/docs).

- First item done
- Second item done

1. Numbered step one
Details at https://example.com/path for later.'

# --- Fixtures ---
# RESPONSE: one JSON response that satisfies every provider.
# TINY: the same JSON paths, each holding a 3-byte payload.
# NONJSON: 2 KB of HTML returned with HTTP 200.
build_fixture() {
  local blob fmt
  fmt='{"audioContent":"%s","choices":[{"message":{"audio":{"data":"%s"}}}],"candidates":[{"content":{"parts":[{"inlineData":{"data":"%s"}}]}}]}\n'
  blob=$(head -c 2048 /dev/zero | tr '\0' 'A' | base64 | tr -d '\n')
  # shellcheck disable=SC2059
  printf "$fmt" "$blob" "$blob" "$blob" > "$RESPONSE"
  # shellcheck disable=SC2059
  printf "$fmt" QUFB QUFB QUFB > "$TINY"
  {
    printf '<!DOCTYPE html>\n<html><body><p>\n'
    head -c 2048 /dev/zero | tr '\0' 'x'
    printf '\n</p></body></html>\n'
  } > "$NONJSON"
}

# --- Stubs ---
build_stubs() {
  cat > "${STUBS}/curl" <<'EOF'
#!/bin/bash
{ echo "=== curl"; for a in "$@"; do printf '[%s]\n' "$a"; done; } >> "$STUB_LOG"
if [[ -n "${STUB_CURL_EXIT:-}" && "$STUB_CURL_EXIT" != 0 ]]; then
  printf '%s' "${STUB_HTTP_CODE:-200}"
  exit "$STUB_CURL_EXIT"
fi
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" && $# -ge 2 ]]; then out="$2"; shift; fi
  shift
done
[[ -n "$out" ]] && cp "$STUB_RESPONSE" "$out"
printf '%s' "${STUB_HTTP_CODE:-200}"
exit 0
EOF

  cat > "${STUBS}/aws" <<'EOF'
#!/bin/bash
{ echo "=== aws"; for a in "$@"; do printf '[%s]\n' "$a"; done; } >> "$STUB_LOG"
if [[ -n "${STUB_CLI_EXIT:-}" ]]; then exit "$STUB_CLI_EXIT"; fi
last=""
for a in "$@"; do last="$a"; done
[[ -n "$last" ]] && head -c 2048 /dev/zero | tr '\0' 'A' > "$last"
exit 0
EOF

  cat > "${STUBS}/edge-tts" <<'EOF'
#!/bin/bash
{ echo "=== edge-tts"; for a in "$@"; do printf '[%s]\n' "$a"; done; } >> "$STUB_LOG"
if [[ -n "${STUB_CLI_EXIT:-}" ]]; then exit "$STUB_CLI_EXIT"; fi
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--write-media" && $# -ge 2 ]]; then out="$2"; shift; fi
  shift
done
[[ -n "$out" ]] && head -c 2048 /dev/zero | tr '\0' 'A' > "$out"
exit 0
EOF

  cat > "${STUBS}/espeak-ng" <<'EOF'
#!/bin/bash
name=$(basename "$0")
{ echo "=== $name"; for a in "$@"; do printf '[%s]\n' "$a"; done; } >> "$STUB_LOG"
if [[ -n "${STUB_ESPEAK_EXIT:-}" ]]; then exit "$STUB_ESPEAK_EXIT"; fi
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-w" && $# -ge 2 ]]; then out="$2"; shift; fi
  shift
done
[[ -n "$out" ]] && head -c 2048 /dev/zero | tr '\0' 'A' > "$out"
exit 0
EOF
  cp "${STUBS}/espeak-ng" "${STUBS}/espeak"

  cat > "${STUBS}/python3" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "-c" ]]; then
  case "${2:-}" in
    "import kittentts"|"import tada") exit 0 ;;
  esac
fi
script="${2:-}"
if [[ "$script" == *"from kittentts import"* ]]; then
  { echo "=== python3 (kitten)"; printf '%s\n' "$script"; echo "--- env"; env | grep '^KITTEN_' | LC_ALL=C sort; } >> "$STUB_LOG"
  if [[ -n "${STUB_CLI_EXIT:-}" ]]; then exit "$STUB_CLI_EXIT"; fi
  head -c 2048 /dev/zero | tr '\0' 'A' > "$KITTEN_OUTPUT"
  exit 0
elif [[ "$script" == *"TadaForCausalLM"* ]]; then
  { echo "=== python3 (tada)"; printf '%s\n' "$script"; echo "--- env"; env | grep '^TADA_' | LC_ALL=C sort; } >> "$STUB_LOG"
  if [[ -n "${STUB_CLI_EXIT:-}" ]]; then exit "$STUB_CLI_EXIT"; fi
  head -c 2048 /dev/zero | tr '\0' 'A' > "$TADA_OUTPUT"
  exit 0
fi
{ echo "=== python3"; for a in "$@"; do printf '[%s]\n' "$a"; done; } >> "$STUB_LOG"
exec "$REAL_PYTHON3" "$@"
EOF

  local p
  for p in mpv ffplay paplay aplay afplay say piper; do
    cat > "${STUBS}/${p}" <<'EOF'
#!/bin/bash
name=$(basename "$0")
{ echo "=== $name"; for a in "$@"; do printf '[%s]\n' "$a"; done; } >> "$STUB_LOG"
exit 0
EOF
  done

  for p in sudo brew pip pip3 apt-get dnf pacman pkill killall; do
    cat > "${STUBS}/${p}" <<'EOF'
#!/bin/bash
name=$(basename "$0")
echo "UNEXPECTED $name $*" >> "$STUB_LOG"
exit 1
EOF
  done

  chmod +x "${STUBS}"/*
}

# --- Scenario plumbing ---
CASE_NUM=0
T=""

new_case() {
  CASE_NUM=$((CASE_NUM + 1))
  T="${ROOT}/case${CASE_NUM}"
  mkdir -p "${T}/home/.claude" "${T}/tmp/claude_tts_queue"
  : > "${T}/stub.log"
  echo "##### $1"
}

normalize() {
  sed "s#${T}#<T>#g" | sed -E 's#<T>/tmp/claude_tts_[a-z_]+\.[A-Za-z0-9]{6}#<MKTEMP>#g'
}

# invoke SCRIPT [VAR=value ...] -- [ARGS ...]
invoke() {
  local script="$1"
  shift
  local -a extra_env=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    extra_env+=("$1")
    shift
  done
  [[ $# -gt 0 ]] && shift
  env -i PATH="${STUBS}:${PATH}" HOME="${T}/home" TMPDIR="${T}/tmp" \
    STUB_LOG="${T}/stub.log" STUB_RESPONSE="$RESPONSE" REAL_PYTHON3="$REAL_PYTHON3" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    ${extra_env[@]+"${extra_env[@]}"} \
    bash "$script" "$@" > "${T}/stdout" 2> "${T}/stderr"
  echo "--- exit: $?"
}

# md_command FILE: print the body of the ```bash fence in a command .md file.
md_command() {
  awk '/^```bash$/ { f = 1; next } /^```$/ { f = 0 } f' "$1"
}

# run_md FILE [VAR=value ...]: run the bash fence of a command .md file
# under env -i, the same sandbox invoke uses.
run_md() {
  local cmd
  cmd=$(md_command "$1")
  shift
  env -i PATH="${STUBS}:${PATH}" HOME="${T}/home" TMPDIR="${T}/tmp" \
    STUB_LOG="${T}/stub.log" STUB_RESPONSE="$RESPONSE" REAL_PYTHON3="$REAL_PYTHON3" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    "$@" \
    bash -c "$cmd" > "${T}/stdout" 2> "${T}/stderr"
  echo "--- exit: $?"
}

report() {
  local show_config="$1"
  echo "--- stdout"
  normalize < "${T}/stdout"
  echo "--- stderr"
  normalize < "${T}/stderr"
  echo "--- queue"
  ls -A "${T}/tmp/claude_tts_queue" | sort
  if [[ "$show_config" == true ]]; then
    echo "--- config"
    if [[ -f "${T}/home/.claude/claude-tts.local.md" ]]; then
      normalize < "${T}/home/.claude/claude-tts.local.md"
    else
      echo "(none)"
    fi
  fi
  echo "--- stub log"
  normalize < "${T}/stub.log"
}

# worker LABEL CONFIG [VAR=value ...]
# CONFIG is the front matter body (empty for no config file). MSG overrides the message.
worker() {
  local label="$1" config="$2"
  shift 2
  new_case "worker: ${label}"
  if [[ -n "$config" ]]; then
    printf -- '---\n%s\n---\n' "$config" > "${T}/home/.claude/claude-tts.local.md"
  fi
  printf '%s\n' "${MSG:-$MESSAGE}" > "${T}/msg.txt"
  # A live PID in daemon.pid stops the worker from spawning the queue daemon.
  echo "$$" > "${T}/tmp/claude_tts_queue/daemon.pid"
  invoke "$WORKER" "$@" -- "${T}/msg.txt"
  report false
}

# setup LABEL [VAR=value ...] -- [ARGS ...]
setup() {
  local label="$1"
  shift
  new_case "setup: ${label}"
  invoke "$SETUP" "$@"
  report true
}

# status LABEL CONFIG [VAR=value ...]
# Runs the /tts-status command. CONFIG is the front matter body (empty for
# no config file). STATUS_ENABLED=1 creates the enabled flag, STATUS_PID is
# written to daemon.pid, and STATUS_QUEUE names queue files to create.
status() {
  local label="$1" config="$2" f
  shift 2
  new_case "status: ${label}"
  if [[ -n "$config" ]]; then
    printf -- '---\n%s\n---\n' "$config" > "${T}/home/.claude/claude-tts.local.md"
  fi
  if [[ -n "${STATUS_ENABLED:-}" ]]; then
    : > "${T}/home/.claude/tts-enabled"
  fi
  if [[ -n "${STATUS_PID:-}" ]]; then
    echo "$STATUS_PID" > "${T}/tmp/claude_tts_queue/daemon.pid"
  fi
  for f in ${STATUS_QUEUE:-}; do
    : > "${T}/tmp/claude_tts_queue/${f}"
  done
  run_md "$STATUS_MD" "$@"
  echo "--- stdout"
  normalize < "${T}/stdout" |
    sed -E -e 's/^(jq: +Installed \().*\)$/\1<JQ>)/' -e 's/\(PID [0-9]+\)/(PID <PID>)/'
  echo "--- stderr"
  normalize < "${T}/stderr"
}

NON_LOCAL="elevenlabs openai google amazon edge kitten mimo tada fish gemini"
HTTP_PROVIDERS="elevenlabs openai google mimo fish gemini"
ALL_PROVIDERS="${NON_LOCAL} local"

run_all() {
  local p

  # (a) defaults: provider and key only
  for p in $NON_LOCAL; do
    worker "a-defaults-${p}" "provider: \"${p}\"
api_key: \"KEY-${p}\""
  done

  # (b) explicit voice, model and region
  for p in $NON_LOCAL; do
    worker "b-overrides-${p}" "provider: \"${p}\"
api_key: \"KEY-${p}\"
voice_id: \"V-x\"
model_id: \"M-x\"
region: \"westeurope\""
  done

  # (c) legacy elevenlabs_api_key with no provider
  worker "c-legacy-elevenlabs-key" "elevenlabs_api_key: \"KEY-legacy\""

  # (d) CLAUDE_TTS_API_KEY overrides the config key
  worker "d-env-key-override-openai" "provider: \"openai\"
api_key: \"KEY-openai\"" CLAUDE_TTS_API_KEY=KEY-from-env

  # (e) ELEVENLABS_API_KEY with no config file
  worker "e-elevenlabs-env-no-config" "" ELEVENLABS_API_KEY=KEY-eleven-env

  # (f) legacy "say" provider maps to local
  worker "f-say-local" "provider: \"say\""

  # (g) unknown provider with a key falls back to local
  worker "g-bogus-provider" "provider: \"bogus\"
api_key: \"KEY-bogus\""
  worker "g-azure-provider-removed" "provider: \"azure\"
api_key: \"KEY-azure\"
region: \"eastus\""

  # (h) key-requiring provider with no key falls back to local
  worker "h-openai-no-key" "provider: \"openai\""

  # (i) HTTP 500 falls back to local
  worker "i-openai-http-500" "provider: \"openai\"
api_key: \"KEY-openai\"" STUB_HTTP_CODE=500

  # (j) HTTP 201 is not a success
  worker "j-openai-http-201" "provider: \"openai\"
api_key: \"KEY-openai\"" STUB_HTTP_CODE=201

  # (k) message too short to speak
  MSG="hi" worker "k-short-message" "provider: \"openai\"
api_key: \"KEY-openai\""

  # (f1) curl itself fails (exit 7, no HTTP response)
  for p in $HTTP_PROVIDERS; do
    worker "f1-curl-exit7-${p}" "provider: \"${p}\"
api_key: \"KEY-${p}\"" STUB_CURL_EXIT=7 STUB_HTTP_CODE=000
  done

  # (f2) HTTP 200 with a tiny payload
  for p in $HTTP_PROVIDERS; do
    worker "f2-http200-tiny-${p}" "provider: \"${p}\"
api_key: \"KEY-${p}\"" STUB_RESPONSE="$TINY"
  done

  # (f3) HTTP 200 with an HTML body; openai queues it as mp3
  for p in google mimo gemini openai; do
    worker "f3-http200-nonjson-${p}" "provider: \"${p}\"
api_key: \"KEY-${p}\"" STUB_RESPONSE="$NONJSON"
  done

  # (f4) CLI or Python provider exits non-zero and writes nothing
  for p in amazon edge kitten tada; do
    worker "f4-cli-fail-${p}" "provider: \"${p}\"" STUB_CLI_EXIT=1
  done

  # (f5) provider and local fallback both fail
  worker "f5-all-backends-fail-openai" "provider: \"openai\"
api_key: \"KEY-openai\"" STUB_HTTP_CODE=500 STUB_ESPEAK_EXIT=1
  worker "f5-all-backends-fail-local" "provider: \"local\"" STUB_ESPEAK_EXIT=1

  # Setup: every provider
  for p in $ALL_PROVIDERS; do
    if [[ "$p" == "tada" ]]; then
      setup "provider-tada-no-arg" -- tada
    else
      setup "provider-${p}" -- "$p" "KEY-${p}"
    fi
  done
  setup "no-args" --
  setup "bogus-provider" -- bogus KEY-bogus
  setup "azure-removed" -- azure KEY-azure
  setup "openai-no-key" -- openai
  setup "say" -- say
  setup "openai-http-401" STUB_HTTP_CODE=401 -- openai KEY-openai

  # Setup: failure modes
  setup "f-openai-curl-exit7" STUB_CURL_EXIT=7 STUB_HTTP_CODE=000 -- openai KEY-openai
  setup "f-openai-tiny" STUB_RESPONSE="$TINY" -- openai KEY-openai
  setup "f-google-nonjson" STUB_RESPONSE="$NONJSON" -- google KEY-google
  setup "f-edge-cli-fail" STUB_CLI_EXIT=1 -- edge
  setup "f-amazon-cli-fail" STUB_CLI_EXIT=1 -- amazon
  setup "f-openai-401-espeak-fail" STUB_HTTP_CODE=401 STUB_ESPEAK_EXIT=1 -- openai KEY-openai

  # /tts-status
  status "unconfigured" ""
  STATUS_ENABLED=1 STATUS_PID=$$ STATUS_QUEUE="000001.mp3 000002.wav" \
    status "openai-running-queued" "provider: \"openai\"
api_key: \"KEY-openai\""
  status "openai-empty-key" "provider: \"openai\"
api_key: \"\""
  status "openai-no-key" "provider: \"openai\""
  status "legacy-key" "elevenlabs_api_key: \"K\""
  status "legacy-empty-key" "elevenlabs_api_key: \"\""
  for p in amazon edge kitten tada local say; do
    status "keyless-${p}" "provider: \"${p}\""
  done
  status "env-claude-key" "provider: \"openai\"" CLAUDE_TTS_API_KEY=K
  status "env-elevenlabs-key-openai" "provider: \"openai\"" ELEVENLABS_API_KEY=K
  STATUS_PID=99999999 status "stale-pid" ""
  status "azure-config" "provider: \"azure\"
api_key: \"KEY-azure\""
}

# split_transcript DIR: read a transcript on stdin and write DIR/scenarios.txt
# (slugs in run order) and DIR/scenarios/<slug>.log (each section, header
# included). The slug is the label after "##### " with every run of
# characters outside [A-Za-z0-9._-] replaced by "_".
split_transcript() {
  local dir="$1"
  mkdir -p "${dir}/scenarios"
  awk -v d="$dir" '
    /^##### / {
      if (f != "") close(f)
      s = substr($0, 7)
      gsub(/[^A-Za-z0-9._-]+/, "_", s)
      if (s in seen) {
        print "duplicate scenario slug: " s > "/dev/stderr"
        exit 1
      }
      seen[s] = 1
      print s > (d "/scenarios.txt")
      f = d "/scenarios/" s ".log"
    }
    f != "" { print > f }
  '
}

build_fixture
build_stubs

case "${1:-}" in
  --update)
    rm -f "${GOLDEN_DIR}/scenarios/"*.log "${GOLDEN_DIR}/scenarios.txt"
    run_all | split_transcript "$GOLDEN_DIR" || exit 1
    echo "Updated ${GOLDEN_DIR}"
    ;;
  --split)
    run_all | split_transcript "${2:?--split needs a directory}" || exit 1
    ;;
  *)
    run_all
    ;;
esac
