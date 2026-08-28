# Configuration

Project configuration lives at `.agentlocalci/pipeline.yml`. Version 0.2 accepts JSON syntax as a deliberately restricted JSON-compatible YAML subset.

## Automatic setup

```powershell
agentlocalci init
# or
agentlocalci quickstart --commit
```

With `package.json` and `package-lock.json`, setup detects existing `lint`, typecheck variants, non-placeholder `test`, and `build` scripts. It emits only safe npm argv and never embeds the script body.

Gradle setup detects committed wrappers at `gradlew`, `android/gradlew`, and `apps/android/gradlew`. Unknown project shapes receive a non-acceptance diagnostic profile.

Always review the generated file before treating it as policy.

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

A stage has `id`, argv-array `command`, safe relative `working_directory`, dependency-cache `needs`, optional policy-approved non-secret `environment`, and bounded `timeout_seconds`.

Stages remain sequential in 0.2. `needs` names dependency cache types, not stage dependencies. Command-string flags such as `bash -c`, `pwsh -Command`, `cmd /c`, `node -e`, and `python -c` are rejected. Commit a script file and invoke it by argv.

## Machine policy locations

- Windows: `%LOCALAPPDATA%\AgentLocalCI\policy.yml`
- macOS: `~/Library/Application Support/AgentLocalCI/policy.yml`
- Linux: `$XDG_STATE_HOME/agentlocalci/policy.yml` or `~/.local/state/agentlocalci/policy.yml`

A repository cannot broaden machine policy. Policy files must remain inside the selected AgentLocalCI home.
