"""Machine-readable test records for the unit tests and tests/smoke.sh.

One reporting path only: the executable announces each test and its outcome on
stdout, and run-tests.sh does all the formatting. Nothing here decides pass or
fail from the framework's own output.

    BEGIN <id>
    TEST PASS|FAIL|CRASH <id> [<ms>]       (CRASH <id> <exit-status>)
    ASSERT <file>:<line>: <message>
    NOTE <test> <message>
    CHECK <name> PASS|FAIL [<ms>]          (tests/smoke.sh: one named HTTP check)
    SUMMARY <pass> <fail> <crash>

Tests are run through `python3 tests/support/record_runner.py`, which wraps the
standard library's unittest without adding a dependency.
"""
import os
import re
import sys
import time
import unittest
import uuid

ASSERTIONS = []  # (file, line, message) for failing assertions, in order
NOTES = []  # (file, line, message) from note()
_ACTIVE = []  # [test id] while its BEGIN..TEST bracket is open; note() uses it


def _where(frame_index=1):
    """file:line of the caller, relative to the repository root."""
    try:
        frame = sys._getframe(frame_index)
    except ValueError:  # pragma: no cover - very deep stacks
        return "<unknown>:0"
    return f"{_relative(frame.f_code.co_filename)}:{frame.f_lineno}"


def _relative(path):
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    path = os.path.abspath(path)
    if path.startswith(root + os.sep):
        return os.path.relpath(path, root)
    return path


def current_test():
    """The test whose bracket is open, or None."""
    return _ACTIVE[0] if _ACTIVE else None


def _emit(line):
    sys.stdout.write(line + "\n")
    sys.stdout.flush()





def note(message):
    """Record a diagnostic under the test that is running now."""
    where = _where(1)
    NOTES.append((where, str(message)))
    owner = current_test() or "<no test>"
    _emit(f"NOTE {owner} {where}: {message}")


def _record_assert(where, message):
    ASSERTIONS.append((where, str(message)))
    _emit(f"ASSERT {where}: {message}")


class TestCase(unittest.TestCase):
    """unittest.TestCase whose failures always carry file:line and expected/got.

    assertEqual/assertTrue/assertIn and friends go through fail(), which records
    the failing assertion's own line. A test that raises instead of asserting
    (a timeout, a KeyError) is reported with the file:line of the exception.
    """

    def fail(self, msg=None):  # noqa: A003 - unittest API
        _record_assert(_where(2), msg if msg is not None else "assertion failed")
        super().fail(msg)

    def assertEqual(self, first, second, msg=None):
        if first != second:
            detail = f"expected {first!r}, got {second!r}"
            _record_assert(_where(2), f"{msg}: {detail}" if msg else detail)
        super().assertEqual(first, second, msg)

    def assertNotEqual(self, first, second, msg=None):
        if first == second:
            detail = f"expected anything but {second!r}"
            _record_assert(_where(2), f"{msg}: {detail}" if msg else detail)
        super().assertNotEqual(first, second, msg)

    def assertTrue(self, expr, msg=None):
        if not expr:
            detail = f"expected truthy, got {expr!r}"
            _record_assert(_where(2), f"{msg}: {detail}" if msg else detail)
        super().assertTrue(expr, msg)

    def assertFalse(self, expr, msg=None):
        if expr:
            detail = f"expected falsy, got {expr!r}"
            _record_assert(_where(2), f"{msg}: {detail}" if msg else detail)
        super().assertFalse(expr, msg)

    def assertIsNone(self, expr, msg=None):
        if expr is not None:
            detail = f"expected None, got {expr!r}"
            _record_assert(_where(2), f"{msg}: {detail}" if msg else detail)
        super().assertIsNone(expr, msg)

    def assertIsNotNone(self, expr, msg=None):
        if expr is None:
            detail = "expected a value, got None"
            _record_assert(_where(2), f"{msg}: {detail}" if msg else detail)
        super().assertIsNotNone(expr, msg)

    def assertIn(self, member, container, msg=None):
        if member not in container:
            detail = f"expected {member!r} in {container!r}"
            _record_assert(_where(2), f"{msg}: {detail}" if msg else detail)
        super().assertIn(member, container, msg)

    def assertNotIn(self, member, container, msg=None):
        if member in container:
            detail = f"expected {member!r} not in {container!r}"
            _record_assert(_where(2), f"{msg}: {detail}" if msg else detail)
        super().assertNotIn(member, container, msg)

    def assertGreater(self, a, b, msg=None):
        if not a > b:
            detail = f"expected {a!r} > {b!r}"
            _record_assert(_where(2), f"{msg}: {detail}" if msg else detail)
        super().assertGreater(a, b, msg)

    def assertGreaterEqual(self, a, b, msg=None):
        if not a >= b:
            detail = f"expected {a!r} >= {b!r}"
            _record_assert(_where(2), f"{msg}: {detail}" if msg else detail)
        super().assertGreaterEqual(a, b, msg)

    def assertLess(self, a, b, msg=None):
        if not a < b:
            detail = f"expected {a!r} < {b!r}"
            _record_assert(_where(2), f"{msg}: {detail}" if msg else detail)
        super().assertLess(a, b, msg)

    def assertIs(self, a, b, msg=None):
        if a is not b:
            detail = f"expected identity with {b!r}, got {a!r}"
            _record_assert(_where(2), f"{msg}: {detail}" if msg else detail)
        super().assertIs(a, b, msg)


