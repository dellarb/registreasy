#!/usr/bin/env bash
# Run the test suite once and write everything to a per-run folder. Read the
# folder afterwards instead of running the suite again.
#
#   bash tests/run-tests.sh                       # unit tests (no container)
#   bash tests/run-tests.sh smoke                 # unit tests + HTTP checks in tests/smoke.sh
#   bash tests/run-tests.sh 'test_auth'           # substring filter on test ids
#   bash tests/run-tests.sh 'tests/test_auth.py::SessionStoreTest.test_delete'   # exact id
#   bash tests/run-tests.sh --last                # reprint the newest run's summary
#   bash tests/run-tests.sh --full <test>         # one test's log from the newest run
#   bash tests/run-tests.sh --prune --keep 5      # keep the 5 newest runs
#   SMOKE_ENDPOINT=http://127.0.0.1:5000 PUSH_PASSWORD=... PULL_PASSWORD=... \
#     bash tests/run-tests.sh smoke
#
# Everything verbose lands in tests/.test-runs/<timestamp>/:
#   summary.txt          short report (teed to stdout)
#   failures.txt         every failure with test identity and source line
#   failures.tsv         the same, tab separated, for tools
#   detail/<suite>/*.log one file per test / per check
#   raw.txt              verbatim stdout/stderr of the executables
#   records.txt          the machine records the executables printed
#   meta.txt tests.txt history.tsv
# tests/.test-runs/latest is a symlink to the newest run.
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
LOGS_GITIGNORE=tests/.test-runs
LOGS="$ROOT/$LOGS_GITIGNORE"
RUN_TIMEOUT="${TEST_TIMEOUT:-600}"
FILTER=""            # substring or substring:substring on test ids
SMOKE=0              # include tests/smoke.sh
SHOW_LAST=0
SHOW_FULL=""
PRUNE=0
KEEP=10
FAILFAST="${TEST_FAILFAST:-0}"
SMOKE_ENDPOINT="${SMOKE_ENDPOINT:-http://127.0.0.1:5000}"

usage() { sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --last) SHOW_LAST=1; shift ;;
        --full) SHOW_FULL="${2:?--full needs a test id, see tests.txt}"; shift 2 ;;
        --prune) PRUNE=1; shift ;;
        --keep) KEEP="${2:?--keep needs a number}"; shift 2 ;;
        --smoke) SMOKE=1; shift ;;
        --failfast) FAILFAST=1; shift ;;
        --timeout) RUN_TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "run-tests.sh: unknown option $1" >&2; exit 2 ;;
        *) FILTER="$1"; [[ "$FILTER" == smoke ]] && SMOKE=1; shift ;;
    esac
done

newest_run() {
    # The symlink is the source of truth, so runs copied elsewhere still work.
    local link
    link="$(readlink -f "$LOGS/latest" 2>/dev/null || true)"
    if [[ -n "$link" && -d "$link" ]]; then echo "$link"; return 0; fi
    local last
    last="$(ls -1d "$LOGS"/*/ 2>/dev/null | sort | tail -1)" || true
    [[ -n "$last" ]] || return 1
    echo "${last%/}"
}

if [[ "$SHOW_LAST" == 1 ]]; then
    run="$(newest_run)" || { echo "run-tests.sh: no runs yet" >&2; exit 1; }
    cat "$run/summary.txt"
    exit 0
fi

if [[ -n "$SHOW_FULL" ]]; then
    run="$(newest_run)" || { echo "run-tests.sh: no runs yet" >&2; exit 1; }
    file="$(awk -F'\t' -v want="$SHOW_FULL" '
        $2 == want { print $3; found = 1; exit }
        index($2, want) && !partial { print $3; partial = 1 }
    ' "$run/tests.txt" | head -1)"
    if [[ -z "$file" || ! -f "$run/$file" ]]; then
        echo "run-tests.sh: no test matching '$SHOW_FULL' in $(basename "$run"); see $run/tests.txt" >&2
        exit 1
    fi
    printf '==> %s\n\n' "$file"
    cat "$run/$file"
    exit 0
fi

