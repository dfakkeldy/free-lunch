#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Scripts/acceptance-sim.sh
#
# The CI-canonical Free Lunch simulator acceptance command. It exits nonzero
# on any failure; changes to Free Lunch simulator acceptance belong here.
#
# What this does, in order:
#   1. Resolves the dedicated iPhone and Apple Watch simulator pair by name
#      via `xcrun simctl list devices --json`,
#      parsed with the macOS-bundled /usr/bin/python3 (a system tool that
#      ships with every Mac, not a project dependency -- not Homebrew
#      python, not a pinned interpreter). The match must be exact-name,
#      isAvailable == true, and scoped to the single newest installed
#      runtime for that platform (newest iOS runtime for the phone,
#      newest watchOS runtime for the watch). More than one available
#      match for a name is treated as a configuration error and fails
#      loudly rather than silently picking one.
#      Never creates, clones, or boots any other device -- fails loudly
#      if either named device is missing or ambiguous.
#   2. Boots the named pair.
#   3. Builds the phone and watch app targets.
#   4. Runs the phone XCUITest suite, then the watch UI test suite.
#   5. Exports screenshots/attachments from both resulting .xcresult
#      bundles into a fresh Scripts/output/runs/<UTC-timestamp>/ directory
#      (previous runs are never overwritten in place -- each run gets its
#      own directory, so there is no result-bundle path collision), updates
#      the Scripts/output/latest symlink to point at it, and prunes
#      run directories beyond the newest 5.
#
# RAM guardrails (memory-constrained build Mac -- non-negotiable):
#   - A global, mkdir-based lock ($LOCK_DIR) serializes this script
#     against any other Free Lunch xcodebuild/simctl work on the machine.
#     The single ownership-flag-aware `cleanup` trap (EXIT/INT/TERM) is
#     installed BEFORE the first `mkdir` attempt -- there is no window
#     where a signal could hit a cleanup-unaware handler after the lock
#     directory already exists on disk. `cleanup` itself is a no-op on
#     lock/simulator state whenever LOCK_OWNED != 1, so a process still
#     waiting for the lock (a "waiter") never tears down another
#     holder's simulators/lock if it is interrupted -- only the process
#     that actually created $LOCK_DIR (LOCK_OWNED=1, set immediately
#     after `mkdir` succeeds) ever runs that part of cleanup. See
#     acquire_lock()/cleanup() below.
#   - Lock acquisition writes an owner file ("$LOCK_DIR/owner" = "<pid>
#     <unix ts>") so a dead holder's lock can be detected and recovered:
#     if the owner file is older than 30 minutes AND its pid is no
#     longer alive, the lock is treated as stale, is recovered (with a
#     loud log line; the named pair is reset by the normal boot step after
#     re-acquisition), and re-acquired. If the owner file is
#     missing or unreadable/unparseable (e.g. the holder was killed
#     between `mkdir` succeeding and the owner file being written), the
#     lock directory's own mtime is used instead: once it is >= 30
#     minutes old the lock is reclaimed the same way. This caps any
#     orphaned-lock consequence at the 30-minute stale threshold instead
#     of the full 45-minute wait timeout. Waiting for the lock has a
#     hard 45-minute timeout, after which the script exits non-zero with
#     a FATAL message rather than waiting forever.
#   - Every xcodebuild build/test invocation passes
#     -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1.
#   - All Free Lunch builds share one DerivedData directory ($DERIVED_DATA,
#     passed via -derivedDataPath) so nothing accumulates multiple copies.
#   - On every exit path where THIS process holds the lock (pass, fail,
#     or a cancelled/interrupted run) -- and only then --:
#     only the two named simulator UDIDs are shut down, and the lock is
#     released. A shutdown failure is logged loudly AND forces the script's
#     own exit code non-zero, even if the tests themselves passed -- leaving
#     this project's simulator state dirty counts as a failed acceptance run.
#   - A cancelled run (SIGINT/SIGTERM) always exits 130/143 respectively,
#     never 0, and never prints PASS -- regardless of what the
#     in-flight command's exit status happened to be.
#   - This script never creates, clones, or boots any simulator other
#     than the named simulator pair.
#
# Usage: Scripts/acceptance-sim.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/FreeLunch.xcodeproj"
APP_NAME="FreeLunch"
PHONE_SCHEME="FreeLunchPhone"
WATCH_SCHEME="FreeLunchWatch"
PHONE_UI_SUITE="FreeLunchPhoneUITests"
WATCH_UI_SUITE="FreeLunchWatchUITests"
DERIVED_DATA="$REPO_ROOT/DerivedData"     # shared DerivedData for all app builds (gitignored)
OUTPUT_DIR="$REPO_ROOT/Scripts/output"
RUNS_DIR="$OUTPUT_DIR/runs"
LATEST_LINK="$OUTPUT_DIR/latest"
# The default must be a path every checkout and worktree on the machine agrees
# on, and whose parent always exists: `mkdir` (not `mkdir -p`) is the lock, so
# a missing parent is a FATAL, not a wait. CI passes its own FL_LOCK_DIR.
LOCK_DIR="${FL_LOCK_DIR:-${TMPDIR:-/tmp}/free-lunch-sim.lock}"
OWNER_FILE="$LOCK_DIR/owner"

