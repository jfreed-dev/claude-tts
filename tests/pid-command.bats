#!/usr/bin/env bats
# PID checks must see the whole command line even when COLUMNS is narrow.
# ps cuts its output to $COLUMNS characters, which hid the script name of an
# installed daemon (its path is over 100 characters) from tts-stop.sh.

bats_require_minimum_version 1.5.0

setup() {
  SRC="${BATS_TEST_DIRNAME}/../plugins/claude-tts/hooks/scripts"
  # A path as long as the plugin cache path, so its tail falls past column 80
  LONG="${BATS_TEST_TMPDIR}/plugins/cache/claude-tts-marketplace/claude-tts/3.0.1/hooks/scripts"
  TMPD="${BATS_TEST_TMPDIR}/tmp"
  mkdir -p "$TMPD/claude_tts_queue"
  FAKE_PID=""
}

teardown() {
  if [ -n "$FAKE_PID" ]; then
    pkill -P "$FAKE_PID" 2>/dev/null || true
    kill "$FAKE_PID" 2>/dev/null || true
  fi
}

# start_fake NAME: run "bash $LONG/NAME", a script that sleeps, in the background.
start_fake() {
  mkdir -p "$LONG"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$LONG/$1"
  bash "$LONG/$1" &
  FAKE_PID=$!
  local i
  for i in $(seq 1 20); do
    [[ "$(ps -ww -p "$FAKE_PID" -o command= 2>/dev/null)" == *"$1" ]] && return 0
    sleep 0.05
  done
  return 1
}

@test "tts_pid_matches finds the script name at COLUMNS=40" {
  start_fake tts-queue-daemon.sh
  run env COLUMNS=40 bash -c "source '$SRC/common.sh'; tts_pid_matches $FAKE_PID tts-queue-daemon.sh"
  [ "$status" -eq 0 ]
}

@test "tts_pid_runs_script finds the script name at COLUMNS=40" {
  start_fake tts-hook.sh
  run env COLUMNS=40 bash -c "source '$SRC/common.sh'; tts_pid_runs_script $FAKE_PID tts-hook.sh"
  [ "$status" -eq 0 ]
}

@test "tts-stop.sh kills a registered daemon with a long path at COLUMNS=80" {
  start_fake tts-queue-daemon.sh
  echo "$FAKE_PID" > "$TMPD/claude_tts_queue/daemon.pid"
  env -i PATH="$PATH" HOME="${BATS_TEST_TMPDIR}" TMPDIR="$TMPD" COLUMNS=80 "$SRC/tts-stop.sh"
  # The fake is this shell's child, so once killed it stays a zombie (Z)
  local i st
  for i in $(seq 1 20); do
    st=$(ps -p "$FAKE_PID" -o stat= 2>/dev/null) || st=""
    [[ -z "$st" || "$st" == Z* ]] && break
    sleep 0.05
  done
  [[ -z "$st" || "$st" == Z* ]]
}
