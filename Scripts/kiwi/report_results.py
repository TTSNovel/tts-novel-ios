#!/usr/bin/env python3
"""Parses an .xcresult bundle and reports each test method's pass/fail into
a new Kiwi TestRun, using test_case_map.yml (written by setup_test_cases.py)
to map "ClassName.testMethod" -> Kiwi case id.

Usage: report_results.py <path-to-TestResults.xcresult>
Exits non-zero if any mapped test failed (or the xcresult itself reports a
failed run), so it's a valid CI gate on its own.
"""
import json
import subprocess
import sys
from datetime import datetime

import yaml

from kiwi_client import KiwiClient

RESULT_TO_KIWI_STATUS = {
    "Passed": "PASSED",
    "Failed": "FAILED",
    "Skipped": "WAIVED",
    "Expected Failure": "WAIVED",
}


def xcresult_test_cases(bundle_path: str):
    """Yields (class_name, method_name, kiwi_status, node) for every leaf
    'Test Case' node in the bundle."""
    raw = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle_path, "--compact"],
        capture_output=True, text=True, check=True,
    ).stdout
    data = json.loads(raw)

    def walk(node):
        if node.get("nodeType") == "Test Case":
            identifier = node.get("nodeIdentifier", "")
            class_name, _, method_raw = identifier.partition("/")
            method_name = method_raw.rstrip("()")
            class_name = class_name.rsplit(".", 1)[-1]  # drop module prefix if present
            status = RESULT_TO_KIWI_STATUS.get(node.get("result"), "ERROR")
            yield class_name, method_name, status, node
        for child in node.get("children", []):
            yield from walk(child)

    for top in data.get("testNodes", []):
        yield from walk(top)


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path-to-TestResults.xcresult>", file=sys.stderr)
        sys.exit(2)
    bundle_path = sys.argv[1]

    with open("test_case_map.yml") as f:
        mapping = yaml.safe_load(f)
    case_map = mapping["cases"]
    plan_id = mapping["plan_id"]
    version_id = mapping["version_id"]

    client = KiwiClient()
    build_id = client.get_or_create_build(version_id, "local-dev")
    run_id = client.create_run(
        plan_id, f"Local run {datetime.now().isoformat(timespec='seconds')}", build_id,
    )
    print(f"Created Kiwi Test Run #{run_id}")

    any_failed = False
    reported = 0
    for class_name, method_name, status, node in xcresult_test_cases(bundle_path):
        key = f"{class_name}.{method_name}"
        case_id = case_map.get(key)
        if case_id is None:
            print(f"  (skip — not in test_case_map.yml) {key}: {status}")
            continue
        execution_id = client.add_case_to_run(run_id, case_id)
        log = node.get("details", "") or ""
        client.record_execution(execution_id, status, log)
        print(f"  {key}: {status} -> execution #{execution_id}")
        reported += 1
        if status not in ("PASSED", "WAIVED"):
            any_failed = True

    print(f"\nReported {reported} test(s) to Kiwi Test Run #{run_id}")
    print(f"https://localhost:8443/runs/{run_id}/")
    sys.exit(1 if any_failed else 0)


if __name__ == "__main__":
    main()
