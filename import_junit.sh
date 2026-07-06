#!/bin/bash
# Import JUnit XML files into ReportPortal
# Usage: ./import_junit.sh <path-to-junit.xml> [launch-name]
#
# Prerequisites: ReportPortal must be running (docker compose up -d)
# Default credentials: superadmin / erebus
# Default project: superadmin_personal

set -euo pipefail

RP_URL="${RP_URL:-http://localhost:8080}"
RP_USER="${RP_USER:-superadmin}"
RP_PASS="${RP_PASS:-erebus}"
RP_PROJECT="${RP_PROJECT:-superadmin_personal}"
RP_PLUGIN="${RP_PLUGIN:-junit}"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <junit-xml-file-or-directory> [launch-name]"
    echo ""
    echo "Examples:"
    echo "  $0 ./results/junit.xml"
    echo "  $0 ./results/junit.xml 'My Test Run'"
    echo "  $0 ./results/  # imports all .xml files in directory"
    exit 1
fi

INPUT="$1"
LAUNCH_NAME="${2:-}"

# Get API token
echo "Authenticating with ReportPortal..."
TOKEN=$(curl -sf -X POST "${RP_URL}/uat/sso/oauth/token" \
    -H "Authorization: Basic dWk6dWltYW4=" \
    -d "grant_type=password&username=${RP_USER}&password=${RP_PASS}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

if [ -z "$TOKEN" ]; then
    echo "ERROR: Failed to authenticate. Is ReportPortal running?"
    exit 1
fi

echo "Authenticated successfully."

# Function to import a single file
import_file() {
    local file="$1"
    local name="$2"
    echo "Importing: ${file} as '${name}'..."

    local IMPORT_ARGS=(-F "file=@${file}")
    if [ -n "$name" ]; then
        IMPORT_ARGS+=(-F "launchImportRq={\"launchName\": \"${name}\"};type=application/json")
    fi

    RESPONSE=$(curl -sf -X POST \
        "${RP_URL}/api/v1/plugin/${RP_PROJECT}/${RP_PLUGIN}/import" \
        -H "Authorization: Bearer ${TOKEN}" \
        "${IMPORT_ARGS[@]}")

    echo "  Result: ${RESPONSE}"
}

# Import single file or directory
if [ -f "$INPUT" ]; then
    import_file "$INPUT" "$LAUNCH_NAME"
elif [ -d "$INPUT" ]; then
    echo "Importing all XML files from: ${INPUT}"
    find "$INPUT" -name "*.xml" -type f | while read -r xmlfile; do
        basename_no_ext=$(basename "$xmlfile" .xml)
        import_file "$xmlfile" "${LAUNCH_NAME} - ${basename_no_ext}"
    done
else
    echo "ERROR: ${INPUT} is not a file or directory"
    exit 1
fi

echo ""
echo "Done! View results at: ${RP_URL}/ui/#${RP_PROJECT}/launches/all"
