#!/bin/bash
# Download GitHub Actions artifacts and optionally import JUnit XML into ReportPortal.
#
# Usage:
#   ./fetch_gha_artifacts.sh --repo <owner/repo> [options]
#   ./fetch_gha_artifacts.sh --check-repos <owner/repo[,owner/repo,...]>
#
# Options:
#   --repo <owner/repo>        Required, e.g. Scania-Goldcup/bms-pp
#   --check-repos <list>       Check access for one or more repos and exit
#   --workflow <name-or-id>    Optional workflow name or ID filter
#   --branch <branch>          Optional branch filter
#   --limit <n>                Number of runs to scan (default: 30)
#   --artifact-pattern <regex> Artifact name regex (default: junit|report)
#   --out-dir <dir>            Output directory (default: ./gha_artifacts)
#   --import                   Import found junit.xml files into ReportPortal
#   --help                     Show this message

set -euo pipefail
cd "$(dirname "$0")"

REPO=""
CHECK_REPOS=""
WORKFLOW=""
BRANCH=""
LIMIT=30
ARTIFACT_PATTERN="junit|report"
OUT_DIR="./gha_artifacts"
DO_IMPORT=false

usage() {
    sed -n '1,30p' "$0"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)
            REPO="$2"
            shift 2
            ;;
        --check-repos)
            CHECK_REPOS="$2"
            shift 2
            ;;
        --workflow)
            WORKFLOW="$2"
            shift 2
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --limit)
            LIMIT="$2"
            shift 2
            ;;
        --artifact-pattern)
            ARTIFACT_PATTERN="$2"
            shift 2
            ;;
        --out-dir)
            OUT_DIR="$2"
            shift 2
            ;;
        --import)
            DO_IMPORT=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI is required"
    exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: gh is not authenticated. Run: gh auth login"
    exit 1
fi

# Check access mode (no downloads)
if [ -n "$CHECK_REPOS" ]; then
    CHECK_REPOS="$(echo "$CHECK_REPOS" | tr -d '[:space:]')"
    IFS=',' read -r -a REPOS <<< "$CHECK_REPOS"

    echo "Checking repository access..."
    echo ""
    FAIL=0
    for r in "${REPOS[@]}"; do
        if ! echo "$r" | grep -Eq '^[^/]+/[^/]+$'; then
            echo "[FAIL] $r  (invalid format; expected owner/repo)"
            FAIL=1
            continue
        fi

        if ! gh repo view "$r" --json nameWithOwner >/dev/null 2>&1; then
            echo "[FAIL] $r  (no repo access)"
            FAIL=1
            continue
        fi

        if gh run list --repo "$r" --limit 1 --json databaseId >/dev/null 2>&1; then
            echo "[OK]   $r  (repo + actions access)"
        else
            echo "[WARN] $r  (repo access OK, actions access failed)"
            FAIL=1
        fi
    done

    echo ""
    if [ "$FAIL" -eq 0 ]; then
        echo "All checks passed."
        exit 0
    fi
    echo "Some checks failed."
    echo "If this is a private org repo, try: gh auth refresh -h github.com -s repo,actions:read"
    exit 1
fi

if [ -z "$REPO" ]; then
    echo "ERROR: --repo is required (or use --check-repos)"
    usage
    exit 1
fi

# Normalize accidental whitespace/newlines in repo input
REPO="$(echo "$REPO" | tr -d '[:space:]')"

if ! echo "$REPO" | grep -Eq '^[^/]+/[^/]+$'; then
    echo "ERROR: --repo must be in owner/repo format. Got: '$REPO'"
    exit 1
fi

if ! gh repo view "$REPO" --json nameWithOwner >/dev/null 2>&1; then
    echo "ERROR: Cannot access repository '$REPO'."
    echo "Possible causes:"
    echo "  - repo name is wrong"
    echo "  - account/token lacks access to this private repo"
    echo "  - SSO authorization is required for your org"
    echo "Try: gh auth refresh -h github.com -s repo,actions:read"
    echo "Then verify manually: gh repo view $REPO"
    exit 1
