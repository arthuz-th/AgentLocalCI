# Configuration

Project configuration lives at `.agentlocalci/pipeline.yml`. Version 0.1 accepts JSON syntax as a deliberately restricted JSON-compatible YAML subset.

## Top-level fields

- `schema_version`: must be `1`.
- `project.name`: 1–80 safe display characters.
- `default_profile`: profile ID.
- `dependency_hosts`: exact lowercase hostnames, each also allowed by machine policy.
- `environment`: non-secret values whose names are allowed by machine policy.
- `dependencies`: optional `npm` and `gradle` definitions.
- `profiles`: one or more named profiles.

Unknown properties fail validation.

## Stages

A stage has:

- `id`: lowercase identifier.
- `command`: argv array, never a `shell:` string.
- `working_directory`: safe path relative to repository root; `.` is valid.
- `needs`: zero or more of `npm`, `gradle`.
- `environment`: optional policy-approved non-secret values.
- `timeout_seconds`: positive value no greater than machine policy.

Stages are sequential in 0.1. `needs` refers to dependency cache types, not stage dependencies.

Command-string interpreter flags such as `bash -c`, `pwsh -Command`, `cmd /c`, `node -e`, and `python -c` are rejected. Commit a script file and invoke the file.

## npm

```json
"dependencies": {
  "npm": {
    "working_directory": ".",
    "lockfile": "package-lock.json"
  }
}
```

The exact tree must contain the lockfile. Preparation runs `npm ci --ignore-scripts --no-audit --no-fund` through the controlled proxy. Validation mounts the resulting cache and configures offline mode.

## Gradle

```json
"dependencies": {
  "gradle": {
    "working_directory": "android",
    "wrapper": "gradlew"
  }
}
```

The wrapper and lock-relevant build files must be committed. Preparation uses the wrapper and a trusted init script to resolve dependencies. Each validation stage receives a fresh writable run-private copy of the prepared Gradle user-home while networking is disabled; stage changes are never promoted to another stage or run.

## Machine policy

The default user-local policy is `%LOCALAPPDATA%\AgentLocalCI\policy.yml`. It controls enablement, executor, allowed dependency hosts, allowed environment names, resource ceilings, timeouts, output limits, required profiles, and required stage IDs.

A repository cannot broaden machine policy. Policy files must remain inside the selected AgentLocalCI home.