# Keep the run folders out of git without editing people's tree unnecessarily.
if ! git check-ignore -q "$LOGS_GITIGNORE/" 2>/dev/null; then
    grep -qxF "$LOGS_GITIGNORE/" .gitignore 2>/dev/null || printf '%s/\n' "$LOGS_GITIGNORE" >>.gitignore
fi

if [[ "$PRUNE" == 1 ]]; then
    # Real run folders only: the latest symlink also ends in "/" and must not be
    # counted or removed. Newest last, so the newest survive.
    mapfile -t runs < <(find "$LOGS" -maxdepth 1 -mindepth 1 -type d ! -name latest -printf '%f\n' | sort)
    total="${#runs[@]}"
    if (( total > KEEP )); then
        for ((i = 0; i < total - KEEP; i++)); do rm -rf "${LOGS:?}/${runs[$i]}"; done
        echo "pruned $((total - KEEP)) run(s), kept $KEEP"
    else
        echo "nothing to prune ($total run(s), keeping $KEEP)"
    fi
    exit 0
fi

# ---------------------------------------------------------------- setup ----
# Milliseconds keep the sort order stable when two runs start in the same second.
# FIXTURE_TAG is only set by tests/harness/verify-runner.sh, which starts many
# runs inside the same second.
STAMP="$(date -u +%Y%m%dT%H%M%S.%3NZ)"${FIXTURE_TAG:-}
RUN="$LOGS/$STAMP"
RUN_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_COMMAND="bash tests/run-tests.sh$(for a in "$@"; do printf ' %q' "$a"; done)"
mkdir -p "$RUN/detail" "$RUN/tmp"
ln -sfn "$RUN" "$LOGS/latest"
: >"$RUN/records.txt"
: >"$RUN/failures.txt"
: >"$RUN/failures.tsv"
: >"$RUN/tests.txt"
: >"$RUN/tmp/expected.tsv"
: >"$RUN/summary.txt"
RAW="$RUN/raw.txt"
: >"$RAW"
UNIT_IDS="$RUN/tmp/unit-ids.txt"

cleanup_children() {
    local pid
    for pid in $(jobs -p); do kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true; done
}
trap cleanup_children EXIT

T0="${EPOCHREALTIME:-$(date +%s.%N)}"; T0="${T0/,/.}"
elapsed_s() { awk -v t="${EPOCHREALTIME/,/.}" -v a="$T0" 'BEGIN { printf "%.1f", t - a }'; }

git_sha="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
git_top="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
git_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
git_dirty="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
git_subject="$(git log -1 --format=%s 2>/dev/null || echo unknown)"
cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo '?')"
mem="$(awk '/MemTotal/ { printf "%.0f MB", $2 / 1024 }' /proc/meminfo 2>/dev/null || echo '?')"
os_name="$(uname -srm)"

