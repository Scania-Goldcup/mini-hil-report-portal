#!/bin/bash
# Fetch JUnit XML reports from remote test machines and import into ReportPortal
# Usage: ./fetch_reports.sh [discover|fetch|all]
#
# Machines are defined in ~/.ssh/config (stuart, jorge, bob)

set -euo pipefail
cd "$(dirname "$0")"

# host_alias=user@ip
declare -A HOSTS
HOSTS[stuart]="github-runner@10.254.0.19"
HOSTS[jorge]="github-runner@10.254.0.22"
HOSTS[bob]="github-runner@10.254.0.17"
REMOTE_USER="github-runner"
LOCAL_REPORTS_DIR="./remote_reports"
MAX_RESULTS_PER_HOST="${MAX_RESULTS_PER_HOST:-500}"

# --- Discovery mode: find where reports are on each machine ---
discover() {
    echo "=== Discovering JUnit XML files on remote machines ==="
    echo ""
    for name in "${!HOSTS[@]}"; do
        local conn="${HOSTS[$name]}"
        echo "--- $name ($conn) ---"
        local results
        results=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$conn" \
            "find /home/$REMOTE_USER -type f -path '*/_work/*' -name 'junit.xml' 2>/dev/null | head -$MAX_RESULTS_PER_HOST") \
            || { echo "  (connection failed)"; echo ""; continue; }

        if [ -n "$results" ]; then
            echo "$results"
        else
            echo "  (no junit.xml found under _work)"
        fi
        echo ""
    done
}

# --- Fetch mode: rsync reports from all machines ---
fetch() {
    echo "=== Fetching reports from remote machines ==="
    mkdir -p "$LOCAL_REPORTS_DIR"

    for name in "${!HOSTS[@]}"; do
        local conn="${HOSTS[$name]}"
        echo ""
        echo "--- $name ($conn) ---"
        local dest="$LOCAL_REPORTS_DIR/$name"
        mkdir -p "$dest"

        local files
        files=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$conn" \
            "find /home/$REMOTE_USER -type f -path '*/_work/*' -name 'junit.xml' 2>/dev/null | head -$MAX_RESULTS_PER_HOST") \
            || { echo "  (connection failed)"; continue; }

        if [ -z "$files" ]; then
            echo "  (no junit.xml found under _work)"
            continue
        fi

        echo "$files" | while read -r remote_path; do
            [ -z "$remote_path" ] && continue
            local rel_path
            rel_path="${remote_path#*/_work/}"
            if [ "$rel_path" = "$remote_path" ]; then
                rel_path="$(basename "$(dirname "$remote_path")")/junit.xml"
            fi
            local local_file="$dest/$rel_path"
            local local_dir
            local_dir="$(dirname "$local_file")"
            mkdir -p "$local_dir"
            echo "  Fetching: $remote_path -> $local_file"
            scp -q -o StrictHostKeyChecking=no "$conn:$remote_path" "$local_file"
        done
    done

    echo ""
    echo "Reports saved to: $LOCAL_REPORTS_DIR/"
    find "$LOCAL_REPORTS_DIR" -name "junit.xml" | sort
}

# --- Import mode: import all fetched reports into ReportPortal ---
import_all() {
    echo "=== Importing fetched reports into ReportPortal ==="
    
    if [ ! -d "$LOCAL_REPORTS_DIR" ]; then
        echo "No reports directory found. Run '$0 fetch' first."
        exit 1
    fi

    RP_URL="${RP_URL:-http://localhost:8080}"
    TOKEN=$(curl -sf -X POST "${RP_URL}/uat/sso/oauth/token" \
        -H "Authorization: Basic dWk6dWltYW4=" \
        -d "grant_type=password&username=superadmin&password=erebus" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

    find "$LOCAL_REPORTS_DIR" -name "junit.xml" | sort | while read -r xmlfile; do
        # Extract host and test dir from path for the launch name
        local rel_path="${xmlfile#$LOCAL_REPORTS_DIR/}"
        local host_name="${rel_path%%/*}"
        local test_dir="${rel_path#*/}"
        test_dir="${test_dir%/junit.xml}"
        local launch_name="${host_name}/${test_dir}"

        echo "  Importing: $xmlfile as '$launch_name'"
        curl -sf -X POST \
            "${RP_URL}/api/v1/plugin/superadmin_personal/junit/import" \
            -H "Authorization: Bearer ${TOKEN}" \
            -F "file=@${xmlfile};type=application/xml" \
            || echo "    (import failed)"
    done

    echo ""
    echo "Done! View at: http://localhost:8080/ui/#superadmin_personal/launches/all"
}

# --- Main ---
case "${1:-discover}" in
    discover)
        discover
        ;;
    fetch)
        fetch
        ;;
    import)
        import_all
        ;;
    all)
        fetch
        echo ""
        import_all
        ;;
    *)
        echo "Usage: $0 [discover|fetch|import|all]"
        echo ""
        echo "  discover  - Find junit.xml files on remote machines"
        echo "  fetch     - Download reports from remote machines"  
        echo "  import    - Import previously fetched reports into ReportPortal"
        echo "  all       - Fetch and import in one step"
        exit 1
        ;;
esac
