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
    # Get the original name, default if not provided
    original_action_name=$(yq ".[$i].name // \"Run ${action_uses}\"" "$MERGED_ACTIONS_YAML_FILE")
    # Store mapping: ID -> Original Name
    jq --arg id "$action_id" --arg name "$original_action_name" '. + {($id): $name}' "$ID_NAME_MAP_FILE" > /tmp/id_map_temp.json && mv /tmp/id_map_temp.json "$ID_NAME_MAP_FILE"

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
    # Get the original name, default if not provided
    original_action_name=$(yq ".[$i].name // \"Run script ${i}\"" "$MERGED_ACTIONS_YAML_FILE")
    # Store mapping: ID -> Original Name
    jq --arg id "$action_id" --arg name "$original_action_name" '. + {($id): $name}' "$ID_NAME_MAP_FILE" > /tmp/id_map_temp.json && mv /tmp/id_map_temp.json "$ID_NAME_MAP_FILE"

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

# Add the final step to collect results and write to a file
cat << EOF >> "$TEMP_WORKFLOW_PATH"
      - name: Collect Results
        id: collect_results_step
        if: always() # Ensure this runs even if previous steps fail
        shell: bash
        run: |
          echo "Writing results to ${RESULTS_FILE}..."
          # Use printf to safely write JSON content to the file
          printf '%s\n' "\${{ toJSON(steps) }}" > "${RESULTS_FILE}"
          echo "Results written."
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
  echo "::debug::Reading results from ${RESULTS_FILE} and ID->Name map from ${ID_NAME_MAP_FILE}"
  # Read raw results (steps context)
  RAW_RESULTS_JSON=$(cat "$RESULTS_FILE")
  # Read the generated ID->Name map
  ID_NAME_MAP_JSON=$(cat "$ID_NAME_MAP_FILE")

  # --- Start Debugging ---
  echo "::debug::--- Debugging JSON content ---"
  echo "::debug::ID->Name Map File (${ID_NAME_MAP_FILE}) Content:"
  cat "$ID_NAME_MAP_FILE"
  echo "::debug::Validating ID->Name Map JSON:"
  if jq -e . "$ID_NAME_MAP_FILE" > /dev/null; then echo "::debug::ID->Name Map JSON is valid."; else echo "::error::ID->Name Map JSON is INVALID."; fi

  echo "::debug::Results File (${RESULTS_FILE}) Content:"
  cat "$RESULTS_FILE"
  echo "::debug::Validating Results JSON:"
  if jq -e . "$RESULTS_FILE" > /dev/null; then echo "::debug::Results JSON is valid."; else echo "::error::Results JSON is INVALID."; fi
  echo "::debug::--- End Debugging JSON content ---"
  # --- End Debugging ---


  # Use jq to add the original name to each step result
  ENHANCED_RESULTS_JSON=$(jq -n --argjson rawResults "$RAW_RESULTS_JSON" --argjson idNameMap "$ID_NAME_MAP_JSON" '
    $rawResults | to_entries | map(
      .key as $stepId | .value as $stepResult |
      {
        id: $stepId,
        name: ($idNameMap[$stepId] // $stepId), # Use mapped name, fallback to stepId if not found
        outcome: $stepResult.outcome,
        outputs: $stepResult.outputs
      }
    )
  ')

  # Check if jq command succeeded
  if [ $? -eq 0 ] && [ -n "$ENHANCED_RESULTS_JSON" ]; then
      RESULTS_JSON="$ENHANCED_RESULTS_JSON"
      echo "::debug::Successfully added action names to results."
  else
      echo "::warning::Failed to add action names to results using jq. Falling back to raw results."
      RESULTS_JSON="$RAW_RESULTS_JSON"
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
rm -f "$ACTION_LIST_FILE" "$PRESETS_YAML_FILE" "$MERGED_ACTIONS_YAML_FILE" "$ID_NAME_MAP_FILE" # Clean up all temp files

exit 0
