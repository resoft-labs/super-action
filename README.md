# Super-Action

This **Docker-based** action allows you to define a sequence of other GitHub Actions to run via a JSON input and executes them inside its container, collecting their results.

**Author:** Faruk Diblen - ReSoft Labs <info@resoftlabs.com>
**Repository:** [https://github.com/resoft-labs/super-action](https://github.com/resoft-labs/super-action)

## Description

`super-action` allows you to dynamically define and execute a sequence of GitHub Actions steps within a single job step. You provide a list of actions (using `uses`) or commands (using `run`) via inputs, and `super-action` runs them sequentially inside its isolated Docker container environment. It then collects the results (outcome and outputs) of each executed step.

This provides a way to create reusable, parameterized sequences of actions that can be invoked dynamically, offering more flexibility than standard GitHub Actions features like Composite Actions in certain scenarios.

## Use Cases

`super-action` can be beneficial when:

- **Dynamic Step Generation:** You need to run a different set of actions or commands based on runtime conditions (e.g., file changes, API responses, previous step outputs) that cannot be easily determined using standard workflow `if` conditions on steps. You can generate the `action_list` input dynamically in a prior step.
- **Complex Reusable Logic:** You have a complex sequence of setup, build, test, or deployment steps involving multiple existing actions that you want to encapsulate into a single, reusable unit with parameters, potentially exceeding the limitations of Composite Actions.
- **Simulating Workflows:** You want to test or simulate parts of a workflow locally or within another workflow using `nektos/act`.
- **Action Orchestration:** You need finer-grained control over a sequence of actions than standard job dependencies allow, potentially running them within a specific container environment provided by `super-action`.

## Comparison with Composite Actions

| Feature                 | Super-Action                                     | Composite Action                                  |
| :---------------------- | :----------------------------------------------- | :------------------------------------------------ |
| **Execution Context**   | Runs steps inside its own Docker container       | Runs steps directly on the runner machine         |
| **Step Definition**     | Dynamic (via `presets` / `action_list` inputs)   | Static (defined in `action.yml` of composite)     |
| **Action Types Allowed**| Can run *any* other action (Docker, JS, Composite) | Can only run `run` scripts and `uses` JS actions |
| **Environment**         | Isolated Docker environment                      | Runner's environment                              |
| **Performance**         | Slower (Docker startup + `act` overhead)         | Faster (direct execution)                         |
| **Use Case**            | Dynamic execution, running Docker actions        | Reusable sequences of `run` and JS actions        |

**Key Differences:**

- **Flexibility vs. Simplicity:** `super-action` offers more flexibility by allowing dynamic step definition and running any action type (including Docker actions) but introduces complexity and performance overhead. Composite actions are simpler and faster but are limited to static definitions and cannot directly run Docker actions.
- **Environment:** `super-action` provides an isolated environment, while composite actions share the runner's environment.

Choose `super-action` when you need the dynamic execution capabilities or the ability to run Docker-based actions within your sequence. Choose Composite Actions for simpler, faster execution of reusable `run` scripts and JavaScript actions.

## Inputs

- `presets` (optional): A YAML sequence (list) of predefined action preset names to run. Presets are run in the order specified, before any custom actions defined in `actions_yaml`. See "Available Presets" below.
    Example:
    ```yaml
    presets:
      - checkout
      - setup-node-22
    ```
- `action_list` (optional): A YAML string representing a sequence (array) of custom actions to run. These run *after* any specified presets. Each item should have `uses` and optionally `with`. Use YAML block scalar syntax (`|` or `>`).
    Example:
    ```yaml
    action_list: |
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v3
        with:
          node-version: 22
    ```
    *Note: At least one of `presets` or `action_list` must be provided.*
- `results_output_file` (optional): Path relative to the workspace root where the results JSON should be saved (e.g., `super_action_results.json` or `outputs/results.json`). If provided, the action writes the results to this file, which can then be used by subsequent steps (like uploading as an artifact).
- `runner_os` (optional, default: `ubuntu-latest`): The operating system specified in the `runs-on` key within the temporary workflow executed by `act` (e.g., `ubuntu-latest`, `windows-latest`, `macos-latest`). `act` will attempt to pull the appropriate runner image.

## Outputs

- `results`: A JSON string representing an array of objects. Each object provides details about a single step executed within the dynamic workflow run by `act`. The internal `collect_results_step` is excluded. Each object includes:
    - `name` (string): The display name for the step. This is taken directly from the `name` field you provided in the `presets` or `action_list` input. If you didn't provide a `name`, a default is generated (e.g., "Run actions/setup-node@v4" or "Run script 0"). For steps generated internally by `act` (like setup/cleanup tasks, if any were captured), this might default to the internal step ID.
    - `uses` (string | null): If the step executed a pre-built action, this field contains the action reference string (e.g., `"actions/setup-python@v5"`). If the step executed a script using `run`, this field will be `null`.
    - `run` (string | null): If the step executed a script, this field contains the command string specified in the `run` key. If the step used `uses`, this field will be `null`.
    - `outcome` (string): The final execution status of the step, as reported by `act`. Common values include `"success"`, `"failure"`, or `"skipped"`. The parsing logic defaults to `"unknown"` if the outcome cannot be reliably determined from `act`'s output.
    - `outputs` (object): A dictionary (key-value map) containing outputs explicitly set by the step during its execution using the `::set-output name=key::value` workflow command. If a step did not set any outputs, this will be an empty object (`{}`). **Note:** This field does *not* contain the step's standard output (stdout) or standard error (stderr) streams.
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

- **Docker Action**: This action runs inside a Docker container defined by the `Dockerfile`. The runner executing this action must have Docker installed and configured to run containers. Standard GitHub-hosted runners support Docker actions.
- **nektos/act**: The core execution is handled by `nektos/act` within the container. `act` simulates the GitHub Actions runner environment.
- **Python 3 & PyYAML**: The `entrypoint.py` script uses Python and the PyYAML library for input parsing and workflow generation. These are included in the Docker image.
- **yq & jq**: These tools are included in the Docker image for YAML/JSON processing within scripts if needed (though the core logic now uses Python).
- **Docker-in-Docker**: `act` often requires Docker itself to run action steps that use Docker (e.g., building images, service containers). The Dockerfile installs `docker.io`, but running Docker-in-Docker can have security implications and might require privileged mode on self-hosted runners. The `super-action` container itself needs access to the host's Docker socket (`/var/run/docker.sock`) for `act` to function correctly.

## Available Presets

Presets encapsulate one or more predefined steps. They are defined as JSON files within the `presets/` directory of this action's repository. The name of the preset corresponds to the filename (without the `.json` extension).

The following presets are currently included:

- `checkout`: Runs `actions/checkout@v4`. (Defined in `presets/checkout.json`)
- `checkout-deep`: Runs `actions/checkout@v4` with `fetch-depth: 0`. (Defined in `presets/checkout-deep.json`)
- `setup-node-22`: Runs `actions/setup-node@v4` with `node-version: '20'`. (Defined in `presets/setup-node-20.json`)
- `setup-node-lts`: Runs `actions/setup-node@v4` with `node-version: 'lts/*'`. (Defined in `presets/setup-node-lts.json`)
- `node-setup-install`: Multi-step preset for checkout, Node.js LTS setup (with npm cache), and `npm ci`. (Defined in `presets/node-setup-install.json`)
- `git-config-user`: Configures git user email and name to default values. (Defined in `presets/git-config-user.json`)
- `setup-python-lts`: Sets up the latest Python 3 LTS version using `actions/setup-python@v5` with pip cache enabled. (Defined in `presets/setup-python-lts.json`)
- `setup-python-3.12`: Sets up Python 3.12 using `actions/setup-python@v5` with pip cache enabled. (Defined in `presets/setup-python-3.12.json`)

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

5.  **All Presets:** `.github/workflows/all-presets.yml`
    *   Shows an example combining several common presets (`checkout`, `git-config-user`, `setup-node-lts`, `setup-python-lts`) followed by a verification script.

## Considerations & Potential Issues

- **Performance**: Running actions via `act` inside a Docker container introduces overhead compared to running them directly on the runner. This includes container startup time and `act`'s simulation time.
- **Compatibility**: `act` aims to simulate the GitHub Actions environment but might have differences or limitations compared to the actual runners, especially with complex workflows, matrix strategies, or specific runner features.
- **Secrets**: Passing secrets securely to actions run via `act` requires careful handling. The current `entrypoint.py` does not explicitly manage secrets passed to `act`. You might need to use `act`'s `--secret` or `--secret-file` flags if the dynamic actions require them, which would require modifying the `subprocess` call in `entrypoint.py`.
- **Resource Usage**: Running `act` and potentially Docker-in-Docker can consume significant resources (CPU, memory, disk space) on the runner.
- **Network**: Network access from within the `act` simulation might differ from the main runner environment.
- **Artifacts/Caching**: Handling artifacts and caching between the main workflow and the `act`-executed workflow is not directly supported. `act` runs in an isolated manner. Steps within the dynamic workflow can use standard caching actions (like `actions/cache`), but this cache is separate from the main workflow's cache. Artifacts produced inside the `act` run are not automatically available outside unless written to the mounted workspace (`--bind` is used by default).
