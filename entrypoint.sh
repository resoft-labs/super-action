#!/bin/bash

set -e

# Configuration
TEMP_WORKFLOW_PATH="/tmp/dynamic_workflow.yml"
RESULTS_FILE="/tmp/results.json"
DEFAULT_RUNNER_OS="ubuntu-latest"
ACTION_LIST_FILE="/tmp/input_action_list.yaml"
PRESETS_YAML_FILE="/tmp/input_presets.yaml"
MERGED_ACTIONS_YAML_FILE="/tmp/merged_actions.yaml"
ID_NAME_MAP_FILE="/tmp/id_name_map.json" # File to store ID -> Name mapping
PRESETS_DIR="/presets"

# Input Validation
if [ -z "$INPUT_PRESETS" ] && [ -z "$INPUT_ACTION_LIST" ]; then
  echo "::error::At least one of 'presets' or 'action_list' inputs must be provided."
  exit 1
fi

# Check if yq is available
if ! command -v yq &> /dev/null; then
    echo "::error::yq is not installed in the container. This is unexpected."
    exit 1
fi

# Check if act is available
if ! command -v act &> /dev/null; then
    echo "::error::act is not installed in the container. This is unexpected."
    exit 1
fi

# Prepare Merged Actions YAML
echo "::debug::Preparing merged actions YAML"
# Start with an empty sequence
echo "[]" > "$MERGED_ACTIONS_YAML_FILE"

# Process Presets if provided
if [ -n "$INPUT_PRESETS" ]; then
  echo "$INPUT_PRESETS" > "$PRESETS_YAML_FILE"
  # Validate presets input is a sequence
  if ! yq -e 'tag == "!!seq"' "$PRESETS_YAML_FILE"; then
    echo "::error::Input 'presets' must be a YAML sequence (array)."
    cat "$PRESETS_YAML_FILE"
    exit 1
  fi

  echo "::debug::Processing presets..."
  preset_count=$(yq 'length' "$PRESETS_YAML_FILE")
  for i in $(seq 0 $((preset_count - 1))); do
    preset_name=$(yq ".[$i]" "$PRESETS_YAML_FILE")
    preset_file="${PRESETS_DIR}/${preset_name}.json"

    if [ -f "$preset_file" ]; then
      echo "::debug::Adding preset: $preset_name from file $preset_file"
      # Convert preset JSON to YAML and merge it into the sequence
      yq eval-all '. as $item ireduce ([]; . * $item)' "$MERGED_ACTIONS_YAML_FILE" <(yq -P '.' "$preset_file") > /tmp/merged_temp.yaml
      mv /tmp/merged_temp.yaml "$MERGED_ACTIONS_YAML_FILE"
    else
      echo "::warning::Preset file not found for requested preset: $preset_name (expected at $preset_file)"
    fi
  done
fi

# Process Custom Action List if provided
if [ -n "$INPUT_ACTION_LIST" ]; then
  echo "$INPUT_ACTION_LIST" > "$ACTION_LIST_FILE"
  # Validate custom action list input is a sequence
  if ! yq -e 'tag == "!!seq"' "$ACTION_LIST_FILE"; then
    echo "::error::Input 'action_list' must be a YAML sequence (array)."
    cat "$ACTION_LIST_FILE"
    exit 1
  fi
  echo "::debug::Adding custom actions from action_list..."
  # Merge the custom action list sequence with the presets sequence
  yq eval-all '. as $item ireduce ([]; . * $item)' "$MERGED_ACTIONS_YAML_FILE" "$ACTION_LIST_FILE" > /tmp/merged_temp.yaml
  mv /tmp/merged_temp.yaml "$MERGED_ACTIONS_YAML_FILE"
fi

echo "::debug::Final merged actions YAML:"
cat "$MERGED_ACTIONS_YAML_FILE"

# Prepare Workflow File
echo "::debug::Generating temporary workflow file at ${TEMP_WORKFLOW_PATH}"

# Use provided runner_os or default
RUNNER_OS="${INPUT_RUNNER_OS:-$DEFAULT_RUNNER_OS}"

# Start workflow structure and ID->Name map
echo "{}" > "$ID_NAME_MAP_FILE" # Initialize map file
cat << EOF > "$TEMP_WORKFLOW_PATH"
name: Dynamic Workflow Execution
on: push # 'act' requires an event, 'push' is common for local testing
jobs:
  dynamic_job:
    runs-on: ${RUNNER_OS}
    steps:
