#!/bin/bash
set -euo pipefail
cd /home/alex/reporting_test

RP_URL="http://localhost:8080"

# Authenticate
echo "Authenticating..."
TOKEN=$(curl -s -X POST "${RP_URL}/uat/sso/oauth/token" \
    -H "Authorization: Basic dWk6dWltYW4=" \
    -d "grant_type=password&username=superadmin&password=erebus" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

echo "Token: ${TOKEN:0:20}..."
echo ""

# Import all 3 test runs
for dir in 2026-07-06T09.58.59 2026-07-06T10.07.49 2026-07-06T10.10.07; do
    if [ -f "$dir/junit.xml" ]; then
        echo "Importing $dir/junit.xml..."
        RESPONSE=$(curl -s -X POST \
            "${RP_URL}/api/v1/plugin/superadmin_personal/junit/import" \
            -H "Authorization: Bearer ${TOKEN}" \
            -F "file=@${dir}/junit.xml;type=application/xml")
        echo "  -> $RESPONSE"
    fi
done

echo ""
echo "=== Check launches ==="
curl -s "${RP_URL}/api/v1/superadmin_personal/launch" \
    -H "Authorization: Bearer ${TOKEN}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(f'Total launches: {data.get(\"page\", {}).get(\"totalElements\", 0)}')
for l in data.get('content', []):
    print(f'  - {l[\"name\"]} (id={l[\"id\"]}, status={l.get(\"status\",\"?\")})')
"
echo ""
echo "View results at: http://localhost:8080/ui/#superadmin_personal/launches/all"
