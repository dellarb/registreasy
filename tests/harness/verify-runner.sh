#!/usr/bin/env bash
# Offline check of tests/run-tests.sh. It copies the real runner into a
# throwaway directory and replaces ONLY the two execution hooks, so the
# planning, timeout, analysis and reporting code under test is the real code.
# Nothing runs for real, no container is needed and the repository is untouched.
#
#   bash tests/harness/verify-runner.sh          # exit 1 on a design defect
#   bash tests/harness/verify-runner.sh --keep   # keep the throwaway runs
#
# Fixtures (tests/harness/fixtures/), each records-*.log paired with raw-*.txt:
#   genuine       a captured run with two probes: a failing assertion and a
#                 crash record; the run has one PASS, one FAIL, one CRASH
#   synthetic-crash  the same run with a CRASH in the middle and engine output
#   runner-death  BEGIN with no TEST record: the runner died in a test
#   load-failure  a whole file that failed to import (never gets a BEGIN)
#   clean         all green: the summary must say PASS
#   smoke-failure the smoke suite failing at one named check
set -Eeuo pipefail
trap 'echo "harness error at line $LINENO" >&2' ERR

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURES="$ROOT/tests/harness/fixtures"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

WORK="$(mktemp -d)"
trap '(( KEEP )) || rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$*" >&2; }
check() {  # check <description> <command...>
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then ok "$description"; else bad "$description"; fi || true
}
grep_check() {  # grep_check <description> <pattern> <file>
    local description="$1" pattern="$2" file="$3"
    if grep -qP -e "$pattern" "$file" 2>/dev/null; then ok "$description"; else
        bad "$description (no /$pattern/ in ${file#"$WORK"/})"
    fi || true
}
absent_check() {  # absent_check <description> <pattern> <file>
    if grep -qP -e "$2" "$3" 2>/dev/null; then bad "$1 (found /$2/ in ${3#"$WORK"/})"; else ok "$1"; fi || true
}

# ---------------------------------------------------------------- sandbox ----
make_sandbox() {  # make_sandbox <name> -> prints the sandbox path
    local name="$1" dir="$WORK/$name"
    mkdir -p "$dir/tests/harness" "$dir/tests/support"
    cp "$ROOT/tests/run-tests.sh" "$dir/tests/run-tests.sh"
    cp -r "$FIXTURES" "$dir/tests/harness/fixtures"
    printf '%s\n' 'tests/.test-runs/' >"$dir/.gitignore"
    # Stand-in for the test executable: answers --list so the runner can plan.
    cat >"$dir/tests/support/record_runner.py" <<'FAKE'
import sys

if "--list" in sys.argv:
    print(open("tests/harness/planned.txt").read().strip())
    sys.exit(0)
sys.exit("fake record_runner: the harness replaces the execution step")
FAKE
    git -C "$dir" init -q
    git -C "$dir" config user.email harness@example.invalid
    git -C "$dir" config user.name harness
    echo "$dir"
}

# Replace only the two execution hooks the runner exposes.
patch_execution() {  # patch_execution <sandbox> <records fixture> <raw fixture>
    python3 - "$1/tests/run-tests.sh" "$2" "$3" <<'PY'
import sys

path, records, raw = sys.argv[1:4]
source = open(path).read()

stub = (
    "test_execute_unit() {  # harness stub: the real execution step is replaced\n"
    f"    cat {raw!r}\n"
    "    return 0\n"
    "}\n"
    "test_execute_smoke() {\n"
    "    return 0\n"
    "}\n"
)
anchor = ("# The harness overrides these two names; nothing else in the runner changes.\n"
          "test_execute_unit() { execute_unit; }\n"
          "test_execute_smoke() { execute_smoke; }\n")
assert anchor in source, "execution hooks not found in the runner"
source = source.replace(anchor, stub.split("\n", 1)[0] + "\n" + stub.split("\n", 1)[1])

# Records come from the fixture, not from whatever the stub printed.
source = source.replace('cat "$RUN/unit.out" >>"$RUN/records.txt"',
                        'cat ' + repr(records) + ' >>"$RUN/records.txt"')

open(path, "w").write(source)
PY
}