IPHONE_NAME="Free Lunch iPhone"
WATCH_NAME="Free Lunch Watch S11 46mm"
# Initialized before traps are installed so cleanup remains safe under set -u.
IPHONE_UDID=""
WATCH_UDID=""

LOCK_TIMEOUT_SECONDS=$((45 * 60))
STALE_LOCK_SECONDS=$((30 * 60))
RUNS_TO_KEEP=5

COMMON_XCODEBUILD_FLAGS=(
  -derivedDataPath "$DERIVED_DATA"
  -parallel-testing-enabled NO
  -maximum-concurrent-test-simulator-destinations 1
  CODE_SIGNING_ALLOWED=NO
)

# Mutable state referenced by traps -- must exist before any trap can fire.
LOCK_OWNED=0
CLEANUP_DONE=0
RUN_DIR=""

log() { echo "acceptance-sim: $*" >&2; }

# ---------------------------------------------------------------------------
# Cleanup: the trap is installed once, up front, BEFORE acquire_lock() makes
# its first `mkdir` attempt (see acquire_lock() below) -- there is no
# separate "pre-lock" signal handler and no window where a signal could hit
# a cleanup-unaware handler after the lock directory already exists on disk.
# Safety for a process that does not (yet) own the lock comes entirely from
# the LOCK_OWNED gate below: cleanup() is a no-op on lock/simulator state
# whenever LOCK_OWNED != 1, so a waiter that gets interrupted never tears
# down another holder's simulators/lock out from under it.
#
#   - INT/TERM always force exit 130/143, never PASS, never exit 0 --
#     regardless of what $? happened to be from the command in flight.
#   - Natural EXIT (script ran to completion or `set -e` aborted it) uses
#     the real $? so normal pass/fail exit codes are preserved.
#   - Shutdown results for the named pair are checked explicitly; a real
#     failure is logged loudly and forces the final exit code non-zero even
#     if the tests passed, because leaving this project's simulator state
#     dirty is itself a failed acceptance run.
#   - The lock (dir + owner file) is only ever removed here if THIS
#     process is the one that acquired it (LOCK_OWNED=1).
# ---------------------------------------------------------------------------
cleanup() {
  local natural_code=$?
  local exit_code="${1:-$natural_code}"

  if [ "$CLEANUP_DONE" -eq 1 ]; then
    exit "$exit_code"
  fi
  CLEANUP_DONE=1

  set +e
  local dirty=0

  if [ "$LOCK_OWNED" -ne 1 ]; then
    log "no build lock owned at exit -- nothing to clean up on the lock/simulator side (exit $exit_code)"
  else
    local udid shutdown_output
    for udid in "$IPHONE_UDID" "$WATCH_UDID"; do
      [ -n "$udid" ] || continue
      if shutdown_output="$(xcrun simctl shutdown "$udid" 2>&1)"; then
        continue
      fi
      if printf '%s\n' "$shutdown_output" | grep -Eqi 'already.*shut[ -]*down|current state: shutdown'; then
        log "simulator $udid was already shut down during cleanup"
        continue
      fi
      log "WARNING: failed to shut down simulator $udid during cleanup -- this project's simulator state may be dirty"
      [ -z "$shutdown_output" ] || printf '%s\n' "$shutdown_output" >&2
      dirty=1
    done

    rm -f "$OWNER_FILE"
    rmdir "$LOCK_DIR" 2>/dev/null
  fi

  finalize_run_artifacts

  if [ "$dirty" -eq 1 ] && [ "$exit_code" -eq 0 ]; then
    log "forcing failure: cleanup did not leave shared simulator state clean, even though the run itself passed"
    exit_code=1
  fi

  if [ "$exit_code" -eq 0 ]; then
    log "PASS"
  else
    log "FAIL (exit $exit_code)"
  fi
  exit "$exit_code"
}

