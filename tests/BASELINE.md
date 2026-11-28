# Test baseline

Recorded for the test-structure pass so later work can compare against it. Re-capture with
`bash tests/run-tests.sh` and read `tests/.test-runs/latest/meta.txt` and `history.tsv`.

| | |
| --- | --- |
| Commit | `9fb040b` ("Separate tag and version columns") on `main`, tree clean |
| Canonical commands | `bash tests/run-tests.sh` (unit, no container); `SMOKE_ENDPOINT=http://127.0.0.1:<port> PUSH_PASSWORD=… PULL_PASSWORD=… bash tests/run-tests.sh smoke` (unit + smoke) |
| Plain entry point kept | `python3 -m unittest discover -s tests` (used by CI) |
| Unit suite | 31 tests, 7.3 s wall (single tier: `tests/test_auth.py` 26, `tests/test_inventory_metadata.py` 5) |
| Smoke suite | 47 `CHECK` records from `tests/smoke.sh` against a container, 7.9 s together with the unit tests |
| Slowest unit tests | the 14 `HandlerTest` cases, ~500 ms each (they start a real in-process HTTP server) |
| Runner overhead | ~0.9 s on top of the unit suite (planning, analysis, writing the run folder) |
| Machine | 6 cores, 26 GiB RAM, Linux 6.12.117+deb13-amd64 |
| Toolchain | Python 3.13.5, GNU bash 5.2.37, Docker 29.10.1 |

Per-test timings for every run are in `tests/.test-runs/latest/history.tsv` (columns
`run, utc, git_sha, branch, dirty, test, status, ms`); `tests.txt` lists each test with its log.