RUN_SEQ=0
run_case() {  # run_case <name> <records fixture> <raw fixture> [planned id...]
    local name="$1" records="$2" raw="$3"
    RUN_SEQ=$((RUN_SEQ + 1))
    shift 3
    CASE_DIR="$(make_sandbox "$name")"
    printf '%s\n' "$@" >"$CASE_DIR/tests/harness/planned.txt"
    patch_execution "$CASE_DIR" "$FIXTURES/$records" "$FIXTURES/$raw"
    git -C "$CASE_DIR" add -A && git -C "$CASE_DIR" commit -qm sandbox --allow-empty
    local status=0
    ( cd "$CASE_DIR" && FIXTURE_TAG="-$name-$RUN_SEQ" bash tests/run-tests.sh ) \
        >"$WORK/$name.stdout" 2>"$WORK/$name.stderr" || status=$?
    CASE_STATUS=$status
    git -C "$CASE_DIR" add -A && git -C "$CASE_DIR" commit -qm "after $name" --allow-empty

    if [[ ! -s "$CASE_DIR/tests/.test-runs/latest/summary.txt" ]]; then
        bad "$name: the runner stopped before writing its report (see $WORK/$name.stderr)"
        printf '\n%d checks passed, %d failed\n' "$pass" "$fail"
        exit 1
    fi
    local untracked
    untracked="$( { git -C "$CASE_DIR" status --porcelain | grep -v 'tests/.test-runs' || true; } | wc -l)"
    check "$name: the run folder leaves the working tree clean" test "$untracked" -eq 0
}

run_in_case() {  # run_in_case <case dir> <suffix> [args...] -> stdout file on $RUN_OUT
    local dir="$1" suffix="$2"
    shift 2
    RUN_OUT="$WORK/out-$suffix.txt"
    ( cd "$dir" && FIXTURE_TAG="-$suffix" bash tests/run-tests.sh "$@" ) >"$RUN_OUT" 2>&1 || true
    git -C "$dir" add -A && git -C "$dir" commit -qm "$suffix" --allow-empty
}

latest() { echo "$CASE_DIR/tests/.test-runs/latest"; }

assert_layout() {  # assert_layout <name>
    local name="$1" run file
    run="$(latest)"
    for file in summary.txt failures.txt failures.tsv raw.txt records.txt meta.txt tests.txt history.tsv; do
        check "$name: $file written" test -f "$run/$file"
    done
    check "$name: one log per test in detail/" test -d "$run/detail"
    check "$name: latest is a symlink" test -L "$CASE_DIR/tests/.test-runs/latest"
    check "$name: the plan file is cleaned up" test ! -e "$run/tmp"
    grep_check "$name: meta has the run id" '^run_id: \S+' "$run/meta.txt"
    grep_check "$name: meta has the git sha" '^git_sha: [0-9a-f]' "$run/meta.txt"
    grep_check "$name: meta has the dirty state" '^git_dirty_files: [0-9]+' "$run/meta.txt"
    grep_check "$name: meta has the elapsed time" '^elapsed_s: [0-9.]+' "$run/meta.txt"
    grep_check "$name: history.tsv has a header" '^# run\t' "$run/history.tsv"
    grep_check "$name: the summary says where the run is" '^  run     \S*' "$run/summary.txt"
}

GENUINE_IDS=(
    tests/test_auth.py::SessionStoreTest.test_create_and_get
    tests/test_auth.py::SessionStoreTest.test_delete
    tests/test_auth.py::SessionStoreTest.test_idle_timeout_and_sliding_refresh
    tests/test_auth.py::ThrottleTest.test_client_lockout_then_recovery
    tests/test_inventory_metadata.py::ManifestMetadataTest.test_size_for_selected_platform
)