EOF

# Generate steps from the MERGED actions YAML using yq
count=$(yq 'length' "$MERGED_ACTIONS_YAML_FILE")
for i in $(seq 0 $((count - 1))); do
  # Check if it's a 'uses' step or a 'run' step
  action_uses=$(yq ".[$i].uses // \"\"" "$MERGED_ACTIONS_YAML_FILE")   # Provide default empty string if null
  action_run=$(yq ".[$i].run // \"\"" "$MERGED_ACTIONS_YAML_FILE")

  if [ -n "$action_uses" ]; then
    # Handle 'uses' step
    action_name_part=$(echo "$action_uses" | cut -d'@' -f1 | sed 's|[/]|-|g')
    action_id="action_${i}_${action_name_part}"
    # Get the original name, default if not provided, trim whitespace, and remove newlines
    original_action_name=$(yq "(.[\$i].name // \"Run ${action_uses}\") | trim" "$MERGED_ACTIONS_YAML_FILE" | tr -d '\n')
    # Store mapping: ID -> {name: Original Name, uses: Action Uses}
    jq --arg id "$action_id" \
       --arg name "$original_action_name" \
       --arg uses_str "$action_uses" \
       '. + {($id): {"name": $name, "uses": $uses_str}}' \
       "$ID_NAME_MAP_FILE" > /tmp/id_map_temp.json && mv /tmp/id_map_temp.json "$ID_NAME_MAP_FILE"

    echo "      - name: ${original_action_name} (${action_id})" >> "$TEMP_WORKFLOW_PATH" # Use original name in step title
    echo "        id: ${action_id}" >> "$TEMP_WORKFLOW_PATH"
    echo "        uses: ${action_uses}" >> "$TEMP_WORKFLOW_PATH"

    # Add 'with' parameters if they exist
    if yq -e ".[$i].with | type == \"!!map\" and length > 0" "$MERGED_ACTIONS_YAML_FILE" > /dev/null; then
      echo "        with:" >> "$TEMP_WORKFLOW_PATH"
      # Let yq handle quoting by default, remove explicit style removal
      yq ".[$i].with" "$MERGED_ACTIONS_YAML_FILE" | sed 's/^/          /' >> "$TEMP_WORKFLOW_PATH"
    fi

  elif [ -n "$action_run" ]; then
    # Handle 'run' step
    action_id="action_${i}_run"
    # Get the original name, default if not provided, trim whitespace, and remove newlines
    original_action_name=$(yq "(.[\$i].name // \"Run script \${i}\") | trim" "$MERGED_ACTIONS_YAML_FILE" | tr -d '\n')
    # Store mapping: ID -> {name: Original Name, uses: null}
    jq --arg id "$action_id" \
       --arg name "$original_action_name" \
       '. + {($id): {"name": $name, "uses": null}}' \
       "$ID_NAME_MAP_FILE" > /tmp/id_map_temp.json && mv /tmp/id_map_temp.json "$ID_NAME_MAP_FILE"

    echo "      - name: ${original_action_name} (${action_id})" >> "$TEMP_WORKFLOW_PATH" # Use original name in step title
    echo "        id: ${action_id}" >> "$TEMP_WORKFLOW_PATH"

    # Add shell if specified, default to bash
    action_shell=$(yq ".[$i].shell // \"bash\"" "$MERGED_ACTIONS_YAML_FILE")
    echo "        shell: ${action_shell}" >> "$TEMP_WORKFLOW_PATH"

    # Add working-directory if specified
    action_wd=$(yq ".[$i].\"working-directory\" // \"\"" "$MERGED_ACTIONS_YAML_FILE")
    if [ -n "$action_wd" ]; then
       echo "        working-directory: ${action_wd}" >> "$TEMP_WORKFLOW_PATH"
    fi

    echo "        run: |" >> "$TEMP_WORKFLOW_PATH"
    # Extract the run script and indent it correctly
    yq ".[$i].run" "$MERGED_ACTIONS_YAML_FILE" | sed 's/^/          /' >> "$TEMP_WORKFLOW_PATH"

  else
    # Neither 'uses' nor 'run' found - invalid step definition
    echo "::error::Invalid step definition at index $i in merged actions. Must contain 'uses' or 'run'."
    yq ".[$i]" "$MERGED_ACTIONS_YAML_FILE"
    exit 1
  fi