# ------------------------------------------------------- test inventory ----
# Plan: which tests exist. A filter matching nothing is an error, not a pass.
mapfile -t all_ids < <(python3 tests/support/record_runner.py --list 2>/dev/null | sort)
if (( ${#all_ids[@]} == 0 )); then
    echo "run-tests.sh: no unit tests discovered under tests/" >&2
    exit 1
fi

matches_filter() {  # matches_filter <id>
    [[ -z "$FILTER" || "$FILTER" == smoke ]] && return 0
    if [[ "$FILTER" == *::* ]]; then
        [[ "$1" == "$FILTER" ]]
    else
        [[ "$1" == *"$FILTER"* ]]
    fi
}

selected=()
for id in "${all_ids[@]}"; do
    matches_filter "$id" && selected+=("$id")
done
plan_smoke=0
if [[ "$SMOKE" == 1 || "$FILTER" == smoke ]]; then plan_smoke=1; fi
if (( ${#selected[@]} == 0 && plan_smoke == 0 )); then
    echo "run-tests.sh: no test matches '$FILTER' (see tests/run-tests.sh --help)" >&2
    exit 1
fi
for id in "${selected[@]}"; do printf 'unit\t%s\n' "$id" >>"$RUN/tmp/expected.tsv"; done
# The unit run takes this exact list, so a run costs one discovery, not two.
printf '%s\n' "${selected[@]}" >"$RUN/tmp/unit-ids.txt"
(( plan_smoke == 1 )) && printf 'smoke\ttests/smoke.sh\n' >>"$RUN/tmp/expected.tsv"

# ------------------------------------------------------------ execution ----
# The execution step is isolated so tests/harness/verify-runner.sh can replace
# it while testing the reporting layer offline. Keep it a plain call that
# returns: bash 5.2 treats "exec" inside a function whose caller redirects
# output as an exit of the whole script.
execute_unit() {
    local args=(--run-listed "$UNIT_IDS")
    [[ "$FAILFAST" == 1 ]] && args+=(--failfast)
    timeout --kill-after=10 "$RUN_TIMEOUT" python3 tests/support/record_runner.py "${args[@]}"
}
execute_smoke() {
    timeout --kill-after=10 "$RUN_TIMEOUT" bash tests/smoke.sh "$SMOKE_ENDPOINT"
}

# The harness overrides these two names; nothing else in the runner changes.
test_execute_unit() { execute_unit; }
test_execute_smoke() { execute_smoke; }

run_unit() {
    echo "### unit: ${FILTER:+filter '$FILTER' }timeout ${RUN_TIMEOUT}s (stderr below)" >>"$RAW"
    # stdout stays quiet: the raw log and records get everything, the summary
    # is printed once at the end.
    test_execute_unit >"$RUN/unit.out" 2>"$RUN/unit.err"
    local status=$?
    cat "$RUN/unit.out" >>"$RAW"
    cat "$RUN/unit.err" >>"$RAW"
    cat "$RUN/unit.out" >>"$RUN/records.txt"
    return "$status"
}

run_smoke() {
    echo "### smoke: bash tests/smoke.sh $SMOKE_ENDPOINT (timeout ${RUN_TIMEOUT}s)" >>"$RAW"
    test_execute_smoke >"$RUN/smoke.out" 2>"$RUN/smoke.err"
    local status=$?
    cat "$RUN/smoke.out" >>"$RAW"
    cat "$RUN/smoke.err" >>"$RAW"
    cat "$RUN/smoke.out" >>"$RUN/records.txt"
    return "$status"
}

smoke_requested="$plan_smoke"
set +e
if (( ${#selected[@]} > 0 )); then
    run_unit; unit_status=$?
else
    unit_status=0
fi
smoke_status=0
if (( plan_smoke == 1 )); then
    run_smoke; smoke_status=$?
fi
set -e

# A killed runner (timeout, crash, signal) leaves a bracket open and never gets
# to print SUMMARY; name that bracket before the analyser looks at it.
if ! grep -q '^SUMMARY ' "$RUN/records.txt" && grep -q '^BEGIN ' "$RUN/records.txt"; then
    # An empty owner means the run was killed between a test's TEST record and
    # the next BEGIN, so the analyser keeps the unfinished bracket itself.
    bracket_owner="$(awk '/^BEGIN /{owner=$2} /^TEST /{owner=""} END{print owner}' "$RUN/records.txt")"
    bracket_owner="${bracket_owner:-tests/support/record_runner.py}"
    case "$unit_status" in
        124|137) why="the suite was killed after ${RUN_TIMEOUT}s (TEST_TIMEOUT / --timeout)" ;;
        *)      why="the runner exited with status $unit_status before finishing" ;;
    esac
    # Owned by the open bracket (the analyser attributes a NOTE from an unknown
    # owner to that bracket), so the test that was running when it stopped is the
    # one reported as unfinished.
    printf 'NOTE %s tests/run-tests.sh:1: %s\n' "$bracket_owner" "$why" >>"$RUN/records.txt"
fi

# ------------------------------------------------------------- analysis ----
# Exactly one parser. It reads only the records above (BEGIN/TEST/CHECK/ASSERT/
# NOTE/SUMMARY) plus the raw log for stack frames; it never reads the framework's
# or curl's own PASS/FAIL text. Per-test files are slices of raw.txt cut between
# BEGIN and TEST, so the log shows exactly what that test printed.
RUN_ELAPSED="$(elapsed_s)"
export RUN_ELAPSED RUN_STARTED RUN_COMMAND FILTER
# The analyst exits non-zero when the run failed; that is a result, not a bug.
set +e
python3 - "$RUN" "$git_sha" "$git_branch" "$git_dirty" "$git_subject" \
    "$cores" "$mem" "$os_name" "$(python3 --version 2>&1)" \
    "$unit_status" "$smoke_status" "$RUN_TIMEOUT" "$smoke_requested" "$git_top" <<'PY' | tee "$RUN/summary.txt"
import os
import re
import sys

(run_dir, sha, branch, dirty, subject, cores, mem, os_name, pyver,
 unit_status, smoke_status, timeout_s, smoke_requested, git_top) = sys.argv[1:15]
run_dir = os.path.abspath(run_dir)
run_id = os.path.basename(run_dir)
# Paths in reports are relative to the git top level when there is one, so they
# can be pasted into an editor; otherwise to the folder that holds tests/.
root = git_top or os.path.dirname(os.path.dirname(run_dir))
elapsed = float(os.environ.get("RUN_ELAPSED", "0"))
started = os.environ.get("RUN_STARTED", "")
command = os.environ.get("RUN_COMMAND", "")
flt = os.environ.get("FILTER", "")

records = open(os.path.join(run_dir, "records.txt"), errors="replace").read().splitlines()
raw = open(os.path.join(run_dir, "raw.txt"), errors="replace").read().splitlines()

BEGIN = re.compile(r"^BEGIN (\S+)$")
# unittest's progress dots are written without a newline, so a record line can
# start with them; they carry no pass/fail meaning and are stripped.
TEST = re.compile(r"^[.sFEx]*TEST (PASS|FAIL|CRASH|ERROR) (\S+)(?: (\d+))?(?: (\d+))?$")
CHECK = re.compile(r"^CHECK (\S.*?) (PASS|FAIL)(?: (\d+))?(?: (\S+?):(\d+): (.*))?$")
ASSERT = re.compile(r"^ASSERT (\S+?):(\d+): (.*)$")
NOTE = re.compile(r"^NOTE (\S+) (.*)$")
SUMMARY = re.compile(r"^SUMMARY (\d+) (\d+) (\d+)$")
FRAME = re.compile(r'^\s*File "([^"]+)", line (\d+), in ')
LOAD_FAIL = re.compile(r"(^_FailedTest|Failed to import test module)")


def rel(path):
    path = os.path.abspath(path)
    if path.startswith(root + os.sep):
        return os.path.relpath(path, root)
    return path


tests = {}
order = []
engine = {}          # id -> output lines between its BEGIN and its record
open_bracket = None


def get(uid):
    if uid not in tests:
        tests[uid] = {"id": uid, "status": None, "ms": 0, "asserts": [], "notes": [], "log": ""}
        order.append(uid)
        engine[uid] = []
    return tests[uid]


# Pass/fail comes from the records only. The raw log supplies what each test
# printed between its BEGIN and its record: stack frames, progress, output.
bracket_span = {}
current = None
for index, line in enumerate(raw):
    m = BEGIN.match(line)
    if m:
        current = m.group(1)
        bracket_span.setdefault(current, [index, len(raw)])
        continue
    m = TEST.match(line)
    if m and current:
        bracket_span[current][1] = index + 1
        current = None

OPEN = (BEGIN, TEST, CHECK, ASSERT, NOTE, SUMMARY)
for line in records:
    if not any(pattern.match(line) for pattern in OPEN):
        continue
    m = BEGIN.match(line)
    if m:
        open_bracket = m.group(1)
        get(open_bracket)
        continue
    m = TEST.match(line)
    if m:
        status, uid, ms, _ = m.groups()
        entry = get(uid)
        entry["status"] = status
        entry["ms"] = int(ms) if ms else 0
        open_bracket = None
        continue
    m = CHECK.match(line)
    if m:
        name, status, ms, where, lineno, detail = m.groups()
        entry = get(name.strip())
        entry["status"] = status
        entry["ms"] = int(ms or 0)
        if detail:
            entry["asserts"].append((where, int(lineno), detail))
        open_bracket = None
        continue
    m = ASSERT.match(line)
    if m:
        if open_bracket:
            path, lineno, msg = m.groups()
            tests[open_bracket]["asserts"].append((path, int(lineno), msg))
        continue
    m = NOTE.match(line)
    if m:
        owner, text = m.groups()
        if owner in tests:
            tests[owner]["notes"].append(text)
        elif open_bracket:
            tests[open_bracket]["notes"].append(text)

# Attach the engine's own output (stack frames, progress, prints) to each test
# now that every bracket has registered one.
for uid, (first, last) in bracket_span.items():
    if uid in tests:
        engine[uid] = raw[first:last]

# A bracket with no TEST record means the runner died inside that test. A whole
# file that failed to load is its own CRASH; anything else is an ERROR with the
# engine's last frame. Never a silent pass.
for uid in order:
    entry = tests[uid]
    if entry["status"] is None:
        entry["status"] = "CRASH" if LOAD_FAIL.search(uid) else "ERROR"


def engine_frame(uid):
    """Last engine frame whose file is the test's own; else the last frame."""
    own = uid.split("::")[0]
    frames = []
    # engine lines are appended by the loop below; a bracket with no TEST record
    # keeps everything the engine printed between BEGIN and the next record.
    for line in engine.get(uid, []):
        m = FRAME.match(line)
        if m:
            frames.append((rel(m.group(1)), int(m.group(2))))
    for frame in reversed(frames):
        if frame[0] == own or own in frame[0]:
            return frame
    return frames[-1] if frames else None


def has_source_line(entry):
    """True when at least one recorded assertion carries file:line."""
    return any(where for where, _, _ in entry["asserts"])


# The runner's own NOTE when it had to stop early (timeout, crash): it names the
# unfinished bracket when nothing else can.
pending_reason = next((m.group(2) for m in map(NOTE.match, records)
                       if m and m.group(1).startswith("tests/support/")), "")

for uid in order:
    entry = tests[uid]
    if entry["status"] in ("ERROR", "CRASH"):
        # A dead bracket's ASSERT lines may quote a log line rather than a real
        # assertion; the engine's own frames win, but keep them as extra detail.
        recorded = list(entry["asserts"])
        # A crash has no TEST record; its source line is the last frame the
        # engine printed inside this test's bracket. Only frames from the test's
        # own file are used, so a parse error in the next file cannot land here.
        frame = engine_frame(uid)
        why = ("runner died inside this test" if entry["status"] == "ERROR"
               else "the run crashed inside this test")
        if frame:
            entry["asserts"] = [(frame[0], frame[1], f"{why} (engine exit {unit_status})")] + recorded
    if entry["status"] in ("FAIL", "ERROR", "CRASH") and not has_source_line(entry):
        # Last resort: a line in the test's own output that names a source line,
        # such as an ASSERT printed without a matching record.
        for line in engine[uid]:
            m = ASSERT.match(line)
            if m:
                entry["asserts"] = [(m.group(1), int(m.group(2)), m.group(3))]
                break
    if entry["status"] in ("FAIL", "ERROR", "CRASH") and not has_source_line(entry) and pending_reason:
        # The runner had to stop early: say why, next to the test it stopped in.
        entry["asserts"] = [("tests/run-tests.sh", 1, pending_reason)]
    if entry["status"] in ("FAIL", "ERROR", "CRASH") and not has_source_line(entry):
        # The notes are the only evidence left (a timeout or a killed runner):
        # show the last one and where it came from.
        note = entry["notes"][-1] if entry["notes"] else ""
        where = NOTE.match(f"NOTE {uid} {note}")
        if where and where.group(2).startswith("tests/") and ":" in where.group(2).split(" ", 1)[0]:
            place, _, text = where.group(2).partition(": ")
            path, _, lineno = place.rpartition(":")
            entry["asserts"] = [(path, int(lineno), text or note)]
        else:
            entry["asserts"] = [("", 0, note or "no source line in the records (see the detail log)")]

# Drift guard: compare the run's plan with the records the shell actually counted.
planned = []
exp_path = os.path.join(run_dir, "tmp", "expected.tsv")
if os.path.exists(exp_path):
    for line in open(exp_path):
        parts = line.rstrip("\n").split("\t")
        if len(parts) == 2:
            planned.append(parts[1])
counted_units = [uid for uid in order if "::" in uid]
counted_smoke = [uid for uid in order if "::" not in uid]
planned_units = [p for p in planned if "::" in p]
mismatch = None
if sorted(planned_units) != sorted(counted_units):
    mismatch = {"planned": len(planned_units), "counted": len(counted_units),
                "missing": sorted(set(planned_units) - set(counted_units))[:5],
                "extra": sorted(set(counted_units) - set(planned_units))[:5]}
if smoke_requested == "1" and not counted_smoke:
    mismatch = mismatch or {"planned": 1, "counted": 0, "missing": ["tests/smoke.sh"], "extra": []}

# Per-test logs: raw.txt between BEGIN and TEST, or the smoke section (which
# runs after the unit section and ends at the end of the log).
smoke_line = next((i for i, line in enumerate(raw) if line.startswith("### smoke:")), None)
unit_line = next((i for i, line in enumerate(raw) if line.startswith("### unit:")), 0)

for uid in order:
    entry = tests[uid]
    if "::" in uid:
        suite, name = uid.split("::", 1)
        entry["log"] = os.path.join("detail", suite.removesuffix(".py").replace("/", "_"), name + ".log")
        lines = raw[bracket_span[uid][0]:bracket_span[uid][1]] if uid in bracket_span else []
    else:
        entry["log"] = os.path.join("detail", "smoke",
                                    re.sub(r"[^A-Za-z0-9._-]+", "_", uid).strip("_")[:80] + ".log")
        lines = raw[smoke_line:] if smoke_line is not None else raw[unit_line:]
    path = os.path.join(run_dir, entry["log"])
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(f"# {uid}\n# status: {entry['status']}  ({entry['ms']} ms)\n")
        fh.write(f"# run: {os.path.join('<run>', entry['log'])}\n")
        for where, lineno, msg in entry["asserts"]:
            fh.write(f"ASSERT {where}:{lineno}: {msg}\n")
        for note in entry["notes"]:
            fh.write(f"NOTE {note}\n")
        fh.write("\n")
        fh.write("".join(line + "\n" for line in lines))

bad = [tests[uid] for uid in order if tests[uid]["status"] != "PASS"]
rank = {"FAIL": 0, "ERROR": 1, "CRASH": 2}
bad.sort(key=lambda e: (rank.get(e["status"], 3), e["id"]))
passed = len(order) - len(bad)
failed = sum(1 for e in bad if e["status"] == "FAIL")
errored = sum(1 for e in bad if e["status"] in ("ERROR", "CRASH"))
# A run that did not finish (timeout, crash) proves less than a full one, even
# when every test it reached passed: never report that as PASS.
truncated = bool(pending_reason)
ok = not bad and not mismatch and unit_status == "0" and smoke_status == "0" and not truncated

with open(os.path.join(run_dir, "failures.txt"), "w") as fh, \
        open(os.path.join(run_dir, "failures.tsv"), "w") as tsv:
    tsv.write("status\ttest\tfile\tline\tmessage\tlog\n")
    if not bad:
        fh.write("no failures\n")
    for entry in bad:
        where = entry["asserts"][0]
        fh.write(f"{entry['status']} {entry['id']}\n")
        fh.write(f"  at {where[0]}:{where[1]}\n")
        for file, lineno, msg in entry["asserts"]:
            fh.write(f"    ASSERT {file}:{lineno}: {msg}\n")
        for note in list(dict.fromkeys(entry["notes"]))[-3:]:
            fh.write(f"    NOTE {note}\n")
        fh.write(f"    log: {entry['log']}\n\n")
        tsv.write("\t".join([entry["status"], entry["id"], where[0], str(where[1]),
                             " | ".join(m for _, _, m in entry["asserts"]), entry["log"]]) + "\n")

with open(os.path.join(run_dir, "tests.txt"), "w") as fh:
    fh.write("# status\ttest\tlog\n")
    for uid in order:
        fh.write(f"{tests[uid]['status']}\t{uid}\t{tests[uid]['log']}\n")

suites = []
if planned_units or counted_units or unit_status != "0":
    suites.append("unit")
if smoke_requested == "1" or counted_smoke:
    suites.append("smoke")

out = [f"registreasy tests — run {run_id}"]
out.append("  suites   " + (", ".join(suites) or "none") + (f"   (filter: {flt})" if flt else ""))
out.append(f"  result   {'PASS' if ok else 'FAIL'}   {passed} passed, {failed} failed, "
           f"{errored} error/crash, {len(order)} tests   {elapsed:.1f}s")
out.append(f"  git      {sha} on {branch}" +
           (f"   {dirty} uncommitted file(s)" if dirty not in ("0", "") else "   clean"))
if unit_status not in ("0",) or smoke_status not in ("0",):
    out.append(f"  exit     unit={unit_status} smoke={smoke_status}"
               + ("   (124/137 = timed out after " + timeout_s + "s)" if unit_status in ("124", "137") else ""))
if mismatch:
    out.append(f"  COUNT MISMATCH — runner planned {mismatch['planned']} unit test(s), shell counted "
               f"{mismatch['counted']}; all counts unreliable")
    if mismatch["missing"]:
        out.append(f"    missing records: {', '.join(mismatch['missing'])}")
    if mismatch["extra"]:
        out.append(f"    unexpected records: {', '.join(mismatch['extra'])}")
if truncated:
    out.append("  unfinished  " + pending_reason + " — the run stopped early and proves less than a full run")
if bad:
    out.append(f"  failures ({min(8, len(bad))} of {len(bad)}, full list in failures.txt):")
    for entry in bad[:8]:
        where = entry["asserts"][0]
        out.append(f"    {entry['status']:<5} {entry['id']}")
        out.append(f"          at {where[0]}:{where[1]}: {where[2]}")
    out.append("  open one with: bash tests/run-tests.sh --full <test>")
else:
    out.append("  failures none")
logs_dir = os.path.join(root, "tests", ".test-runs")
shown = os.path.relpath(run_dir, logs_dir) if run_dir.startswith(logs_dir + os.sep) else run_dir
out.append(f"  run      tests/.test-runs/{shown}")
out.append("  next     read failures.txt and detail/*.log; do not re-run to see more")
for line in out:
    print(line)

with open(os.path.join(run_dir, "meta.txt"), "w") as fh:
    meta = [("run_id", run_id), ("started_utc", started), ("elapsed_s", f"{elapsed:.1f}"),
            ("timeout_s", timeout_s), ("command", command), ("filter", flt),
            ("git_sha", sha), ("git_branch", branch), ("git_dirty_files", dirty),
            ("git_subject", subject), ("python", pyver), ("os", os_name),
            ("cores", cores), ("memory", mem), ("unit_exit", unit_status),
            ("smoke_exit", smoke_status),
            ("tests", f"{len(order)} ({passed} passed, {failed} failed, {errored} error/crash)"),
            ("count_mismatch", "yes" if mismatch else "no")]
    for key, value in meta:
        fh.write(f"{key}: {value}\n")

with open(os.path.join(run_dir, "history.tsv"), "w") as fh:
    fh.write("# run\tutc\tgit_sha\tbranch\tdirty\ttest\tstatus\tms\n")
    for uid in order:
        fh.write(f"{run_id}\t{started}\t{sha}\t{branch}\t{dirty}\t{uid}\t{tests[uid]['status']}\t"
                 f"{tests[uid]['ms']}\n")

sys.exit(0 if ok else 1)
PY
analysis_status=$?
set -e

rm -rf "$RUN/tmp"   # after the analyst has used the plan file in it

# The run folder keeps its own rows (written by the analyser). The shared ledger
# at the top of tests/.test-runs is that append-only history: this run's rows are
# appended to it, and runs pruned from disk are folded in once by --prune.
LEDGER="$LOGS/history.tsv"
if [[ ! -f "$LEDGER" ]]; then
    echo '# run	utc	git_sha	branch	dirty	test	status	ms' >"$LEDGER"
fi
grep -v '^#' "$RUN/history.tsv" >>"$LEDGER" 2>/dev/null || true

exit "$analysis_status"