# ------------------------------------------- 1. a captured run with failures
run_case genuine records-genuine.log raw-genuine.txt "${GENUINE_IDS[@]}"
assert_layout genuine
run="$(latest)"
check "genuine: non-zero exit status when tests fail" test "$CASE_STATUS" -eq 1
check "genuine: stdout is exactly the summary" diff -q "$WORK/genuine.stdout" "$run/summary.txt"
check "genuine: the summary is short" test "$(wc -l <"$run/summary.txt")" -le 20
grep_check "genuine: PASS, FAIL and CRASH are counted separately" \
    '3 passed, 1 failed, 1 error/crash, 5 tests' "$run/summary.txt"
grep_check "genuine: result is FAIL" 'result   FAIL' "$run/summary.txt"
grep_check "genuine: the first failure is inline with its source line" \
    'at tests/test_auth.py:44: expected None' "$run/summary.txt"
grep_check "genuine: failures.txt names the failing test" \
    '^FAIL tests/test_auth.py::SessionStoreTest.test_delete' "$run/failures.txt"
grep_check "genuine: failures.txt keeps expected/got" 'expected None, got' "$run/failures.txt"
grep_check "genuine: failures.txt names the crashed test" \
    '^CRASH tests/test_auth.py::ThrottleTest.test_client_lockout_then_recovery' "$run/failures.txt"
grep_check "genuine: failures.txt points at the log" 'log: detail/tests_test_auth/' "$run/failures.txt"
grep_check "genuine: failures.tsv is machine readable" \
    '^FAIL\ttests/test_auth.py::SessionStoreTest.test_delete\ttests/test_auth.py\t44\t' "$run/failures.tsv"
check "genuine: one detail log per test" test "$(find "$run/detail" -name '*.log' | wc -l)" -eq 5
grep_check "genuine: a passing test's log shows its record" \
    'TEST PASS tests/test_auth.py::SessionStoreTest.test_create_and_get' \
    "$run/detail/tests_test_auth/SessionStoreTest.test_create_and_get.log"
grep_check "genuine: notes are attributed to their test" 'NOTE .*deleting a token' \
    "$run/detail/tests_test_auth/SessionStoreTest.test_delete.log"
grep_check "genuine: a crash without an ASSERT line still shows its log" 'tests/test_auth.py:87' \
    "$run/detail/tests_test_auth/ThrottleTest.test_client_lockout_then_recovery.log"
grep_check "genuine: the framework's own output stays in raw.txt" 'FAILED \(failures=1' "$run/raw.txt"
grep_check "genuine: no count mismatch when records agree" '^count_mismatch: no$' "$run/meta.txt"
absent_check "genuine: no COUNT MISMATCH on a consistent run" 'COUNT MISMATCH' "$run/summary.txt"
grep_check "genuine: tests.txt lists each test with its log" \
    '^PASS\ttests/test_auth.py::SessionStoreTest.test_create_and_get\tdetail/' "$run/tests.txt"
check "genuine: history.tsv has one row per test" test "$(wc -l <"$run/history.tsv")" -eq 6

run_in_case "$CASE_DIR" last --last
check "genuine: --last reprints summary.txt" diff -q "$run/summary.txt" "$RUN_OUT"
run_in_case "$CASE_DIR" full --full SessionStoreTest.test_delete
grep_check "genuine: --full prints that test's log" \
    'TEST FAIL tests/test_auth.py::SessionStoreTest.test_delete' "$RUN_OUT"
grep_check "genuine: --full names the file it printed" 'SessionStoreTest.test_delete.log' "$RUN_OUT"
run_in_case "$CASE_DIR" fullbad --full nosuchtest
grep_check "genuine: --full with an unknown test fails loudly" 'no test matching' "$RUN_OUT"

printf '%s\n' tests/test_auth.py::SessionStoreTest.test_delete >"$CASE_DIR/tests/harness/planned.txt"
run_in_case "$CASE_DIR" exact tests/test_auth.py::SessionStoreTest.test_delete
grep_check "genuine: the exact-id form runs the one test it was given" '5 tests' "$RUN_OUT"
grep_check "genuine: the summary records which filter ran" \
    'filter: tests/test_auth.py::SessionStoreTest.test_delete' "$RUN_OUT"