done

# Add the final step to collect results and write to a file (simple version)
cat << EOF >> "$TEMP_WORKFLOW_PATH"
      - name: Collect Results
        id: collect_results_step
        if: always() # Ensure this runs even if previous steps fail
        shell: bash
        run: |
          echo "Writing raw results to ${RESULTS_FILE}..."
          # Use printf; subsequent processing will parse this potentially non-standard JSON
          printf '%s\n' "\${{ toJSON(steps) }}" > "${RESULTS_FILE}"
          echo "Raw results written."
EOF

echo "::debug::Generated workflow content:"
cat "$TEMP_WORKFLOW_PATH"

# Execute Workflow with act
echo "::group::Running act..."
# Run 'act' targeting the specific job.
# Use --container-architecture linux/amd64 for broader compatibility if needed.
# Use --bind to mount the workspace if actions need access to checked-out code.
# Use --secret-file if secrets are needed (requires careful handling).
# The '--output' flag in act is complex; writing to a file from within the workflow is more reliable here.
act push -P ubuntu-latest=-self-hosted --workflows "$TEMP_WORKFLOW_PATH" --job dynamic_job --bind --directory "$GITHUB_WORKSPACE" --container-architecture linux/amd64
# Consider adding error handling for 'act' execution itself
echo "::endgroup::"

# Process the run results
if [ -f "$RESULTS_FILE" ] && [ -f "$ID_NAME_MAP_FILE" ]; then
  echo "::debug::Processing results from ${RESULTS_FILE} and ID->Name map from ${ID_NAME_MAP_FILE}"
  # Read the potentially non-standard JSON results
  RAW_RESULTS_CONTENT=$(cat "$RESULTS_FILE")
  # Read the ID->Name map
  ID_NAME_MAP_JSON=$(cat "$ID_NAME_MAP_FILE")

  FINAL_RESULTS_ARRAY="[" # Start building the final JSON array string
  FIRST_ENTRY=true

  # Extract all top-level keys (step IDs) from the raw results content
  # This requires careful parsing as it's not guaranteed valid JSON/YAML
  # Using grep to find lines starting with "  step_id:"
  ALL_STEP_IDS=$(echo "$RAW_RESULTS_CONTENT" | grep -E '^[[:space:]]{2}[a-zA-Z0-9_-]+:' | sed -e 's/^[[:space:]]*//; s/:.*//')

  for STEP_ID in $ALL_STEP_IDS; do
      # Look up info from the map using the current STEP_ID
      STEP_INFO_JSON=$(echo "$ID_NAME_MAP_JSON" | jq -c --arg id "$STEP_ID" '.[$id] // {}') # Get map entry or empty object
      ORIGINAL_NAME=$(echo "$STEP_INFO_JSON" | jq -r '.name // null')
      USES_STR=$(echo "$STEP_INFO_JSON" | jq -r '.uses // null')

      # Use mapped name if available, otherwise use the step ID itself
      DISPLAY_NAME=${ORIGINAL_NAME:-$STEP_ID}
      JSON_NAME=$(echo "$DISPLAY_NAME" | jq -R -s .) # Escape name for JSON
      JSON_USES=$(echo "$USES_STR" | jq -R -s .) # Escape uses for JSON (will be "null" if not applicable)


      # Extract outcome for this STEP_ID using awk for better block handling
      # Find the block starting with "  step_id:" and ending with "  },"
      # Within that block, find the line "outcome: value"
      STEP_OUTCOME=$(echo "$RAW_RESULTS_CONTENT" | awk -v step_id="^  ${STEP_ID}:" '/^\s*}/ { if(p) p=0 } $0 ~ step_id { p=1 } p && /outcome:/ { print $2; exit }' | sed 's/,*$//')
      # Default outcome if not found
      STEP_OUTCOME=${STEP_OUTCOME:-unknown}

      # Extract outputs object string for this STEP_ID
      # This is complex with shell tools, find the 'outputs: {' line and extract until the matching '}'
      # Using awk for block extraction might be better, but let's try grep/sed first (might be fragile)
      # This extracts lines between "outputs: {" and the next "}," or "}" at the same indentation level
      OUTPUTS_STR=$(echo "$RAW_RESULTS_CONTENT" | sed -n "/^  ${STEP_ID}:/,/^\s*}/p" | sed -n '/outputs: {/,/}/p' | sed '1d;$d' | sed 's/^    //') # Basic attempt, likely needs refinement
      # Try to format the extracted outputs as valid JSON
      STEP_OUTPUTS_JSON=$(echo "{${OUTPUTS_STR}}" | jq -c . 2>/dev/null || echo '{}')

      # Append to the final array string
      if [ "$FIRST_ENTRY" = true ]; then FIRST_ENTRY=false; else FINAL_RESULTS_ARRAY+=","; fi
      # Add the 'uses' field
      JSON_ENTRY=$(printf '{"id":"%s","name":%s,"uses":%s,"outcome":"%s","outputs":%s}' \
          "$STEP_ID" "$JSON_NAME" "$JSON_USES" "$STEP_OUTCOME" "$STEP_OUTPUTS_JSON")
      FINAL_RESULTS_ARRAY+="$JSON_ENTRY"
  done

  # No need to add collect_results_step manually, it should be captured by iterating ALL_STEP_IDS

  FINAL_RESULTS_ARRAY+="]" # Close the array

  # Validate the constructed JSON array
  if echo "$FINAL_RESULTS_ARRAY" | jq -e . > /dev/null; then
      RESULTS_JSON="$FINAL_RESULTS_ARRAY"
      echo "::debug::Successfully parsed and formatted results."
  else
      echo "::error::Failed to construct valid final results JSON. Falling back to empty array."
      cat "$RESULTS_FILE" # Show raw results for debugging
      RESULTS_JSON="[]"
  fi

