#!/usr/bin/env bats
# Compares provider requests made by tts-worker.sh and tts-setup.sh against
# the golden transcript. Regenerate with: bash tests/capture-requests.sh --update

setup() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    skip "golden transcript is captured on Linux"
  fi
  cd "${BATS_TEST_DIRNAME}/.."
}

@test "provider requests match golden transcript" {
  run bash tests/capture-requests.sh
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") tests/golden/requests.log
}