# ------------------------------------- 2. CRASH in the middle of the run
run_case crash records-synthetic-crash.log raw-genuine-crash.txt "${GENUINE_IDS[@]}"
assert_layout crash
run="$(latest)"
check "crash: non-zero exit status" test "$CASE_STATUS" -eq 1
grep_check "crash: CRASH is counted apart from FAIL" '1 failed, 1 error/crash' "$run/summary.txt"
grep_check "crash: the crashing test is listed" \
    '^CRASH tests/test_auth.py::ThrottleTest.test_client_lockout_then_recovery' "$run/failures.txt"
grep_check "crash: its last engine line is in the log" \
    'RuntimeError: throttle state was corrupted mid-test' \
    "$run/detail/tests_test_auth/ThrottleTest.test_client_lockout_then_recovery.log"
grep_check "crash: tests around it are unaffected" \
    '^PASS\ttests/test_auth.py::SessionStoreTest.test_idle_timeout_and_sliding_refresh' "$run/tests.txt"
grep_check "crash: the framework output is kept verbatim" 'FAILED \(failures=1' "$run/raw.txt"

# ---------------------------- 3. runner death: a bracket with no TEST record
run_case death records-runner-death.log raw-runner-death.txt \
    tests/test_auth.py::SessionStoreTest.test_create_and_get \
    tests/test_auth.py::SessionStoreTest.test_delete
assert_layout death
run="$(latest)"
check "death: non-zero exit status" test "$CASE_STATUS" -eq 1
grep_check "death: the open bracket is ERROR, never a pass" \
    '^ERROR tests/test_auth.py::SessionStoreTest.test_delete' "$run/failures.txt"
grep_check "death: the engine's last frame gives the source line" \
    'tests/test_auth.py:41: runner died inside this test' "$run/failures.txt"
absent_check "death: the dead test is not recorded as PASS" \
    '^PASS\ttests/test_auth.py::SessionStoreTest.test_delete$' "$run/tests.txt"
grep_check "death: the test before it still passes" \
    '^PASS\ttests/test_auth.py::SessionStoreTest.test_create_and_get' "$run/tests.txt"
grep_check "death: its notes are kept for diagnosis" 'about to lose the interpreter' "$run/failures.txt"

# ------------------------------- 4. a whole file that failed to import
run_case load records-load-failure.log raw-load-failure.txt \
    tests/test_auth.py::SessionStoreTest.test_create_and_get \
    tests/test_inventory_metadata.py::ManifestMetadataTest.test_size_for_selected_platform
run="$(latest)"
check "load: non-zero exit status" test "$CASE_STATUS" -eq 1
grep_check "load: the file that failed to import is its own CRASH" \
    '^CRASH tests/test_inventory_metadata.py' "$run/failures.txt"
absent_check "load: it is not blamed on the previous test" \
    'SessionStoreTest\.test_create_and_get\t.*(FAIL|ERROR|CRASH)' "$run/failures.tsv"
grep_check "load: COUNT MISMATCH is reported" 'COUNT MISMATCH' "$run/summary.txt"
grep_check "load: the counts are marked unreliable" 'all counts unreliable' "$run/summary.txt"
grep_check "load: the test that never reported is named" \
    'missing records: tests/test_inventory_metadata.py::ManifestMetadataTest.test_size_for_selected_platform' \
    "$run/summary.txt"
grep_check "load: meta records the mismatch" '^count_mismatch: yes$' "$run/meta.txt"

# ------------------------------------------------------------ 5. clean run
run_case clean records-clean.log raw-clean.txt \
    tests/test_inventory_metadata.py::RegistrySizeTest.test_stored_files_and_empty_registry \
    tests/test_inventory_metadata.py::RegistrySizeTest.test_unreadable_registry_is_unavailable
