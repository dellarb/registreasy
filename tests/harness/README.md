# Offline check of the test runner

`verify-runner.sh` tests `tests/run-tests.sh` itself without running any test. It copies the
runner into a throwaway git sandbox, replaces only the two execution hooks
(`test_execute_unit`, `test_execute_smoke`) with a stub that cats a fixture, and then asserts
every file and every line the runner is supposed to produce: the summary, `failures.txt`/`.tsv`,
one `detail/<suite>/<test>.log` per test, `raw.txt`, `meta.txt`, `tests.txt`, `history.tsv`,
`--last`, `--full`, the exact-id filter, `--prune --keep`, and the error paths.

```bash
bash tests/harness/verify-runner.sh          # exit 1 on a design defect
bash tests/harness/verify-runner.sh --keep   # keep the sandbox for inspection
```

It needs `bash`, `git`, `python3` and `grep -P`; no container and no network.

## Fixtures

Each `records-*.log` is what the test executable prints (the machine records) and each matching
`raw-*.txt` is its full output, which is what the analyser slices per-test logs from.

| Pair | What it represents |
| --- | --- |
| `records-genuine.log` / `raw-genuine.txt` | A captured run with one pass, one failing assertion and one crash record |
| `records-synthetic-crash.log` / `raw-genuine-crash.txt` | The same run with the crashing test's engine output in the middle |
| `records-runner-death.log` / `raw-runner-death.txt` | `BEGIN` with no `TEST` record: the runner died inside a test |
| `records-load-failure.log` / `raw-load-failure.txt` | A whole file that failed to import (it never gets a `BEGIN`) |
| `records-clean.log` / `raw-clean.txt` | All green |
| `records-smoke-failure.log` / `raw-smoke-failure.txt` | The smoke suite failing at one named `CHECK` |

The runner treats the plan (which tests exist) separately from the records (what happened), so the
sandbox has a stand-in `tests/support/record_runner.py` that only answers `--list` from
`tests/harness/planned.txt`.

## Why the harness exists

Two defects it caught while the runner was written:

- `exit` inside the execution step, whose output the caller redirects, ends the whole script in
  bash 5.2 — the runner then writes no summary at all. The stub uses `return`, and there is a
  gate that fails the harness loudly if a run folder has no report.
- The `latest` symlink also ends in `/`, so a naive `ls -d */` prune deleted it. The harness's
  `--prune` case checks the symlink survives and that exactly `--keep` run folders remain.
