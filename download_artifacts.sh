
# go into downloaded_artifacts directory
mkdir -p downloaded_artifacts
cd downloaded_artifacts || exit 1

# Make variable for the repository to fetch artifacts from
REPO="scania-goldcup/bms-pp"
OLDEST_DATE="2026-07-07T00:00:00Z"

# Remove all folders that are empty and has "artifact" in the name
find . -type d -name "*artifact*" -empty -delete

# Download all artifacts that are not already downloaded
# First check if run 
gh run list --repo "$REPO" --limit 1000 --json databaseId \
  --jq '.[].databaseId' |
while read -r run_id; do
    completed=$(gh run view "$run_id" --repo "$REPO" --json status --jq '.status')
    if [ "$completed" != "completed" ]; then
        echo "Run $run_id is not completed, skipping."
        continue
    fi
    timestamp=$(gh run view "$run_id" --repo "$REPO" --json createdAt --jq '.createdAt')
    if [[ "$timestamp" < "$OLDEST_DATE" ]]; then
        echo "Run $run_id is older than $OLDEST_DATE, skipping."
        continue
    fi
    run_name=$(gh run view "$run_id" --repo "$REPO" --json name --jq '.name')
    echo "Processing run $run_id, with run name \"$run_name\" from timestamp $timestamp"
    
    # Create a directory for the run to block re-downloading the same run in the future
    run_dir="run-$run_id"
    # Check if the run has already been downloaded (run id is part of folder name)
    if find . -maxdepth 1 -type d -name "*$run_id*" | grep -q .; then
        echo "Run $run_id already downloaded, skipping."
        continue
    fi
    mkdir -p "$run_dir"


    gh api "repos/$REPO/actions/runs/$run_id/artifacts" \
      --jq '.artifacts[] | .id' |
    while read -r artifact_id; do
        echo "  Found artifact $artifact_id"
        run_id=$(gh api "repos/$REPO/actions/artifacts/$artifact_id" --jq '.workflow_run.id')
        artifact_name=$(gh api "repos/$REPO/actions/artifacts/$artifact_id" --jq '.name')
        folder_name="run-$run_id-artifact-$artifact_id"
        # Only download artifacts that has "mini-hil" in the name
        if ! echo "$artifact_name" | grep -Eiq "mini-hil"; then
            echo "Skipping artifact $artifact_id ($artifact_name) as it does not match the pattern."
            continue
        fi

        # Download the artifact as a zip file
        gh api \
            -H "Accept: application/vnd.github+json" \
            repos/$REPO/actions/artifacts/$artifact_id/zip \
            > "$folder_name.zip"
            echo "Downloaded artifact $artifact_id"
            # Unzip the artifact
            unzip -o "$folder_name.zip" -d "$folder_name"
            # Remove the zip file after extraction
            rm "$folder_name.zip"
            # Remove if there is no .xml file in the extracted directory
            if ! find "$folder_name" -type f -name "*.xml" | grep -q .; then
                echo "No .xml files found in artifact $artifact_id, removing all content in directory."
                rm -rf "$folder_name"
                mkdir -p "$folder_name"
            fi
        done
done
