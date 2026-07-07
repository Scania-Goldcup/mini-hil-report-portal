#!/bin/bash
set -euo pipefail

echo "=== stuart: reports directory ==="
ssh -o StrictHostKeyChecking=no github-runner@10.254.0.19 \
    "find ~/actions-runner/_work -name 'junit.xml' 2>/dev/null; echo '---'; ls ~/actions-runner/_work/bms-pp/bms-pp/reports/ 2>/dev/null"

echo ""
echo "=== jorge: reports directory ==="
ssh -o StrictHostKeyChecking=no github-runner@10.254.0.22 \
    "find ~/actions-runner/_work -name 'junit.xml' 2>/dev/null; echo '---'; find ~ -path '*/reports/*' -name 'junit.xml' 2>/dev/null; echo '---'; ls ~/actions-runner/_work/*/reports/ 2>/dev/null || find ~ -type d -name reports 2>/dev/null | head -10"

echo ""
echo "=== bob: reports directory ==="
ssh -o StrictHostKeyChecking=no github-runner@10.254.0.17 \
    "find ~/actions-runner/_work -name 'junit.xml' 2>/dev/null; echo '---'; find ~ -path '*/reports/*' -name 'junit.xml' 2>/dev/null; echo '---'; ls ~/actions-runner/_work/*/reports/ 2>/dev/null || find ~ -type d -name reports 2>/dev/null | head -10"
