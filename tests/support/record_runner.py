#!/usr/bin/env python3
"""Entry point for the unit tests: one BEGIN/TEST record per test.

    python3 tests/support/record_runner.py [--failfast] [--filter TEXT] [--list]
    python3 tests/support/record_runner.py --exact 'tests/test_auth.py::Class.test'
    python3 -m unittest discover -s tests      # still plain unittest, no records

Pass/fail is decided here and printed as TEST records; run-tests.sh only formats
them. The framework's own output stays in the raw log for humans.
"""
import argparse
import os
import re
import sys

# Import through the package so the module object is the one the tests import
# (`support.records`); tests/support/__init__.py keeps both names identical.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from support import records  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description="Run the unit tests and emit machine records.")
    parser.add_argument("--failfast", action="store_true")
    parser.add_argument("--exact", metavar="ID", help="run exactly one test: tests/test_x.py::Class.test")
    parser.add_argument("--filter", metavar="TEXT",
                        help="only tests whose id contains TEXT, or exactly TEXT when it has '::'")
    parser.add_argument("--list", action="store_true", help="print every test id and exit")
    args = parser.parse_args()
    if args.list:
        return records.list_tests()
    if args.exact and args.filter:
        parser.error("--exact and --filter are mutually exclusive")
    tests = None
    if args.exact:
        tests = records.select(re.escape(args.exact))
    elif args.filter:
        tests = records.select(records.filter_to_pattern(args.filter))
    if tests is not None and tests.countTestCases() == 0:
        print(f"record_runner: no test matches {args.exact or args.filter!r}", file=sys.stderr)
        return 1
    return records.run_suite(stream=sys.stderr, failfast=args.failfast, tests=tests)


if __name__ == "__main__":
    sys.exit(main())