# ---------------------------------------------------------------------------
# Artifact history bookkeeping: point Scripts/output/latest at this run's
# directory (if one was created) and prune run directories beyond the
# newest RUNS_TO_KEEP. Runs unconditionally from cleanup() so it happens on
# every completed/failed/cancelled-after-lock-acquired run, not only green
# ones.
# ---------------------------------------------------------------------------
finalize_run_artifacts() {
  if [ -z "$RUN_DIR" ] || [ ! -d "$RUN_DIR" ]; then
    return 0
  fi

  ln -sfn "runs/$(basename "$RUN_DIR")" "$LATEST_LINK"

  [ -d "$RUNS_DIR" ] || return 0

  local -a all_runs=()
  local d
  while IFS= read -r d; do
    all_runs+=("$d")
  done < <(find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

  local total=${#all_runs[@]}
  if [ "$total" -le "$RUNS_TO_KEEP" ]; then
    return 0
  fi

  local to_delete=$((total - RUNS_TO_KEEP))
  local i=0
  while [ "$i" -lt "$to_delete" ]; do
    log "pruning old run directory: ${all_runs[$i]}"
    rm -rf "${all_runs[$i]}"
    i=$((i + 1))
  done
}

# ---------------------------------------------------------------------------
# Global build lock serializes simulator work on the machine.
# ---------------------------------------------------------------------------
reclaim_stale_lock_if_any() {
  local now
  now=$(date +%s)

  local owner_pid="" owner_ts=""
  if [ -f "$OWNER_FILE" ] && [ -r "$OWNER_FILE" ]; then
    read -r owner_pid owner_ts < "$OWNER_FILE" 2>/dev/null
  fi

  if [[ "$owner_pid" =~ ^[0-9]+$ ]] && [[ "$owner_ts" =~ ^[0-9]+$ ]]; then
    # Owner file present and parses -- use its age/pid to judge staleness,
    # same as always.
    local age=$((now - owner_ts))
    [ "$age" -ge "$STALE_LOCK_SECONDS" ] || return 1

    if kill -0 "$owner_pid" 2>/dev/null; then
      return 1   # owner process is still alive -- just slow, not stale
    fi

    log "STALE LOCK DETECTED: owner pid $owner_pid is dead and the lock is ${age}s old (>= ${STALE_LOCK_SECONDS}s) -- recovering"
  else
    # No usable owner file -- missing, unreadable, or unparseable. This is
    # exactly what a `mkdir` that succeeded but was interrupted before the
    # owner file got written would leave behind. Without this fallback the
    # lock would sit unreclaimable until the full LOCK_TIMEOUT_SECONDS wait
    # gives up; instead, fall back to the lock directory's own mtime so an
    # ownerless lock is reclaimed no later than STALE_LOCK_SECONDS after it
    # was created.
    local lock_mtime
    lock_mtime="$(stat -f %m "$LOCK_DIR" 2>/dev/null)" || return 1
    [[ "$lock_mtime" =~ ^[0-9]+$ ]] || return 1

    local lock_age=$((now - lock_mtime))
    [ "$lock_age" -ge "$STALE_LOCK_SECONDS" ] || return 1

    log "STALE LOCK DETECTED (missing/unreadable owner file): $LOCK_DIR is ${lock_age}s old (>= ${STALE_LOCK_SECONDS}s) -- recovering"
  fi

  rm -f "$OWNER_FILE"
  rmdir "$LOCK_DIR" 2>/dev/null
  log "stale lock removed; the named pair's state will be reset by the normal idempotent boot step"
  return 0
}

acquire_lock() {
  # Install the ownership-flag-aware cleanup trap BEFORE the first `mkdir`
  # attempt below -- not after it succeeds. cleanup() gates all lock/
  # simulator teardown on LOCK_OWNED, so this is a safe no-op for as long as
  # this process is only waiting for the lock, and it closes the window
  # where a signal landing right after a successful `mkdir` (but before a
  # trap was installed) could leak an ownerless lock directory.
  trap cleanup EXIT
  trap 'cleanup 130' INT
  trap 'cleanup 143' TERM

  local start_ts
  start_ts=$(date +%s)

  while true; do
    local mkdir_err
    if mkdir_err="$(mkdir "$LOCK_DIR" 2>&1)"; then
      # Flag assignment immediately follows the successful mkdir -- the
      # cleanup trap is already installed (above), so from this line
      # onward a signal reliably runs the full lock/simulator teardown
      # instead of leaking the directory this process just created.
      LOCK_OWNED=1
      printf '%s %s\n' "$$" "$(date +%s)" > "$OWNER_FILE"
      log "build lock acquired ($LOCK_DIR), owner pid $$"
      return 0
    fi

    if [[ "$mkdir_err" != *"File exists"* ]]; then
      log "FATAL: could not create lock dir '$LOCK_DIR': $mkdir_err"
      exit 1
    fi

    local now
    now=$(date +%s)
    if [ $((now - start_ts)) -ge "$LOCK_TIMEOUT_SECONDS" ]; then
      log "FATAL: timed out after $((LOCK_TIMEOUT_SECONDS / 60)) minutes waiting for build lock at $LOCK_DIR"
      exit 1
    fi

    if reclaim_stale_lock_if_any; then
      log "retrying lock acquisition immediately after stale-lock recovery"
      continue
    fi

    log "waiting for build lock at $LOCK_DIR ..."
    # Backgrounded + `wait` rather than a plain foreground `sleep 30`: bash
    # defers running a pending INT/TERM trap until the *entire* enclosing
    # compound command (this while loop) returns when the wait is a plain
    # foreground `sleep` -- so a real Ctrl-C/SIGINT while waiting would
    # never actually interrupt this loop. `wait` on a backgrounded sleep is
    # a shell builtin that returns immediately (>128) the moment a trapped
    # signal arrives, making the wait genuinely interruptible.
    sleep 30 &
    wait "$!"
  done
}

acquire_lock

# ---------------------------------------------------------------------------
# Fresh run directory for this invocation. Created up front (before device
# resolution) so even an early FATAL still leaves a timestamped record and
# an up-to-date `latest` pointer, and so `xcresulttool`/`xcodebuild` always
# write into a directory that has never existed before -- eliminating the
# result-bundle manifest collision that came from reusing one fixed path.
# ---------------------------------------------------------------------------
RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$RUNS_DIR/$RUN_TS"
SCREENSHOTS_DIR="$RUN_DIR/screenshots"
RESULT_BUNDLE="$RUN_DIR/${PHONE_UI_SUITE}.xcresult"
WATCH_RESULT_BUNDLE="$RUN_DIR/${WATCH_UI_SUITE}.xcresult"
mkdir -p "$SCREENSHOTS_DIR"
log "$APP_NAME run directory: $RUN_DIR"

# ---------------------------------------------------------------------------
# Resolve the named pair by parsing `xcrun simctl list devices --json` with
# the macOS-bundled /usr/bin/python3 (a system tool present on every Mac,
# not a project dependency). Exact name match, isAvailable == true only,
# scoped to the single newest installed runtime for the platform. More than
# one available match is a configuration error and fails loudly rather than
# silently picking one. Never falls back to creating a device.
# ---------------------------------------------------------------------------
DEVICES_JSON_FILE="$(mktemp -t free-lunch-acceptance-devices)"

if ! xcrun simctl list devices --json > "$DEVICES_JSON_FILE" 2>/dev/null; then
  log "FATAL: 'xcrun simctl list devices --json' failed -- cannot resolve simulator devices."
  exit 1
fi

resolve_udid() {
  local name="$1" platform="$2"
  /usr/bin/python3 - "$DEVICES_JSON_FILE" "$name" "$platform" <<'PYEOF'
import json
import sys

path, name, platform = sys.argv[1], sys.argv[2], sys.argv[3]

with open(path) as f:
    data = json.load(f)

devices = data.get("devices", {})
marker = "." + platform + "-"


def version_key(runtime_id):
    tail = runtime_id.rsplit(marker, 1)[-1]
    parts = []
    for chunk in tail.split("-"):
        try:
            parts.append(int(chunk))
        except ValueError:
            parts.append(0)
    return tuple(parts)


runtimes = [rid for rid in devices if marker in rid]
if not runtimes:
    print(f"no installed {platform} simulator runtime", file=sys.stderr)
    sys.exit(2)

newest = max(runtimes, key=version_key)

matches = [
    d for d in devices.get(newest, [])
    if d.get("name") == name and d.get("isAvailable") is True
]

if not matches:
    print(f"no available device named '{name}' in newest {platform} runtime {newest}", file=sys.stderr)
    sys.exit(1)

if len(matches) > 1:
    udids = ", ".join(m.get("udid", "?") for m in matches)
    print(
        f"ambiguous: {len(matches)} available devices named '{name}' in runtime {newest}: {udids}",
        file=sys.stderr,
    )
    sys.exit(3)

print(matches[0]["udid"])
PYEOF
}

# Resolver failures must never escape via `set -e` before we get a chance to
# print the device-specific FATAL message -- capture the outcome explicitly.
resolve_device_or_die() {
  local device_name="$1" platform="$2" outvar="$3"
  local udid rc

  if udid="$(resolve_udid "$device_name" "$platform")"; then
    rc=0
  else
    rc=$?
  fi

  if [ "$rc" -ne 0 ] || [ -z "$udid" ]; then
    case "$rc" in
      2)
        log "FATAL: no $platform simulator runtime is installed on this Mac -- cannot resolve '$device_name'."
        ;;
      3)
        log "FATAL: ambiguous device name '$device_name' -- more than one available $platform simulator matches. Refusing to guess."
        ;;
      *)
        log "FATAL: no available simulator named '$device_name' found via 'xcrun simctl list devices --json' (scoped to the newest $platform runtime)."
        ;;
    esac
    log "This script never creates simulators -- create/fix the dedicated '$device_name' device manually and re-run."
    exit 1
  fi

  printf -v "$outvar" '%s' "$udid"
}

