#!/usr/bin/env python3
"""Idempotently populates Kiwi TCMS with the Product/Version/Plan and one
Test Case per entry in test_case_catalog.py, then writes test_case_map.yml
(key -> Kiwi case id) for report_results.py to consume.
"""
import yaml

from kiwi_client import KiwiClient
from test_case_catalog import CASES

PRODUCT_NAME = "WebnovelReader iOS"
VERSION_VALUE = "dev"
PLAN_NAME = "iOS UI Regression"
CATEGORY_NAME = "--default--"


def main():
    client = KiwiClient()

    product_id = client.get_or_create_product(PRODUCT_NAME, "Native SwiftUI TTS webnovel reader")
    version_id = client.get_or_create_version(product_id, VERSION_VALUE)
    plan_id = client.get_or_create_plan(PLAN_NAME, product_id, version_id)

    categories = client.rpc.Category.filter({"product": product_id, "name": CATEGORY_NAME})
    category_id = categories[0]["id"] if categories else client.rpc.Category.create({
        "product": product_id, "name": CATEGORY_NAME,
    })["id"]

    case_map = {}
    for entry in CASES:
        case_id = client.get_or_create_case(
            summary=entry["summary"],
            plan_id=plan_id,
            product_id=product_id,
            category_id=category_id,
            text=entry["steps"],
            is_automated=entry["automated"],
        )
        client.add_tag(case_id, "automated" if entry["automated"] else "manual")
        case_map[entry["key"]] = case_id
        print(f"  {entry['key']} -> case #{case_id}")

    with open("test_case_map.yml", "w") as f:
        yaml.safe_dump({
            "product_id": product_id,
            "version_id": version_id,
            "plan_id": plan_id,
            "cases": case_map,
        }, f, sort_keys=False)

    print(f"\nWrote test_case_map.yml — {len(case_map)} cases under plan #{plan_id}")


if __name__ == "__main__":
    main()