fi

mkdir -p "$OUT_DIR"

RUN_ARGS=(--repo "$REPO" --limit "$LIMIT" --json databaseId,workflowName,headBranch,displayTitle,conclusion,status,updatedAt)
if [ -n "$WORKFLOW" ]; then
    RUN_ARGS+=(--workflow "$WORKFLOW")
fi
if [ -n "$BRANCH" ]; then
    RUN_ARGS+=(--branch "$BRANCH")
fi

if ! RUN_JSON=$(gh run list "${RUN_ARGS[@]}" 2>&1); then
    echo "ERROR: failed to get runs from GitHub."
    echo "$RUN_JSON"
    exit 1
fi

RUN_IDS=$(printf '%s\n' "$RUN_JSON" | python3 -c 'import sys,json
runs=json.load(sys.stdin)
for r in runs:
    # include completed runs only
    if r.get("status") == "completed":
        print(r.get("databaseId"))')

if [ -z "$RUN_IDS" ]; then
    echo "No matching completed workflow runs found."
    exit 0
fi

echo "Scanning artifacts for repo: $REPO"
TOTAL_ARTIFACTS=0
DOWNLOADED=0

for run_id in $RUN_IDS; do
    [ -z "$run_id" ] && continue

    ARTIFACT_LINES=$(gh api "repos/$REPO/actions/runs/$run_id/artifacts?per_page=100" \
        --jq '.artifacts[] | select(.expired == false) | "\(.id)\t\(.name)"' || true)

    [ -z "$ARTIFACT_LINES" ] && continue

    run_dir="$OUT_DIR/run_$run_id"
    mkdir -p "$run_dir"

    while IFS=$'\t' read -r artifact_id artifact_name; do
        [ -z "$artifact_id" ] && continue
        TOTAL_ARTIFACTS=$((TOTAL_ARTIFACTS + 1))

        if ! echo "$artifact_name" | grep -Eiq "$ARTIFACT_PATTERN"; then
            continue
        fi

        target_dir="$run_dir/$artifact_name"
        mkdir -p "$target_dir"
        echo "Downloading run $run_id artifact '$artifact_name'..."

        # gh run download extracts artifact contents into target_dir
        if gh run download "$run_id" --repo "$REPO" --name "$artifact_name" --dir "$target_dir" >/dev/null 2>&1; then
            DOWNLOADED=$((DOWNLOADED + 1))
        else
            echo "  Failed to download artifact '$artifact_name' from run $run_id"
        fi
    done <<< "$ARTIFACT_LINES"
done

echo ""
echo "Artifacts scanned: $TOTAL_ARTIFACTS"
echo "Artifacts downloaded: $DOWNLOADED"

echo ""
echo "Looking for junit.xml files in $OUT_DIR ..."
JUNIT_FILES=$(find "$OUT_DIR" -type f -name "junit.xml" 2>/dev/null || true)

if [ -z "$JUNIT_FILES" ]; then
    echo "No junit.xml files found in downloaded artifacts."
    echo "Tip: widen --artifact-pattern or inspect artifact contents manually."
    exit 0
fi

COUNT=$(printf '%s\n' "$JUNIT_FILES" | sed '/^$/d' | wc -l)
echo "Found $COUNT junit.xml file(s):"
printf '%s\n' "$JUNIT_FILES"

if [ "$DO_IMPORT" = true ]; then
    if [ ! -x "./import_junit.sh" ]; then
        chmod +x ./import_junit.sh 2>/dev/null || true
    fi

    echo ""
    echo "Importing junit.xml files into ReportPortal..."
    while read -r xml; do
        [ -z "$xml" ] && continue
        rel="${xml#$OUT_DIR/}"
        launch_name="gha/${REPO}/${rel%/junit.xml}"
        ./import_junit.sh "$xml" "$launch_name"
    done <<< "$JUNIT_FILES"
fi

echo ""
echo "Done. Output directory: $OUT_DIR"