resolve_device_or_die "$IPHONE_NAME" "iOS" IPHONE_UDID
resolve_device_or_die "$WATCH_NAME" "watchOS" WATCH_UDID
rm -f "$DEVICES_JSON_FILE"

log "resolved '$IPHONE_NAME' -> $IPHONE_UDID"
log "resolved '$WATCH_NAME' -> $WATCH_UDID"

# ---------------------------------------------------------------------------
# Boot the named pair (idempotent: -b boots only if not already booted).
# ---------------------------------------------------------------------------
xcrun simctl bootstatus "$IPHONE_UDID" -b
xcrun simctl bootstatus "$WATCH_UDID" -b

# A booted device is not yet a device xcodebuild can see. On fresh macos-26
# runners xcodebuild lists no simulators at all for a while after both boots
# finish, then every simulator appears at once; simctl sees them throughout.
# A sibling project's CI observed long visibility delays on GitHub macos-26
# runners, and neither -runFirstLaunch nor restarting CoreSimulatorService
# shortened them.
# Poll -showdestinations until the device appears (15 minutes is about twice
# the worst case seen), and fail with xcodebuild's own output and the simctl
# inventory instead of a bare destination error.
DESTINATION_WAIT_SECONDS=$((15 * 60))

wait_for_destination() {
  local scheme="$1" device_name="$2" udid="$3"
  local started=$SECONDS deadline=$((SECONDS + DESTINATION_WAIT_SECONDS)) destinations
  while true; do
    # Captured, not piped into `grep -q`: under pipefail an early grep exit
    # can SIGPIPE xcodebuild and turn a match into a failure.
    destinations="$(xcodebuild -showdestinations -project "$PROJECT" -scheme "$scheme" 2>&1 || true)"
    if [[ "$destinations" == *"id:$udid"* ]]; then
      log "xcodebuild sees '$device_name' after $((SECONDS - started))s"
      return 0
    fi
    if (( SECONDS >= deadline )); then
      log "FATAL: xcodebuild still cannot see '$device_name' ($udid) for $scheme after ${DESTINATION_WAIT_SECONDS}s; its last -showdestinations output and the simctl inventory follow."
      printf '%s\n' "$destinations" >&2
      xcrun simctl list devices >&2 || true
      exit 70
    fi
    log "waiting for xcodebuild to see '$device_name' ($udid) for $scheme ($((SECONDS - started))s so far)"
    sleep 15
  done
}

