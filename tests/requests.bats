#!/usr/bin/env bats
# Compares provider requests made by tts-worker.sh and tts-setup.sh against
# the golden transcript, one file per scenario under tests/golden.
# Regenerate with: bash tests/capture-requests.sh --update

setup() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    skip "golden transcript is captured on Linux"
  fi
  cd "${BATS_TEST_DIRNAME}/.."
}

@test "provider requests match golden transcript" {
  run bash tests/capture-requests.sh --split "$BATS_TEST_TMPDIR/g"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  diff -r tests/golden "$BATS_TEST_TMPDIR/g"
}