else
  if [ ! -f "$RESULTS_FILE" ]; then
      echo "::warning::Results file ${RESULTS_FILE} not found after act execution."
  fi
   if [ ! -f "$ID_NAME_MAP_FILE" ]; then
      echo "::warning::ID->Name map file ${ID_NAME_MAP_FILE} not found."
  fi
  echo "::warning::Setting empty results due to missing files."
  RESULTS_JSON="[]" # Use empty array for consistency
fi
# Remove the ID map file as it's no longer needed after workflow generation
rm -f "$ID_NAME_MAP_FILE"


# Set Action Output
echo "::debug::Setting action output 'results'"
# Ensure the output is properly escaped for multiline JSON
# Using echo "results<<EOF" is safer for multiline output
echo "results<<EOF" >> "$GITHUB_OUTPUT"
echo "$RESULTS_JSON" >> "$GITHUB_OUTPUT"
echo "EOF" >> "$GITHUB_OUTPUT"

# Display Results in Log (Conditional)
# Default to true if the input is not provided or empty
DISPLAY_RESULTS="${INPUT_DISPLAY_RESULTS:-true}"
if [ "$DISPLAY_RESULTS" = "true" ]; then
  echo "::group::Super-Action Collected Results (JSON)"
  # Use jq to pretty-print the JSON to the log (already processed)
  echo "$RESULTS_JSON" | jq '.' || echo "$RESULTS_JSON" # Fallback to raw echo if jq fails or results are not JSON
  echo "::endgroup::"
else
  echo "::debug::Result display is disabled by the 'display_results' input."
fi

# Save Results to File (Optional)
if [ -n "$INPUT_RESULTS_OUTPUT_FILE" ]; then
  # Ensure the path is relative to the workspace
  # Basic check to prevent absolute paths or path traversal
  if [[ "$INPUT_RESULTS_OUTPUT_FILE" == /* ]] || [[ "$INPUT_RESULTS_OUTPUT_FILE" == *..* ]]; then
    echo "::error::'results_output_file' must be a relative path within the workspace and cannot contain '..'."
    exit 1
  fi

  output_filepath="${GITHUB_WORKSPACE}/${INPUT_RESULTS_OUTPUT_FILE}"
  echo "::debug::Saving results to file: ${output_filepath}"
  # Create directory if it doesn't exist
  mkdir -p "$(dirname "$output_filepath")"
  # Save the potentially enhanced JSON
  echo "$RESULTS_JSON" > "$output_filepath"
  echo "Results saved to ${INPUT_RESULTS_OUTPUT_FILE}"
fi

echo "::debug::Action finished successfully."

# Cleanup
rm -f "$TEMP_WORKFLOW_PATH"
rm -f "$RESULTS_FILE"
rm -f "$ACTION_LIST_FILE" "$PRESETS_YAML_FILE" "$MERGED_ACTIONS_YAML_FILE" # Clean up main temp files

exit 0