wait_for_destination "$PHONE_SCHEME" "$IPHONE_NAME" "$IPHONE_UDID"
wait_for_destination "$WATCH_SCHEME" "$WATCH_NAME" "$WATCH_UDID"

# ---------------------------------------------------------------------------
# Build both app targets.
# ---------------------------------------------------------------------------
log "building $PHONE_SCHEME on $IPHONE_NAME"
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$PHONE_SCHEME" \
  -destination "platform=iOS Simulator,id=$IPHONE_UDID" \
  "${COMMON_XCODEBUILD_FLAGS[@]}"

log "building $WATCH_SCHEME on $WATCH_NAME"
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$WATCH_SCHEME" \
  -destination "platform=watchOS Simulator,id=$WATCH_UDID" \
  "${COMMON_XCODEBUILD_FLAGS[@]}"

# ---------------------------------------------------------------------------
# Run the phone and watch UI test suites.
# Both run through this one script/lock so a change to either device's
# acceptance coverage never needs a second, parallel script.
#
# A suite that fails gets one bounded second pass. A sibling project's CI on
# GitHub macos-26 runners observed differing isolated UI-test failures: a
# dropped tap, a skip that never ran, and an accessibility-snapshot timing
# issue. Cause unproven, never the same test twice. So when a suite fails at
# most MAX_RETRIED_TESTS tests, exactly those
# run again in a fresh xcodebuild (its own result bundle, next to the first).
# The suite passes only if every one of them passes the second time. More
# failures than that, or a failure with no failed test (a crash or build
# error), is treated as real and stops the run. Every retried test is
# reported: a FLAKE log line, a GitHub Actions warning, a step-summary line,
# and a row in retried-tests.txt. FL_FAIL_ON_RETRY=1 fails the run on any
# retry instead, for measuring flakes.
# ---------------------------------------------------------------------------
MAX_RETRIED_TESTS=3
RETRIED_TESTS_COUNT=0

