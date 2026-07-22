#!/bin/bash
set -euo pipefail

# go into downloaded_artifacts directory
mkdir -p downloaded_artifacts
cd downloaded_artifacts || exit 1

DEFAULT_REPOS=(
    "scania-goldcup/bms_minions"
    "scania-goldcup/bms-pp"
)

OLDEST_DATE="${OLDEST_DATE:-2026-07-08T00:00:00Z}"
RUN_LIMIT="${RUN_LIMIT:-300}"
ARTIFACT_PATTERN="${ARTIFACT_PATTERN:-mini-hil}"

if [ $# -gt 0 ]; then
    REPOS=("$@")
elif [ -n "${REPOS:-}" ]; then
    read -r -a REPOS <<< "$REPOS"
else
    REPOS=("${DEFAULT_REPOS[@]}")
fi

has_junit_xml() {
    local dir="$1"

    find "$dir" -type f -name "*.xml" -exec grep -qE '<testsuites?[[:space:]>]' {} \; -print -quit | grep -q .
}

for REPO in "${REPOS[@]}"; do
    echo "=== Downloading artifacts from $REPO ==="

    # Download all artifacts that are not already downloaded
    gh run list --repo "$REPO" --limit "$RUN_LIMIT" --json databaseId \
      --jq '.[].databaseId' |
    while read -r run_id; do

        #run_name=$(gh run view "$run_id" --repo "$REPO" --json name --jq '.name')
        #echo "Processing run $run_id, with run name \"$run_name\" from timestamp $timestamp"

        # Only a completion marker proves that every matching artifact was processed.
        # An empty run directory may be left behind by an interrupted download.
        run_dir="run-$run_id"
        if [ -f "$run_dir/.download-complete" ]; then
            echo "Run $run_id already downloaded, skipping."
            continue
        fi

        completed=$(gh run view "$run_id" --repo "$REPO" --json status --jq '.status')
        if [ "$completed" != "completed" ]; then
            echo "Run $run_id is not completed, skipping."
            continue
        fi
        timestamp=$(gh run view "$run_id" --repo "$REPO" --json createdAt --jq '.createdAt')
        if [[ "$timestamp" < "$OLDEST_DATE" ]]; then
            echo "Run $run_id is older than $OLDEST_DATE, stopping scan for $REPO."
            break
        fi
        echo "Processing run $run_id from timestamp $timestamp"
        mkdir -p "$run_dir"

        gh api "repos/$REPO/actions/runs/$run_id/artifacts?per_page=100" \
          --jq '.artifacts[] | [.id, .name, .expired] | @tsv' |
        while IFS=$'\t' read -r artifact_id artifact_name artifact_expired; do
            echo "  Found artifact $artifact_id"
            folder_name="run-$run_id-artifact-$artifact_id"
            # Only download artifacts that match the configured pattern
            if ! echo "$artifact_name" | grep -Eiq "$ARTIFACT_PATTERN"; then
                echo "Skipping artifact $artifact_id ($artifact_name) as it does not match the pattern."
                continue
            fi

            if [ "$artifact_expired" = "true" ]; then
                echo "Skipping artifact $artifact_id ($artifact_name) because it has expired."
                continue
            fi

            if [ -f "$folder_name/.download-complete" ] || \
               { [ -d "$folder_name" ] && has_junit_xml "$folder_name"; }; then
                echo "Artifact $artifact_id already downloaded, skipping."
                mkdir -p "$folder_name"
                touch "$folder_name/.download-complete"
                continue
            fi

            # Download to a temporary name so a failed transfer cannot look complete.
            partial_zip="$folder_name.zip.part"
            gh api \
                -H "Accept: application/vnd.github+json" \
                repos/$REPO/actions/artifacts/$artifact_id/zip \
                > "$partial_zip"

            if ! unzip -tq "$partial_zip" >/dev/null; then
                echo "ERROR: Downloaded artifact $artifact_id is not a valid ZIP; it will be retried."
                exit 1
            fi

            mv -f "$partial_zip" "$folder_name.zip"
            echo "Downloaded artifact $artifact_id"
            # Unzip the artifact
            unzip -o "$folder_name.zip" -d "$folder_name"
            # Remove the zip file after extraction
            rm "$folder_name.zip"
            # Remove if there is no JUnit XML file in the extracted directory
            if ! has_junit_xml "$folder_name"; then
                echo "No JUnit XML files found in artifact $artifact_id, removing all content in directory."
                rm -rf "$folder_name"
                mkdir -p "$folder_name"
            fi
            touch "$folder_name/.download-complete"
        done

        touch "$run_dir/.download-complete"
    done
done
