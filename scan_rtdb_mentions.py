#!/usr/bin/env python3
"""Scan junit.xml artifacts for RTDB mentions and log run metadata."""

from __future__ import annotations

import argparse
import csv
import re
import sys
from pathlib import Path
import xml.etree.ElementTree as ET


def parse_property_attributes(xml_text: str) -> dict[str, str]:
    """Fallback parser for property name/value attributes in XML text."""
    props: dict[str, str] = {}
    pattern = re.compile(r'<property\\b[^>]*\\bname="([^"]+)"[^>]*\\bvalue="([^"]*)"')
    for match in pattern.finditer(xml_text):
        name = match.group(1).strip()
        value = match.group(2).strip()
        if not name:
            continue
        if name == "attribute" and ":" in value:
            key, raw_value = value.split(":", 1)
            props[key.strip()] = raw_value.strip()
        elif value:
            props[name] = value
    return props


def parse_properties(xml_text: str) -> dict[str, str]:
    """Parse properties from junit XML, with regex fallback for malformed XML."""
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        return parse_property_attributes(xml_text)

    props: dict[str, str] = {}
    for prop in root.findall(".//property"):
        name = prop.attrib.get("name", "").strip()
        value = prop.attrib.get("value", "").strip()
        if not name:
            continue
        if name == "attribute" and ":" in value:
            key, raw_value = value.split(":", 1)
            props[key.strip()] = raw_value.strip()
        elif value:
            props[name] = value
    return props


def build_sw_version(props: dict[str, str]) -> str:
    sw_items = [(k, v) for k, v in props.items() if k.startswith("sw_version.")]
    if not sw_items:
        return ""
    return "; ".join(f"{k}={v}" for k, v in sorted(sw_items, key=lambda item: item[0].lower()))


def derive_run_id(props: dict[str, str], github_url: str) -> str:
    run_id = props.get("run-id", "").strip()
    if run_id:
        return run_id
    if github_url:
        match = re.search(r"/actions/runs/(\\d+)", github_url)
        if match:
            return match.group(1)
    return ""


def extract_run_date(xml_text: str) -> str:
    """Extract run date (YYYY-MM-DD) from junit testsuite timestamp."""
    timestamp = ""
    try:
        root = ET.fromstring(xml_text)
        timestamp = root.attrib.get("timestamp", "").strip()
        if not timestamp:
            testsuite = root.find(".//testsuite")
            if testsuite is not None:
                timestamp = testsuite.attrib.get("timestamp", "").strip()
    except ET.ParseError:
        match = re.search(r'\btimestamp="([^"]+)"', xml_text)
        if match:
            timestamp = match.group(1).strip()

    if not timestamp:
        return ""
    return timestamp.split("T", 1)[0]


def scan_junit_files(root_dir: Path, needle: str, default_repo: str) -> tuple[int, list[dict[str, str]]]:
    junit_files = sorted(root_dir.rglob("junit.xml"))
    rows: list[dict[str, str]] = []

    for junit_file in junit_files:
        xml_text = junit_file.read_text(encoding="utf-8", errors="replace")
        match_count = xml_text.count(needle)
        if match_count == 0:
            continue

        props = parse_properties(xml_text)
        github_url = props.get("github_actions_run_url", "").strip()
        run_id = derive_run_id(props, github_url)
        run_date = extract_run_date(xml_text)
        repository = props.get("repository", "").strip() or default_repo
        repo_name = repository.split("/")[-1] if "/" in repository else repository
        sw_version = build_sw_version(props)

        rows.append(
            {
                "date": run_date,
                "match_count": str(match_count),
                "github_actions_run_url": github_url,
                "run_id": run_id,
                "repository": repository,
                "repository_name": repo_name,
                "sw_version": sw_version,
            }
        )

    return len(junit_files), rows


def write_csv(output_file: Path, rows: list[dict[str, str]]) -> None:
    output_file.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "date",
        "match_count",
        "github_actions_run_url",
        "run_id",
        "repository",
        "repository_name",
        "sw_version",
    ]
    with output_file.open("w", newline="", encoding="utf-8") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Scan all junit.xml files under a directory and log files containing "
            "a requested RTDB string."
        )
    )
    parser.add_argument(
        "--root",
        default="downloaded_artifacts",
        help="Root directory to scan for junit.xml files (default: downloaded_artifacts).",
    )
    parser.add_argument(
        "--needle",
        default="RTDB_PMIC_ERRORCODE",
        help="String to search for inside junit.xml content (default: RTDB_PMIC_ERRORCODE).",
    )
    parser.add_argument(
        "--default-repo",
        default="BMS_Minions",
        help="Fallback repository label when repository metadata is missing.",
    )
    parser.add_argument(
        "--output",
        default="rtdb_mentions.csv",
        help="Output CSV path (default: rtdb_mentions.csv).",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root_dir = Path(args.root)

    if not root_dir.exists() or not root_dir.is_dir():
        print(f"ERROR: Scan root '{root_dir}' does not exist or is not a directory.", file=sys.stderr)
        return 2

    scanned_count, rows = scan_junit_files(root_dir, args.needle, args.default_repo)
    write_csv(Path(args.output), rows)

    total_mentions = sum(int(row["match_count"]) for row in rows)
    print(f"Scanned {scanned_count} junit.xml files under '{root_dir}'.")
    print(
        f"Found '{args.needle}' in {len(rows)} files with {total_mentions} total mentions."
    )
    print(f"Wrote CSV: {args.output}")

    for row in rows:
        print(
            " - "
            f"matches={row['match_count']} | "
            f"date={row['date'] or 'unknown'} | "
            f"run_id={row['run_id'] or 'unknown'} | "
            f"repository={row['repository_name'] or 'unknown'} | "
            f"github_actions_run_url={row['github_actions_run_url'] or 'unknown'}"
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