# Prints one "Class/testMethod()" line per failed test case in a bundle.
failed_tests() {
  xcrun xcresulttool get test-results tests --path "$1" --compact \
    | /usr/bin/python3 -I -c '
import json, sys
def walk(node):
    if node.get("nodeType") == "Test Case":
        if node.get("result") == "Failed":
            print(node["nodeIdentifier"])
        return
    for child in node.get("children", []):
        walk(child)
for node in json.load(sys.stdin).get("testNodes", []):
    walk(node)
'
}

# run_ui_suite SUITE SCHEME DESTINATION BUNDLE
run_ui_suite() {
  local suite="$1" scheme="$2" destination="$3" bundle="$4"
  local retry_bundle="${bundle%.xcresult}-retry.xcresult"
  local rc=0 failed count only_testing test outcome

  xcodebuild test \
    -project "$PROJECT" \
    -scheme "$scheme" \
    -destination "$destination" \
    -resultBundlePath "$bundle" \
    -only-testing:"$suite" \
    "${COMMON_XCODEBUILD_FLAGS[@]}" || rc=$?
  [ "$rc" -eq 0 ] && return 0

  failed="$(failed_tests "$bundle" 2>/dev/null || true)"
  count="$(printf '%s' "$failed" | grep -c . || true)"
  if [ "$count" -eq 0 ]; then
    log "$suite failed (exit $rc) with no failed test in its result bundle; not retrying"
    return "$rc"
  fi
  if [ "$count" -gt "$MAX_RETRIED_TESTS" ]; then
    log "$suite failed $count tests, more than $MAX_RETRIED_TESTS; treating it as a real failure, not retrying"
    return "$rc"
  fi

  only_testing=""
  while IFS= read -r test; do
    only_testing="$only_testing -only-testing:$suite/${test%()}"
  done <<< "$failed"
  log "$suite failed $count test(s); running them once more:$only_testing"

  rc=0
  # shellcheck disable=SC2086 # only_testing is one word per test, by construction.
  xcodebuild test \
    -project "$PROJECT" \
    -scheme "$scheme" \
    -destination "$destination" \
    -resultBundlePath "$retry_bundle" \
    $only_testing \
    "${COMMON_XCODEBUILD_FLAGS[@]}" || rc=$?

  while IFS= read -r test; do
    if [ "$rc" -eq 0 ]; then
      outcome="passed on retry"
      RETRIED_TESTS_COUNT=$((RETRIED_TESTS_COUNT + 1))
    else
      outcome="and the retry run failed; see $(basename "$retry_bundle")"
    fi
    log "FLAKE $suite/$test: failed once, $outcome"
    printf '%s\t%s\t%s\n' "$suite" "$test" "$outcome" >> "$RUN_DIR/retried-tests.txt"
    # A workflow command on stdout shows as a warning on the GitHub run.
    printf '::warning title=Retried UI test::%s/%s failed once, %s\n' "$suite" "$test" "$outcome"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      printf -- '- Retried UI test `%s/%s`: failed once, %s\n' "$suite" "$test" "$outcome" >> "$GITHUB_STEP_SUMMARY"
    fi
  done <<< "$failed"
  return "$rc"
}

