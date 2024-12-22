#!/usr/bin/env python3
"""
Main entrypoint script for the super-action.
Handles input processing, dynamic workflow generation, execution via 'act',
and processing of results using a helper Python script.
"""

import os
import sys
import json
import yaml
import subprocess
import tempfile
import shutil
from pathlib import Path
from typing import List, Dict, Any, Optional, Tuple

# --- Configuration ---
DEFAULT_RUNNER_OS = "ubuntu-latest"
PRESETS_DIR = Path("/presets")
TEMP_DIR = Path(tempfile.gettempdir())
MERGED_ACTIONS_FILE = TEMP_DIR / "merged_actions.yaml"
ID_INDEX_MAP_FILE = TEMP_DIR / "id_index_map.json"
RESULTS_FILE = TEMP_DIR / "results.json" # File written by act step
TEMP_WORKFLOW_FILE = TEMP_DIR / "dynamic_workflow.yml"
PYTHON_PARSER_SCRIPT = Path("/usr/local/bin/parse_results.py")

# --- Helper Functions ---
def fail_action(message: str) -> None:
    """Prints an error message and exits."""
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)

def debug_log(message: str) -> None:
    """Prints a debug message if runner debugging is enabled."""
    if os.environ.get('RUNNER_DEBUG') == '1':
        print(f"::debug::{message}", file=sys.stderr)

def set_output(name: str, value: str) -> None:
    """Sets an action output, handling multiline values."""
    github_output_path = os.environ.get('GITHUB_OUTPUT')
    if not github_output_path:
        print("::warning::GITHUB_OUTPUT environment variable not set. Cannot set action output.", file=sys.stderr)
        return
    try:
        with open(github_output_path, 'a', encoding='utf-8') as f:
            f.write(f"{name}<<EOF\n")
            f.write(f"{value}\n")
            f.write("EOF\n")
    except Exception as e:
        print(f"::warning::Failed to write to GITHUB_OUTPUT file {github_output_path}: {e}", file=sys.stderr)

def load_presets(preset_names_yaml: Optional[str]) -> List[Dict[str, Any]]:
    """Loads actions from specified preset files."""
    actions = []
    if not preset_names_yaml:
        return actions

    try:
        preset_names = yaml.safe_load(preset_names_yaml)
        if not isinstance(preset_names, list):
            fail_action("Input 'presets' must be a YAML sequence (list).")

        debug_log(f"Processing presets: {preset_names}")
        for name in preset_names:
            preset_file = PRESETS_DIR / f"{name}.json"
            if preset_file.is_file():
                debug_log(f"Loading preset '{name}' from {preset_file}")
                try:
                    with open(preset_file, 'r', encoding='utf-8') as f:
                        preset_actions = json.load(f)
                    if isinstance(preset_actions, list):
                        actions.extend(preset_actions)
                    else:
                        print(f"::warning::Preset file {preset_file} does not contain a JSON list.", file=sys.stderr)
                except json.JSONDecodeError as e:
                    print(f"::warning::Failed to decode JSON from preset file {preset_file}: {e}", file=sys.stderr)
                except Exception as e:
                     print(f"::warning::Failed to read preset file {preset_file}: {e}", file=sys.stderr)
            else:
                print(f"::warning::Preset file not found for requested preset: {name} (expected at {preset_file})", file=sys.stderr)
    except yaml.YAMLError as e:
        fail_action(f"Failed to parse 'presets' input YAML: {e}")
    except Exception as e:
         fail_action(f"Error processing presets: {e}")
    return actions

def load_custom_actions(action_list_yaml: Optional[str]) -> List[Dict[str, Any]]:
    """Loads custom actions from the action_list input."""
    actions = []
    if not action_list_yaml:
        return actions

    try:
        custom_actions = yaml.safe_load(action_list_yaml)
        if not isinstance(custom_actions, list):
            fail_action("Input 'action_list' must be a YAML sequence (list).")
        debug_log(f"Adding {len(custom_actions)} custom actions from action_list.")
        actions.extend(custom_actions)
    except yaml.YAMLError as e:
        fail_action(f"Failed to parse 'action_list' input YAML: {e}")
    except Exception as e:
         fail_action(f"Error processing action_list: {e}")
    return actions

