"""Test support code shared by tests/ and run-tests.sh.

Import it as `from support.records import TestCase, note` (or `from support import
records`). The same module can be reached as `records` and as `support.records`
depending on how the test run started: `python3 -m unittest discover -s tests`
puts tests/ on sys.path, so records.py can load once as `records` and again as
`support.records`. That would give two copies of note()'s state and a note()
could not see which test is running. This file keeps a single copy.
"""
import importlib.util
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_PARENT = os.path.dirname(_HERE)
if _PARENT not in sys.path:
    sys.path.insert(0, _PARENT)


def _load():
    """Load tests/support/records.py at most once, whatever name it was asked for."""
    for cached in (sys.modules.get("support.records"), sys.modules.get("records")):
        if cached is not None and hasattr(cached, "TestCase"):
            sys.modules["support.records"] = sys.modules["records"] = cached
            return cached
    spec = importlib.util.spec_from_file_location("support.records", os.path.join(_HERE, "records.py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules["support.records"] = module
    spec.loader.exec_module(module)
    return module


records = _load()
sys.modules["records"] = records