assert_suite_ran() {
  local suite="$1" bundle="$2" retry_bundle stats passed failed
  retry_bundle="${bundle%.xcresult}-retry.xcresult"

  if [ ! -d "$bundle" ]; then
    log "FATAL: $suite did not produce its result bundle: $bundle"
    exit 1
  fi

  stats="$(xcrun xcresulttool get test-results summary --path "$bundle" --compact | /usr/bin/python3 -I -c '
import json
import sys

summary = json.load(sys.stdin)
passed = summary.get("passedTests")
failed = summary.get("failedTests")
if not isinstance(passed, int) or not isinstance(failed, int):
    raise SystemExit("result summary is missing integer passedTests or failedTests")
print(f"{passed}\t{failed}")
')" || {
    log "FATAL: could not read the result summary for $suite: $bundle"
    exit 1
  }
  IFS=$'\t' read -r passed failed <<< "$stats"

  if [ "$failed" -ne 0 ]; then
    if [ ! -d "$retry_bundle" ]; then
      log "FATAL: $suite first result reports failures but its retry bundle is missing: $retry_bundle"
      exit 1
    fi
    log "$suite first result reports $failed failure(s); retry bundle exists, skipping first-result test-count check"
    return 0
  fi

  if [ "$passed" -lt 1 ]; then
    log "FATAL: $suite ran zero passing test cases according to $bundle"
    exit 1
  fi
  log "$suite result reports $passed passing test case(s)"
}

log "running $PHONE_UI_SUITE on $IPHONE_NAME"
run_ui_suite "$PHONE_UI_SUITE" "$PHONE_SCHEME" "platform=iOS Simulator,id=$IPHONE_UDID" "$RESULT_BUNDLE"
assert_suite_ran "$PHONE_UI_SUITE" "$RESULT_BUNDLE"

log "running $WATCH_UI_SUITE on $WATCH_NAME"
run_ui_suite "$WATCH_UI_SUITE" "$WATCH_SCHEME" "platform=watchOS Simulator,id=$WATCH_UDID" "$WATCH_RESULT_BUNDLE"
assert_suite_ran "$WATCH_UI_SUITE" "$WATCH_RESULT_BUNDLE"

if [ "$RETRIED_TESTS_COUNT" -gt 0 ]; then
  log "WARNING: $RETRIED_TESTS_COUNT UI test(s) passed only on retry; see retried-tests.txt"
  if [ "${FL_FAIL_ON_RETRY:-0}" = 1 ]; then
    log "FATAL: FL_FAIL_ON_RETRY=1 and a UI test needed a retry"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Export screenshots/attachments for digest reports.
#
# One subdirectory per suite, not a shared one: `xcresulttool export
# attachments` writes its own manifest.json into --output-path, and a
# second invocation against the same directory fails outright ("file
# already exists") without exporting anything of its own -- discovered the
# hard way when the second UI suite was added here (both suites' PNGs used to
# land, but only the first suite's manifest.json survived). Separate
# directories give each suite its own manifest and both PNG sets survive.
# ---------------------------------------------------------------------------
PHONE_SCREENSHOTS_DIR="$SCREENSHOTS_DIR/phone"
WATCH_SCREENSHOTS_DIR="$SCREENSHOTS_DIR/watch"
mkdir -p "$PHONE_SCREENSHOTS_DIR" "$WATCH_SCREENSHOTS_DIR"

log "exporting screenshots to $SCREENSHOTS_DIR"
xcrun xcresulttool export attachments \
  --path "$RESULT_BUNDLE" \
  --output-path "$PHONE_SCREENSHOTS_DIR"
xcrun xcresulttool export attachments \
  --path "$WATCH_RESULT_BUNDLE" \
  --output-path "$WATCH_SCREENSHOTS_DIR"

log "screenshots exported:"
find "$SCREENSHOTS_DIR" -type f -print >&2
