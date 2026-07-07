
# go into downloaded_artifacts directory
mkdir -p downloaded_artifacts
cd downloaded_artifacts || exit 1

# REPO ="scania-goldcup/bms_minions"

# Download all artifacts that are not already downloaded
gh api repos/scania-goldcup/bms_minions/actions/artifacts --paginate \
  --jq '.artifacts[].id' |
while read -r artifact_id; do
  run_id=$(gh api "repos/scania-goldcup/bms_minions/actions/artifacts/$artifact_id" --jq '.workflow_run.id')
  
  # Change to new format
  if [ -d "artifact-$artifact_id" ]; then
    echo "Artifact $artifact_id is old format, renaming to use run_id $run_id."
    mv "artifact-$artifact_id" "run-$run_id-artifact-$artifact_id"
    continue
  fi
  if [ -d "run-$run_id-artifact-$artifact_id" ]; then
    echo "Artifact $artifact_id for run $run_id already downloaded, skipping."
    continue
  fi
  gh api \
    -H "Accept: application/vnd.github+json" \
    repos/scania-goldcup/bms_minions/actions/artifacts/$artifact_id/zip \
    > artifact-$artifact_id.zip
    echo "Downloaded artifact $artifact_id"
    # Unzip the artifact
    unzip -o artifact-$artifact_id.zip -d artifact-$artifact_id
    # Remove the zip file after extraction
    rm artifact-$artifact_id.zip
    # Remove if there is no .xml file in the extracted directory
    if ! find artifact-$artifact_id -type f -name "*.xml" | grep -q .; then
        echo "No .xml files found in artifact $artifact_id, removing all content in directory."
        rm -rf artifact-$artifact_id
        mkdir -p artifact-$artifact_id
    fi
    # Rename the directory to include the run_id for clarity
    mv artifact-$artifact_id "run-$run_id-artifact-$artifact_id"
done