def generate_workflow_and_map(
    merged_actions: List[Dict[str, Any]],
    runner_os: str
) -> Tuple[Dict[str, Any], Dict[str, int]]:
    """Generates the dynamic workflow dict and the ID-to-Index map."""
    id_index_map: Dict[str, int] = {}
    workflow_steps: List[Dict[str, Any]] = []

    for i, action in enumerate(merged_actions):
        action_uses = action.get('uses')
        action_run = action.get('run')
        action_name = action.get('name')
        action_id = ""

        if action_uses:
            action_name_part = action_uses.split('@')[0].replace('/', '-')
            action_id = f"action_{i}_{action_name_part}"
            if not action_name:
                action_name = f"Run {action_uses}"
        elif action_run:
            action_id = f"action_{i}_run"
            if not action_name:
                action_name = f"Run script {i}"
        else:
            fail_action(f"Invalid step definition at index {i}. Must contain 'uses' or 'run'. Step: {action}")

        cleaned_name = " ".join(str(action_name).split()).strip()
        id_index_map[action_id] = i

        step_dict: Dict[str, Any] = {
            'name': f"{cleaned_name} ({action_id})",
            'id': action_id
        }
        if action_uses:
            step_dict['uses'] = action_uses
            if 'with' in action:
                step_dict['with'] = action['with']
        elif action_run:
            step_dict['shell'] = action.get('shell', 'bash')
            if 'working-directory' in action:
                 step_dict['working-directory'] = action['working-directory']
            step_dict['run'] = action_run

        workflow_steps.append(step_dict)

    # Add the final results collection step
    workflow_steps.append({
        'name': 'Collect Results',
        'id': 'collect_results_step',
        'if': 'always()',
        'shell': 'bash',
        'run': (
            f"echo 'Writing raw results to {RESULTS_FILE}...' >&2\n"
            f"# Use printf; subsequent processing will parse this potentially non-standard JSON\n"
            f"printf '%s\\n' \"${{{{ toJSON(steps) }}}}\" > \"{RESULTS_FILE}\"\n"
            f"echo 'Raw results written.' >&2"
        )
    })

    workflow_dict = {
        'name': 'Dynamic Workflow Execution',
        'on': {'push': None}, # 'act' requires an event trigger
        'jobs': {
            'dynamic_job': {
                'runs-on': runner_os,
                'steps': workflow_steps
            }
        }
    }
    return workflow_dict, id_index_map

def run_act(workflow_file: Path, runner_os: str, workspace: Path) -> int:
    """Runs the dynamic workflow using act."""
    print("::group::Running act...", file=sys.stderr)
    act_command = [
        "act", "push",
        "-P", f"{runner_os}=-self-hosted",
        "--workflows", str(workflow_file),
        "--job", "dynamic_job",
        "--bind",
        "--directory", str(workspace),
        "--container-architecture", "linux/amd64"
    ]
    debug_log(f"Executing act command: {' '.join(act_command)}")
    exit_code = 0
    try:
        # Stream output directly
        process = subprocess.Popen(act_command, stdout=sys.stdout, stderr=sys.stderr, text=True)
        process.wait()
        exit_code = process.returncode
    except Exception as e:
        fail_action(f"Failed to execute act: {e}")

    print("::endgroup::", file=sys.stderr)
    return exit_code

def process_results(
    results_file: Path,
    id_map_file: Path,
    merged_actions_file: Path
) -> str:
    """Processes results by calling the Python parser script."""
    results_json_str = "[]" # Default to empty array
    if results_file.is_file() and id_map_file.is_file() and merged_actions_file.is_file():
        debug_log("Processing results using Python script...")
        parser_command = [
            "python3",
            str(PYTHON_PARSER_SCRIPT),
            str(results_file),
            str(id_map_file),
            str(merged_actions_file)
        ]
        try:
            parser_process = subprocess.run(parser_command, capture_output=True, text=True, check=True, encoding='utf-8')
            results_json_str = parser_process.stdout.strip()
            if parser_process.stderr:
                 print(f"::debug::Parser script stderr:\n{parser_process.stderr}", file=sys.stderr)

            # Validate final JSON
            try:
                json.loads(results_json_str) # Try parsing
                debug_log("Successfully processed results using Python script.")
            except json.JSONDecodeError:
                print(f"::error::Constructed results JSON is INVALID after Python script processing. Falling back to empty array.", file=sys.stderr)
                print(f"Invalid JSON received: {results_json_str}", file=sys.stderr)
                results_json_str = "[]"

        except subprocess.CalledProcessError as e:
            print(f"::error::Python parser script failed with exit code {e.returncode}.", file=sys.stderr)
            print(f"Parser stdout:\n{e.stdout}", file=sys.stderr)
            print(f"Parser stderr:\n{e.stderr}", file=sys.stderr)
            results_json_str = "[]" # Fallback
        except Exception as e:
            print(f"::error::Error running Python parser script: {e}", file=sys.stderr)
            results_json_str = "[]" # Fallback
    else:
         print("::warning::One or more required files for results processing not found. Setting empty results.", file=sys.stderr)
         if not results_file.is_file(): print(f"::warning::Missing: {results_file}", file=sys.stderr)
         if not id_map_file.is_file(): print(f"::warning::Missing: {id_map_file}", file=sys.stderr)
         if not merged_actions_file.is_file(): print(f"::warning::Missing: {merged_actions_file}", file=sys.stderr)

    return results_json_str