class Recorder:
    """Emits BEGIN/TEST/ASSERT/NOTE/SUMMARY around a unittest result."""

    def __init__(self, stream=None):
        del _ACTIVE[:]
        self.ids = {}  # test id -> unit test (for attribution after the fact)
        self.results = []  # (id, status, ms)
        self.counts = {"pass": 0, "fail": 0, "crash": 0}

    # The id used everywhere in the run folder: tests/test_auth.py::Class.test
    @staticmethod
    def id_for(test):
        cls = type(test)
        module = getattr(sys.modules.get(cls.__module__), "__file__", None) or cls.__module__
        return f"{_relative(module)}::{cls.__name__}.{getattr(test, '_testMethodName', 'unknown')}"

    def begin(self, test):
        test_id = self.id_for(test)
        self.ids[test_id] = test
        del _ACTIVE[:]
        _ACTIVE.append(test_id)
        del ASSERTIONS[:]
        del NOTES[:]
        _emit(f"BEGIN {test_id}")
        return test_id

    def end(self, test, status, ms, detail=""):
        test_id = self.id_for(test)
        suffix = f" {int(ms)}" if status in ("PASS", "FAIL") else f" {detail or 1}"
        _emit(f"TEST {status} {test_id}{suffix}")
        self.results.append((test_id, status, int(ms)))
        self.counts["pass" if status == "PASS" else ("fail" if status == "FAIL" else "crash")] += 1
        del _ACTIVE[:]

    def summary(self):
        _emit(f"SUMMARY {self.counts['pass']} {self.counts['fail']} {self.counts['crash']}")


class RecordingResult(unittest.TextTestResult):
    """Text result that also writes machine records for every test."""

    def __init__(self, stream, descriptions, verbosity, recorder):
        super().__init__(stream, descriptions, verbosity)
        self.recorder = recorder
        self._started = {}

    def startTest(self, test):
        self.recorder.begin(test)
        self._started[test] = time.monotonic()
        super().startTest(test)

    def _elapsed(self, test):
        return (time.monotonic() - self._started.get(test, time.monotonic())) * 1000

    def addSuccess(self, test):
        super().addSuccess(test)
        self.recorder.end(test, "PASS", self._elapsed(test))

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self._explain_exception(err)
        self.recorder.end(test, "FAIL", self._elapsed(test))

    def addError(self, test, err):
        # unittest calls this for exceptions that are not test failures too
        # (assertion helpers used outside a test, errors in setUp); they are
        # failures of this test either way.
        super().addError(test, err)
        self._explain_exception(err)
        self.recorder.end(test, "FAIL", self._elapsed(test))

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        note(f"skipped: {reason}")
        self.recorder.end(test, "PASS", self._elapsed(test))

    def addExpectedFailure(self, test, err):
        super().addExpectedFailure(test, err)
        self.recorder.end(test, "PASS", self._elapsed(test))

    def addUnexpectedSuccess(self, test):
        super().addUnexpectedSuccess(test)
        _emit(f"ASSERT {self.recorder.id_for(test)}:0: expected failure, but the test passed")
        self.recorder.end(test, "FAIL", self._elapsed(test))

    def _explain_exception(self, err):
        """Record the exception's own file:line when assert* did not already."""
        kind, value, tb = err
        if ASSERTIONS:
            return  # the assertion helper already recorded file:line and expected/got
        frames = []
        while tb is not None:
            frames.append(tb)
            tb = tb.tb_next
        for frame in reversed(frames):
            path = frame.tb_frame.f_code.co_filename
            if path.startswith(os.path.dirname(os.path.abspath(__file__))):
                continue
            where = f"{_relative(path)}:{frame.tb_lineno}"
            _record_assert(where, f"{kind.__name__}: {value}")
            return
        _record_assert("<unknown>:0", f"{kind.__name__}: {value}")

    def addSubTest(self, test, subtest, err):
        super().addSubTest(test, subtest, err)
        if err is not None:
            kind, value, tb = err
            params = subtest.params
            self._explain_exception(err)
            note(f"subtest {params}: {kind.__name__}: {value}")


def discover(module_path="tests"):
    """The whole suite, in a deterministic order."""
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    directory = os.path.join(root, module_path)
    if root not in sys.path:
        sys.path.insert(0, root)
    if directory not in sys.path:
        sys.path.insert(0, directory)
    return unittest.defaultTestLoader.discover(directory, top_level_dir=directory)


def list_tests():
    """Print every test id, one per line (used by the runner to plan a run)."""
    for test in _walk(discover()):
        print(Recorder.id_for(test))
    return 0


def filter_to_pattern(text):
    """substring filter -> a regex the id matcher accepts; '::' means exact."""
    if "::" in text:
        return re.escape(text)
    return ".*" + re.escape(text) + ".*"


def run_suite(stream=None, failfast=False, tests=None):
    """Discover tests/, record them, and return an exit status."""
    recorder = Recorder(stream)
    try:
        suite = tests if tests is not None else discover()
        result = unittest.TextTestRunner(
            stream=stream or sys.stdout,
            verbosity=1,
            resultclass=_result_class(recorder),
            failfast=failfast,
        ).run(suite)
    finally:
        recorder.summary()
    return 0 if result.wasSuccessful() else 1


def _result_class(recorder):
    class _Result(RecordingResult):
        def __init__(self, stream, descriptions, verbosity):
            super().__init__(stream, descriptions, verbosity, recorder)

    return _Result


def select(pattern):
    """Suite of every test whose id matches the regex `pattern` (full match)."""
    keep = [t for t in _walk(discover()) if re.fullmatch(pattern, Recorder.id_for(t))]
    suite = unittest.TestSuite()
    for test in keep:
        suite.addTest(test)
    return suite


def _walk(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from _walk(item)
        else:
            yield item


__all__ = ["TestCase", "Recorder", "RecordingResult", "note", "discover", "list_tests",
           "filter_to_pattern", "run_suite", "select", "uuid"]
