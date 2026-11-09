#!/usr/bin/env bats
# Tests for the hook lock in tts-hook.sh and how tts-stop.sh treats it.
# Each test runs a copy of the hook scripts with tts-worker.sh replaced by a
# stub that registers like the real worker and logs the message it was given.

bats_require_minimum_version 1.5.0

setup() {
  local src="${BATS_TEST_DIRNAME}/../plugins/claude-tts/hooks/scripts"
  S="${BATS_TEST_TMPDIR}/scripts"
  TMPD="${BATS_TEST_TMPDIR}/tmp"
  mkdir -p "$S" "${BATS_TEST_TMPDIR}/home/.claude" "$TMPD" "${BATS_TEST_TMPDIR}/fake"
  cp "$src"/*.sh "$S/"
  WORKER_LOG="${BATS_TEST_TMPDIR}/worker.log"
  # STUB_REGISTER_DELAY: seconds before the stub writes its pid file.
  # STUB_LINGER: seconds the stub stays alive after logging.
  cat > "$S/tts-worker.sh" <<STUB
#!/usr/bin/env bash
exec 3>&-
q="\$TMPDIR/claude_tts_queue"
mkdir -p "\$q"
sleep "\${STUB_REGISTER_DELAY:-0}"
echo \$\$ > "\$q/worker.\$\$.pid"
cat "\$1" >> "$WORKER_LOG"
rm -f "\$1"
sleep "\${STUB_LINGER:-0}"
rm -f "\$q/worker.\$\$.pid"
STUB
  chmod +x "$S"/*.sh
  touch "${BATS_TEST_TMPDIR}/home/.claude/tts-enabled"
  LOCK="${TMPD}/claude_tts_hook.pid"
  BG_PIDS=""
}

teardown() {
  local p f
  for f in "$TMPD"/claude_tts_queue/worker.*.pid; do
    [ -f "$f" ] && BG_PIDS="$BG_PIDS $(cat "$f")"
  done
  for p in $BG_PIDS; do
    pkill -P "$p" 2>/dev/null || true
    kill "$p" 2>/dev/null || true
  done
}

# hook MESSAGE: run the hook copy in a clean environment.
hook() {
  printf '{"last_assistant_message":"%s"}' "$1" |
    env -i PATH="$PATH" HOME="${BATS_TEST_TMPDIR}/home" TMPDIR="$TMPD" \
      STUB_REGISTER_DELAY="${STUB_REGISTER_DELAY:-0}" STUB_LINGER="${STUB_LINGER:-0}" \
      "$S/tts-hook.sh"
}

stop() {
  env -i PATH="$PATH" HOME="${BATS_TEST_TMPDIR}/home" TMPDIR="$TMPD" "$S/tts-stop.sh"
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
# tts-hook.sh, make it the lock owner, and have it release the lock after
# SECONDS as a real hook would on exit. Sets HOLDER to its PID.
fake_holder() {
  printf '#!/usr/bin/env bash\nsleep %s\nrm -f "%s"\n' "$1" "$LOCK" > "${BATS_TEST_TMPDIR}/fake/tts-hook.sh"
  # Close fd 3 so bats does not wait for the background sleep
  bash "${BATS_TEST_TMPDIR}/fake/tts-hook.sh" 3>&- &
  HOLDER=$!
  BG_PIDS="$BG_PIDS $HOLDER"
  echo "$HOLDER" > "$LOCK"
}

# no_lock_leftovers: no lock, temp or stale files remain in TMPDIR.
no_lock_leftovers() {
  local left
  left=$(cd "$TMPD" && ls -A | grep '^claude_tts_hook' || true)
  [ -z "$left" ] || { echo "left behind: $left"; return 1; }
}

@test "hook starts the worker, prints nothing and releases the lock" {
  run --separate-stderr hook "first reply"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ] || { echo "stderr: $stderr"; return 1; }
  wait_for_worker "first reply"
  no_lock_leftovers
}

@test "a second hook waits for a live holder, then runs" {
  fake_holder 1
  run --separate-stderr hook "second reply"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  if kill -0 "$HOLDER" 2>/dev/null; then
    echo "hook returned while the holder was still running"
    return 1
  fi
  wait_for_worker "second reply"
  no_lock_leftovers
}

@test "a hook that gives up leaves the holder's lock and lets a retry speak" {
  fake_holder 30
  run hook "retried reply"
  [ "$status" -eq 0 ]
  [ ! -e "$WORKER_LOG" ]
  [ "$(cat "$LOCK")" = "$HOLDER" ]
  # The holder goes away; the same message is spoken on retry
  kill "$HOLDER"
  run hook "retried reply"
  [ "$status" -eq 0 ]
  wait_for_worker "retried reply"
}

@test "a lock whose holder died is taken over" {
  bash -c 'exit 0' &
  local dead=$!
  wait "$dead" || true
  echo "$dead" > "$LOCK"
  run hook "after a dead holder"
  [ "$status" -eq 0 ]
  wait_for_worker "after a dead holder"
  no_lock_leftovers
}

@test "a lock holding the PID of another program is taken over" {
  sleep 30 3>&- &
  local other=$!
  BG_PIDS="$BG_PIDS $other"
  echo "$other" > "$LOCK"
  run hook "after a reused pid"
  [ "$status" -eq 0 ]
  wait_for_worker "after a reused pid"
  no_lock_leftovers
  kill -0 "$other"
}

@test "an empty lock file is taken over" {
  : > "$LOCK"
  run hook "after an empty lock"
  [ "$status" -eq 0 ]
  wait_for_worker "after an empty lock"
  no_lock_leftovers
}

@test "the next hook stops a worker that registered late" {
  STUB_REGISTER_DELAY=0.5 STUB_LINGER=30 run hook "older reply"
  [ "$status" -eq 0 ]
  local f older
  f=$(ls "$TMPD"/claude_tts_queue/worker.*.pid 2>/dev/null | head -1)
  [ -n "$f" ] || { echo "hook returned before the worker registered"; return 1; }
  older=$(cat "$f")
  STUB_LINGER=30 run hook "newer reply"
  [ "$status" -eq 0 ]
  wait_for_worker "newer reply"
  if kill -0 "$older" 2>/dev/null; then
    echo "the older worker survived the newer hook"
    return 1
  fi
}

@test "tts-stop.sh keeps a live hook's lock" {
  fake_holder 30
  run stop
  [ "$status" -eq 0 ]
  [ "$(cat "$LOCK")" = "$HOLDER" ]
}

@test "tts-stop.sh removes a stale lock" {
  echo 99999999 > "$LOCK"
  run stop
  [ "$status" -eq 0 ]
  [ ! -e "$LOCK" ]
}

@test "a stale breaker left by a dead process is cleared" {
  echo 99999999 > "${TMPD}/claude_tts_hook.break"
  echo 99999999 > "$LOCK"
  run hook "after a stale breaker"
  [ "$status" -eq 0 ]
  wait_for_worker "after a stale breaker"
  no_lock_leftovers
}

@test "eight hooks racing a stale lock never run the stop section together" {
  # Replace tts-stop.sh with a probe that records any overlap
  cat > "$S/tts-stop.sh" <<PROBE
#!/usr/bin/env bash
mkdir "${BATS_TEST_TMPDIR}/inside" 2>/dev/null || echo OVERLAP >> "${BATS_TEST_TMPDIR}/probe"
echo enter >> "${BATS_TEST_TMPDIR}/probe"
sleep 0.05
rmdir "${BATS_TEST_TMPDIR}/inside"
PROBE
  local round i
  for round in 1 2 3; do
    echo 99999999 > "$LOCK"
    for i in 1 2 3 4 5 6 7 8; do
      hook "round $round hook $i" 3>&- &
    done
    wait
  done
  [ "$(grep -c enter "${BATS_TEST_TMPDIR}/probe")" -eq 24 ]
  if grep -q OVERLAP "${BATS_TEST_TMPDIR}/probe"; then
    echo "$(grep -c OVERLAP "${BATS_TEST_TMPDIR}/probe") overlaps"
    return 1
  fi
  no_lock_leftovers
}