assert_layout clean
run="$(latest)"
check "clean: exit status is zero" test "$CASE_STATUS" -eq 0
grep_check "clean: the summary says PASS" 'result   PASS' "$run/summary.txt"
grep_check "clean: no failures" 'failures none' "$run/summary.txt"
grep_check "clean: failures.txt says so" '^no failures$' "$run/failures.txt"
check "clean: failures.tsv holds only its header" test "$(wc -l <"$run/failures.tsv")" -eq 1
grep_check "clean: notes are still attributed" 'permission error expected' \
    "$run/detail/tests_test_inventory_metadata/RegistrySizeTest.test_unreadable_registry_is_unavailable.log"
check "clean: history.tsv has one row per test plus its header" test "$(wc -l <"$run/history.tsv")" -eq 3

# ------------------------------------------------ 6. the smoke suite failing
run_case smoke-failure records-smoke-failure.log raw-smoke-failure.txt
run="$(latest)"
check "smoke: non-zero exit status" test "$CASE_STATUS" -eq 1
grep_check "smoke: the failing check is listed with file:line" \
    '^FAIL pull user cannot start an upload' "$run/failures.txt"
grep_check "smoke: expected/got is kept" 'expected 403, got 200' "$run/failures.txt"
grep_check "smoke: its log shows what the check saw" 'FAIL: pull user cannot start an upload' \
    "$run/detail/smoke/pull_user_cannot_start_an_upload.log"
grep_check "smoke: passing checks are recorded too" '^PASS\tanonymous read challenged' "$run/tests.txt"

# -------------------------------------------------------------- 7. --prune
for n in 1 2 3 4; do
    ( cd "$CASE_DIR" && FIXTURE_TAG="-extra-$RUN_SEQ-$n" bash tests/run-tests.sh >/dev/null 2>&1 || true )
    git -C "$CASE_DIR" add -A && git -C "$CASE_DIR" commit -qm "extra $n" --allow-empty
done
before="$(find "$CASE_DIR/tests/.test-runs" -maxdepth 1 -mindepth 1 -type d | wc -l)"
( cd "$CASE_DIR" && bash tests/run-tests.sh --prune --keep 2 ) >"$WORK/prune.stdout" 2>&1 || true
after="$(find "$CASE_DIR/tests/.test-runs" -maxdepth 1 -mindepth 1 -type d | wc -l)"
grep_check "prune: says what it removed" 'pruned [0-9]+ run' "$WORK/prune.stdout"
check "prune: keeps exactly --keep runs (had $before run folders, now $after)" test "$after" -eq 2
check "prune: latest still points at a kept run" test -d "$CASE_DIR/tests/.test-runs/latest"
check "prune: the ledger stays at the top level" test -f "$CASE_DIR/tests/.test-runs/history.tsv"
grep_check "prune: the ledger keeps rows of pruned runs" 'extra-' "$CASE_DIR/tests/.test-runs/history.tsv"
check "prune: runs are kept unless asked to prune" test "$after" -lt "$before"

# ------------------------------------------------------- 8. argument errors
( cd "$CASE_DIR" && bash tests/run-tests.sh 'no-such-test' ) >/dev/null 2>"$WORK/nofilter.stderr" || true
grep_check "arguments: a filter that matches nothing fails loudly" 'no test matches' "$WORK/nofilter.stderr"
check "arguments: an unknown flag fails loudly" \
    bash -c "cd '$CASE_DIR' && ! bash tests/run-tests.sh --nope >/dev/null 2>&1"
check "arguments: --last without any run fails loudly" \
    bash -c "cd '$CASE_DIR' && mv tests/.test-runs tests/.test-runs.bak && ! bash tests/run-tests.sh --last >/dev/null 2>&1; mv tests/.test-runs.bak tests/.test-runs"

# ---------------------------------------------------------------- verdict
printf '\n%d checks passed, %d failed\n' "$pass" "$fail"
if (( fail > 0 )); then
    rm -rf /tmp/registreasy-harness-failed
    cp -r "$WORK" /tmp/registreasy-harness-failed 2>/dev/null || true
    echo "workspace kept at /tmp/registreasy-harness-failed" >&2
    exit 1
fi
