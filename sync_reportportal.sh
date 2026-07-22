#!/bin/bash
# Download latest JUnit artifacts and import them into ReportPortal.

set -euo pipefail
cd "$(dirname "$0")"

LOCK_DIR="${LOCK_DIR:-/tmp/reportportal-sync.lock}"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another ReportPortal sync is already running."
    exit 1
fi
trap 'rmdir "$LOCK_DIR"' EXIT

echo "=== Downloading artifacts ==="
./download_artifacts.sh "$@"

echo ""
echo "=== Importing JUnit reports ==="
./import_junit.sh ./downloaded_artifacts/
