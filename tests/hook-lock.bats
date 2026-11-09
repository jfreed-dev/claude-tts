#!/usr/bin/env bats
# Tests for the hook lock in tts-hook.sh and how tts-stop.sh treats it.
# Each test runs a copy of the hook scripts with tts-worker.sh replaced by a
# stub that records the message it was given.

bats_require_minimum_version 1.5.0

setup() {
  local src="${BATS_TEST_DIRNAME}/../plugins/claude-tts/hooks/scripts"
  S="${BATS_TEST_TMPDIR}/scripts"
  mkdir -p "$S" "${BATS_TEST_TMPDIR}/home/.claude" "${BATS_TEST_TMPDIR}/tmp" "${BATS_TEST_TMPDIR}/fake"
  cp "$src"/*.sh "$S/"
  WORKER_LOG="${BATS_TEST_TMPDIR}/worker.log"
  cat > "$S/tts-worker.sh" <<STUB
#!/usr/bin/env bash
cat "\$1" >> "$WORKER_LOG"
rm -f "\$1"
STUB
  chmod +x "$S"/*.sh
  touch "${BATS_TEST_TMPDIR}/home/.claude/tts-enabled"
  LOCK="${BATS_TEST_TMPDIR}/tmp/claude_tts_hook.lock"
  BG_PIDS=""
}

teardown() {
  local p
  for p in $BG_PIDS; do
    pkill -P "$p" 2>/dev/null || true
    kill "$p" 2>/dev/null || true
  done
}

# hook MESSAGE: run the hook copy in a clean environment.
hook() {
  printf '{"last_assistant_message":"%s"}' "$1" |
    env -i PATH="$PATH" HOME="${BATS_TEST_TMPDIR}/home" TMPDIR="${BATS_TEST_TMPDIR}/tmp" \
      "$S/tts-hook.sh"
}

stop() {
  env -i PATH="$PATH" HOME="${BATS_TEST_TMPDIR}/home" TMPDIR="${BATS_TEST_TMPDIR}/tmp" \
    "$S/tts-stop.sh"
}

# wait_for_worker MESSAGE: up to 3 s for the worker stub to log MESSAGE.
wait_for_worker() {
  local i
  for i in $(seq 30); do
    grep -qx -- "$1" "$WORKER_LOG" 2>/dev/null && return 0
    sleep 0.1
  done
  echo "worker never got: $1"
  return 1
}

# fake_holder SECONDS: start a process whose command line contains
# tts-hook.sh, sleeping SECONDS and then removing the lock as a real hook
# would on exit. Sets HOLDER to its PID.
fake_holder() {
  printf '#!/usr/bin/env bash\nsleep %s\nrm -rf "%s"\n' "$1" "$LOCK" > "${BATS_TEST_TMPDIR}/fake/tts-hook.sh"
  # Close fd 3 so bats does not wait for the background sleep
  bash "${BATS_TEST_TMPDIR}/fake/tts-hook.sh" 3>&- &
  HOLDER=$!
  BG_PIDS="$BG_PIDS $HOLDER"
  mkdir "$LOCK"
  echo "$HOLDER" > "$LOCK/pid"
}

@test "hook starts the worker, prints nothing and releases the lock" {
  run --separate-stderr hook "first reply"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ] || { echo "stderr: $stderr"; return 1; }
  wait_for_worker "first reply"
  [ ! -e "$LOCK" ]
}

@test "a second hook waits for a live holder, then runs" {
  fake_holder 1
  run --separate-stderr hook "second reply"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  # The hook returned only after the holder finished
  if kill -0 "$HOLDER" 2>/dev/null; then
    echo "hook returned while the holder was still running"
    return 1
  fi
  wait_for_worker "second reply"
  [ ! -e "$LOCK" ]
}

@test "a hook gives up after about 5 s if the holder never exits" {
  fake_holder 30
  run hook "never spoken"
  [ "$status" -eq 0 ]
  [ ! -e "$WORKER_LOG" ]
  # The holder's lock is untouched
  [ "$(cat "$LOCK/pid")" = "$HOLDER" ]
}

@test "a lock whose holder died is taken over" {
  bash -c 'exit 0' &
  local dead=$!
  wait "$dead" || true
  mkdir "$LOCK"
  echo "$dead" > "$LOCK/pid"
  run hook "after a dead holder"
  [ "$status" -eq 0 ]
  wait_for_worker "after a dead holder"
  [ ! -e "$LOCK" ]
}

@test "a lock holding the PID of another program is taken over" {
  sleep 30 3>&- &
  local other=$!
  BG_PIDS="$BG_PIDS $other"
  mkdir "$LOCK"
  echo "$other" > "$LOCK/pid"
  run hook "after a reused pid"
  [ "$status" -eq 0 ]
  wait_for_worker "after a reused pid"
  [ ! -e "$LOCK" ]
  kill -0 "$other"
}

@test "a lock with no pid file is taken over" {
  mkdir "$LOCK"
  run hook "after a pidless lock"
  [ "$status" -eq 0 ]
  wait_for_worker "after a pidless lock"
  [ ! -e "$LOCK" ]
}

@test "tts-stop.sh keeps a live hook's lock" {
  fake_holder 30
  run stop
  [ "$status" -eq 0 ]
  [ "$(cat "$LOCK/pid")" = "$HOLDER" ]
}

@test "tts-stop.sh removes a stale lock" {
  mkdir "$LOCK"
  echo 99999999 > "$LOCK/pid"
  run stop
  [ "$status" -eq 0 ]
  [ ! -e "$LOCK" ]
}
