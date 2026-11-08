#!/usr/bin/env bats
# Unit tests for tts_config_get in plugins/claude-tts/hooks/scripts/common.sh.
# Each case sources common.sh under bash -euo pipefail, as the scripts do.

setup() {
  COMMON="${BATS_TEST_DIRNAME}/../plugins/claude-tts/hooks/scripts/common.sh"
  CFG="${BATS_TEST_TMPDIR}/config.md"
}

@test "missing key prints nothing and returns 0 inside \$()" {
  printf -- '---\nprovider: "openai"\n---\n' > "$CFG"
  run bash -euo pipefail -c 'source "$1"; v=$(tts_config_get voice_id "$2"); echo "[$v] rc=$?"' _ "$COMMON" "$CFG"
  [ "$status" -eq 0 ]
  [ "$output" = "[] rc=0" ]
}

@test "missing key as a bare command prints nothing and returns 0" {
  printf -- '---\nprovider: "openai"\n---\n' > "$CFG"
  run bash -euo pipefail -c 'source "$1"; tts_config_get voice_id "$2"; echo "rc=$?"' _ "$COMMON" "$CFG"
  [ "$status" -eq 0 ]
  [ "$output" = "rc=0" ]
}

@test "missing file prints nothing and returns 0" {
  run bash -euo pipefail -c 'source "$1"; tts_config_get provider "$2"; echo "rc=$?"' _ "$COMMON" "${BATS_TEST_TMPDIR}/missing.md"
  [ "$status" -eq 0 ]
  [ "$output" = "rc=0" ]
}

@test "api_key does not match elevenlabs_api_key" {
  printf -- '---\nelevenlabs_api_key: "LEGACY"\n---\n' > "$CFG"
  run bash -euo pipefail -c 'source "$1"; echo "[$(tts_config_get api_key "$2")]"' _ "$COMMON" "$CFG"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "quoted and unquoted values are both read" {
  printf -- '---\nprovider: "openai"\nvoice_id: alloy\n---\n' > "$CFG"
  run bash -euo pipefail -c 'source "$1"; echo "$(tts_config_get provider "$2")|$(tts_config_get voice_id "$2")"' _ "$COMMON" "$CFG"
  [ "$status" -eq 0 ]
  [ "$output" = "openai|alloy" ]
}

@test "the first matching line wins" {
  printf -- '---\nprovider: "openai"\nprovider: "google"\n---\n' > "$CFG"
  run bash -euo pipefail -c 'source "$1"; tts_config_get provider "$2"' _ "$COMMON" "$CFG"
  [ "$status" -eq 0 ]
  [ "$output" = "openai" ]
}