def save_results_to_file(results_json_str: str, output_file: str, workspace: Path) -> None:
    """Saves the results JSON to the specified output file."""
    if not output_file:
        return

    # Basic check to prevent absolute paths or path traversal
    if Path(output_file).is_absolute() or ".." in output_file:
         print("::error::'results_output_file' must be a relative path within the workspace and cannot contain '..'.", file=sys.stderr)
         return # Don't exit, just skip saving

    output_filepath = workspace / output_file
    debug_log(f"Saving results to file: {output_filepath}")
    try:
        output_filepath.parent.mkdir(parents=True, exist_ok=True)
        with open(output_filepath, 'w', encoding='utf-8') as f:
            f.write(results_json_str)
        print(f"Results saved to {output_file}")
    except Exception as e:
        print(f"::warning::Failed to save results to {output_filepath}: {e}", file=sys.stderr)

def display_results_log(results_json_str: str, display_enabled: bool) -> None:
    """Displays the results in the log if enabled."""
    if display_enabled:
        print("::group::Super-Action Collected Results (JSON)", file=sys.stderr)
        try:
            # Pretty print if valid JSON
            parsed_json = json.loads(results_json_str)
            print(json.dumps(parsed_json, indent=2))
        except json.JSONDecodeError:
             print(results_json_str) # Print raw string if not valid JSON
        print("::endgroup::", file=sys.stderr)
    else:
        debug_log("Result display is disabled by the 'display_results' input.")

# --- Main Execution ---
def run():
    """Main execution flow."""
    # --- Get Inputs ---
    input_presets_yaml = os.environ.get('INPUT_PRESETS')
    input_action_list_yaml = os.environ.get('INPUT_ACTION_LIST')
    input_results_output_file = os.environ.get('INPUT_RESULTS_OUTPUT_FILE')
    input_runner_os = os.environ.get('INPUT_RUNNER_OS', DEFAULT_RUNNER_OS)
    input_display_results = os.environ.get('INPUT_DISPLAY_RESULTS', 'true').lower() == 'true'
    github_workspace = Path(os.environ.get('GITHUB_WORKSPACE', '.'))

    debug_log(f"Input Presets YAML: {input_presets_yaml}")
    debug_log(f"Input Action List YAML: {input_action_list_yaml}")
    debug_log(f"Input Results Output File: {input_results_output_file}")
    debug_log(f"Input Runner OS: {input_runner_os}")
    debug_log(f"Input Display Results: {input_display_results}")
    debug_log(f"GitHub Workspace: {github_workspace}")

    if not input_presets_yaml and not input_action_list_yaml:
        fail_action("At least one of 'presets' or 'action_list' inputs must be provided.")

    # --- Merge Actions ---
    presets = load_presets(input_presets_yaml)
    custom_actions = load_custom_actions(input_action_list_yaml)
    merged_actions = presets + custom_actions

    if not merged_actions:
        fail_action("No actions found after processing presets and action_list.")

    debug_log(f"Total merged actions: {len(merged_actions)}")
    try:
        with open(MERGED_ACTIONS_FILE, 'w', encoding='utf-8') as f:
            yaml.dump(merged_actions, f, indent=2)
        debug_log(f"Saved merged actions YAML to {MERGED_ACTIONS_FILE}")
    except Exception as e:
        fail_action(f"Failed to write merged actions file: {e}")

    # --- Generate Workflow & Map ---
    workflow_dict, id_index_map = generate_workflow_and_map(merged_actions, input_runner_os)
    try:
        with open(TEMP_WORKFLOW_FILE, 'w', encoding='utf-8') as f:
             yaml.dump(workflow_dict, f, indent=2, sort_keys=False, default_flow_style=None)
        debug_log(f"Generated temporary workflow file at {TEMP_WORKFLOW_FILE}")
        with open(ID_INDEX_MAP_FILE, 'w', encoding='utf-8') as f:
            json.dump(id_index_map, f)
        debug_log(f"Generated ID->Index map file at {ID_INDEX_MAP_FILE}")
    except Exception as e:
        fail_action(f"Failed to write temporary workflow/map files: {e}")

    # --- Run Act ---
    act_exit_code = run_act(TEMP_WORKFLOW_FILE, input_runner_os, github_workspace)
    if act_exit_code != 0:
         print(f"::warning::'act' command failed with exit code {act_exit_code}. Attempting to process results anyway.", file=sys.stderr)

    # --- Process Results ---
    results_json_str = process_results(RESULTS_FILE, ID_INDEX_MAP_FILE, MERGED_ACTIONS_FILE)

    # --- Handle Outputs ---
    set_output("results", results_json_str)
    display_results_log(results_json_str, input_display_results)
    save_results_to_file(results_json_str, input_results_output_file, github_workspace)

    debug_log("Action finished successfully.")

    # --- Cleanup ---
    # Explicitly remove temp files if desired
    # TEMP_WORKFLOW_FILE.unlink(missing_ok=True)
    # RESULTS_FILE.unlink(missing_ok=True)
    # ID_INDEX_MAP_FILE.unlink(missing_ok=True)
    # MERGED_ACTIONS_FILE.unlink(missing_ok=True)
    # Path(ACTION_LIST_FILE).unlink(missing_ok=True) # These might not exist
    # Path(PRESETS_YAML_FILE).unlink(missing_ok=True)


if __name__ == "__main__":
    run()
