# Super-Action GitHub Action

This **Docker-based** action allows you to define a sequence of other GitHub Actions to run via a JSON input and executes them using `nektos/act` inside its container, collecting their results.

**Author:** ReSoft Labs <info@resoftlabs.com>
**Repository:** [https://github.com/resoft-labs/super-action](https://github.com/resoft-labs/super-action)

## Description

The primary goal of this action is to execute a series of specified actions, defined in a JSON array and passed as an input. It dynamically generates a temporary workflow file and runs it using `nektos/act` within its Docker container. It then provides the outcome (success/failure) and outputs of each executed action step (as captured by `act`'s simulation) as a JSON object.

**This approach overcomes the limitation of composite actions by simulating a workflow run inside the action's container.**

## Inputs

-   `presets` (optional): A YAML sequence (list) of predefined action preset names to run. Presets are run in the order specified, before any custom actions defined in `actions_yaml`. See "Available Presets" below.
    Example:
    ```yaml
    presets:
      - checkout
      - setup-node-20
    ```
-   `action_list` (optional): A YAML string representing a sequence (array) of custom actions to run. These run *after* any specified presets. Each item should have `uses` and optionally `with`. Use YAML block scalar syntax (`|` or `>`).
    Example:
    ```yaml
    action_list: |
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v3
        with:
          node-version: 18
    ```
    *Note: At least one of `presets` or `action_list` must be provided.*
-   `results_output_file` (optional): Path relative to the workspace root where the results JSON should be saved (e.g., `super_action_results.json` or `outputs/results.json`). If provided, the action writes the results to this file, which can then be used by subsequent steps (like uploading as an artifact).
-   `runner_os` (optional, default: `ubuntu-latest`): The operating system specified in the `runs-on` key within the temporary workflow executed by `act` (e.g., `ubuntu-latest`, `windows-latest`, `macos-latest`). `act` will attempt to pull the appropriate runner image.

## Outputs

-   `results`: A JSON string representing an array of objects. Each object provides details about a single step executed within the dynamic workflow run by `act`. The internal `collect_results_step` is excluded. Each object includes:
    -   `name` (string): The display name for the step. This is taken directly from the `name` field you provided in the `presets` or `action_list` input. If you didn't provide a `name`, a default is generated (e.g., "Run actions/setup-node@v4" or "Run script 0"). For steps generated internally by `act` (like setup/cleanup tasks, if any were captured), this might default to the internal step ID.
    -   `uses` (string | null): If the step executed a pre-built action, this field contains the action reference string (e.g., `"actions/setup-python@v5"`). If the step executed a script using `run`, this field will be `null`.
    -   `run` (string | null): If the step executed a script, this field contains the command string specified in the `run` key. If the step used `uses`, this field will be `null`.
    -   `outcome` (string): The final execution status of the step, as reported by `act`. Common values include `"success"`, `"failure"`, or `"skipped"`. The parsing logic defaults to `"unknown"` if the outcome cannot be reliably determined from `act`'s output.
    -   `outputs` (object): A dictionary (key-value map) containing outputs explicitly set by the step during its execution using the `::set-output name=key::value` workflow command. If a step did not set any outputs, this will be an empty object (`{}`). **Note:** This field does *not* contain the step's standard output (stdout) or standard error (stderr) streams.
    **Note:** The action also automatically prints this JSON output (pretty-printed) to the main workflow logs within a collapsible group named "Super-Action Collected Results (JSON)", unless this behavior is disabled by setting the `display_results` input to `'false'`.

    **Example `results` Output:**
    ```json
    [
      {
        "name": "Simple Echo",
        "uses": null,
        "run": "echo \"Running a custom echo command.\"",
        "outcome": "success",
        "outputs": {}
      },
      {
        "name": "Set up Python",
        "uses": "actions/setup-python@v5",
        "run": null,
        "outcome": "success",
        "outputs": {
          "python-path": "/github/home/.cache/act/tool_cache/Python/3.12.9/x64/bin/python",
          "python-version": "3.12.9"
        }
      },
      {
        "name": "Show Python Version",
        "uses": null,
        "run": "python --version",
        "outcome": "success",
        "outputs": {}
      }
    ]
    ```

## Execution Model & Dependencies

-   **Docker Action**: This action runs inside a Docker container defined by the `Dockerfile`. The runner executing this action must have Docker installed and configured to run containers. Standard GitHub-hosted runners support Docker actions.
-   **nektos/act**: The core execution is handled by `nektos/act` within the container. `act` simulates the GitHub Actions runner environment.
-   **yq**: The `entrypoint.sh` script uses `yq` (from mikefarah) to parse the `action_list` input. It's included in the Docker image.
-   **Docker-in-Docker**: `act` often requires Docker itself to run action steps that use Docker (e.g., building images, service containers). The Dockerfile installs `docker.io`, but running Docker-in-Docker can have security implications and might require privileged mode on self-hosted runners.

## Available Presets

Presets encapsulate one or more predefined steps. They are defined as JSON files within the `presets/` directory of this action's repository. The name of the preset corresponds to the filename (without the `.json` extension).

To add a new preset (e.g., `my-preset`):
1.  Create a file named `presets/my-preset.json`.
2.  Define the sequence of steps within this file using standard GitHub Actions step syntax, formatted as a JSON array. Example `presets/my-preset.json`:
    ```json
    [
      {
        "name": "My Preset Step 1",
        "uses": "actions/some-action@v1",
        "with": {
          "input1": "value1"
        }
      },
      {
        "name": "My Preset Step 2",
        "run": "echo 'Running second step'"
      }
    ]
    ```
3.  Users can then request this preset using `presets: [ my-preset ]`.

The following presets are currently included:

-   `checkout`: Runs `actions/checkout@v4`. (Defined in `presets/checkout.json`)
-   `checkout-deep`: Runs `actions/checkout@v4` with `fetch-depth: 0`. (Defined in `presets/checkout-deep.json`)
-   `setup-node-20`: Runs `actions/setup-node@v4` with `node-version: '20'`. (Defined in `presets/setup-node-20.json`)
-   `setup-node-lts`: Runs `actions/setup-node@v4` with `node-version: 'lts/*'`. (Defined in `presets/setup-node-lts.json`)
-   `node-setup-install`: Multi-step preset for checkout, Node.js LTS setup (with npm cache), and `npm ci`. (Defined in `presets/node-setup-install.json`)

## Usage Examples

See the following example workflow files in the `.github/workflows/` directory for detailed usage patterns:

1.  **Custom Actions Only:** `.github/workflows/example-custom-actions.yml`
    *   Demonstrates using only the `action_list` input to define a sequence of custom steps.

2.  **Presets Only:** `.github/workflows/example-presets-only.yml`
    *   Demonstrates using only the `presets` input to run predefined action sequences (like `node-setup-install`).

3.  **Presets and Custom Actions Combined:** `.github/workflows/example-presets-and-custom.yml`
    *   Demonstrates using both `presets` and `action_list` together.
    *   Shows how to save the results to a file using `results_output_file` and upload it as an artifact using `actions/upload-artifact`.

4.  **Local Reference:** `.github/workflows/example-local-ref.yml`
    *   Demonstrates using the action via a local path reference (`uses: resoft-labs/super-action@main` or `uses: ./`), which builds the local `Dockerfile`. Useful for testing changes to the action itself.

## Local Testing with act

You can test this action locally using `nektos/act` if you have Docker and `act` installed on your machine.

1.  **Prerequisites:**
    *   Install Docker: [https://docs.docker.com/get-docker/](https://docs.docker.com/get-docker/)
    *   Install act: [https://github.com/nektos/act#installation](https://github.com/nektos/act#installation)

2.  **Create an Event File (Optional but Recommended):**
    Create a file (e.g., `event.json`) with minimal event payload:
    ```json
    {}
    ```

3.  **Prepare Input:**
    Define the inputs. Create a file named `super-action.env`:
    ```env
    # Example using presets and custom actions via env vars (complex escaping needed)
    INPUT_PRESETS="- node-setup-install" # Use the file-based preset name
    INPUT_ACTION_LIST="- name: Run Build\n  run: npm run build"
    # Optional: To test file output locally:
    INPUT_RESULTS_OUTPUT_FILE=local_test_results.json
    # Optional: INPUT_RUNNER_OS=ubuntu-latest
    ```
    *Recommendation: For local testing, it's often easier to modify the `presets` and `action_list` blocks directly in the example workflow files.*

4.  **Run `act`:**
    Execute `act` from the root of the `super-action` repository, targeting one of the example workflow files:
    ```bash
    # Example: List jobs in the combined workflow for the 'push' event
    act push -W .github/workflows/example-presets-and-custom.yml -l

    # Example: Run the specific job from the combined workflow for the 'push' event
    act push -W .github/workflows/example-presets-and-custom.yml -j run_combined_steps

    # Example: Run the job from the presets-only workflow for the 'push' event
    # act push -W .github/workflows/example-presets-only.yml -j run_preset_steps

    # Example: Run the job from the custom-actions-only workflow for the 'push' event
    # act push -W .github/workflows/example-custom-actions.yml -j run_custom_steps

    # If using an .env file for inputs:
    # act push -W .github/workflows/example-presets-and-custom.yml -j run_combined_steps --env-file super-action.env
    ```
    *   Ensure you are running the command from the root directory of the `super-action` project.
    *   If `act push -W ... -l` doesn't list the expected job, there might be an issue with how `act` is parsing the workflow file or detecting the event trigger. Double-check the workflow syntax and consult `act`'s documentation or issue tracker.
    *   If the job is listed, running `act push -W <workflow_file> -j <job_id>` should execute the job.
    *   When it reaches the `uses: ./` step, it will execute your local `super-action` using the Docker container.
    *   The `entrypoint.sh` script will run inside the container, using the `presets` and `action_list` defined in the workflow file as input.
    *   You will see the output from `act`, including the logs from the dynamically executed actions and the automatically logged "Super-Action Collected Results (JSON)" group at the end of the `super-action` step.

## Considerations & Potential Issues

-   **Performance**: Running actions via `act` inside a Docker container introduces overhead compared to running them directly on the runner. This includes container startup time and `act`'s simulation time.
-   **Compatibility**: `act` aims to simulate the GitHub Actions environment but might have differences or limitations compared to the actual runners, especially with complex workflows, matrix strategies, or specific runner features.
-   **Secrets**: Passing secrets securely to actions run via `act` requires careful handling. The current `entrypoint.sh` does not explicitly manage secrets passed to `act`. You might need to mount a secret file (`--secret-file`) if the dynamic actions require them.
-   **Resource Usage**: Running `act` and potentially Docker-in-Docker can consume significant resources (CPU, memory, disk space) on the runner.
-   **Network**: Network access from within the `act` simulation might differ from the main runner environment.
-   **Artifacts/Caching**: Handling artifacts and caching between the main workflow and the `act`-executed workflow requires explicit volume mounts or other strategies within the `entrypoint.sh` if needed. The current script uses `--bind` to mount the workspace.
