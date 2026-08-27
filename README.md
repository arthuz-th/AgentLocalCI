# AgentLocalCI

**Local-first, exact-commit CI for Windows and Docker Desktop.**

AgentLocalCI runs repository-defined checks on your own machine without sending the job to GitHub Actions. It packages one exact local Git tree, executes stages in fresh locked-down Linux containers, writes a local report, and removes every run-owned Docker resource it can prove it owns.

> Status: **0.1 alpha**. The security boundary and supported workflows are intentionally narrow. Read [THREAT_MODEL.md](THREAT_MODEL.md) and [docs/limitations.md](docs/limitations.md) before using it as an acceptance gate.

## What it is

- An on-demand CLI named `agentlocalci`.
- A local CI controller for an **exact lowercase 40-character commit SHA** already present in your local Git object database.
- A Windows-hosted controller that uses Docker Desktop with Linux containers.
- A safe-by-default way to run deterministic lint, test, typecheck, and build commands locally.
- A local report and cleanup system with explicit acceptance versus diagnostic-only profiles.

## What it is not

- It is **not** a GitHub Actions self-hosted runner.
- It does not listen for webhooks, public pull requests, or remote commands.
- It does not fetch branches, tags, or missing commits.
- It does not forward Git credentials, cloud credentials, SSH agents, Docker sockets, host directories, or personal files.
- It does not approve a merge, deployment, release, or production change by itself.
- It is not yet a universal replacement for every operating system, toolchain, service container, or integration test.

## Why use it

For private repositories, GitHub-hosted Actions jobs consume the plan's included minutes and can become billable after the allowance. AgentLocalCI runs outside GitHub Actions, so routine AgentLocalCI runs do not consume GitHub Actions minutes or GitHub-hosted runner charges. Your own electricity, hardware, disk, Docker image downloads, and dependency network traffic still have real costs.

For public repositories, GitHub's standard hosted runners are already free and unlimited. AgentLocalCI can still be useful there for exact-commit local gates, offline validation stages, privacy, reproducibility, and keeping untrusted project code away from host files.

See [docs/billing.md](docs/billing.md) for precise wording and official GitHub references.

## Security boundary

Every validation stage uses a fresh container with:

- non-root UID/GID `10001:10001`;
- read-only root filesystem;
- all Linux capabilities dropped;
- `no-new-privileges`;
- no host bind mounts;
- no Docker socket, devices, ports, credentials, or personal directories;
- `network=none` during validation;
- source materialized from an exact-tree Git object pack, not from the host checkout.

When dependencies are required, AgentLocalCI first prepares disposable caches through a trusted IPv4-only HTTPS CONNECT proxy. The proxy accepts only exact machine-policy-approved hostnames on port 443. Validation then uses the prepared cache with networking disabled.

See [docs/security.md](docs/security.md).

## Requirements

- Windows 11 or a currently supported Windows 10 release.
- PowerShell 7.4 or newer.
- Git for Windows.
- Docker Desktop configured for Linux containers.
- At least 20 GiB free disk by the default machine policy.

No GitHub token is required to run CI. The target commit must already exist locally.

## Install

From a checked-out AgentLocalCI repository:

```powershell
pwsh -NoProfile -File .\install.ps1
agentlocalci doctor --build-image
```

The installer creates a user-local, side-by-side installation under `%LOCALAPPDATA%\AgentLocalCI`. It does not replace or modify another product-specific CI installation.

## Configure a project

From the target repository root:

```powershell
agentlocalci init
```

Review and commit `.agentlocalci/pipeline.yml`. The file is JSON-compatible YAML in 0.1; JSON syntax is valid and recommended while the parser remains intentionally small.

Minimal generic example:

```json
{
  "schema_version": 1,
  "project": { "name": "my-project" },
  "default_profile": "standard",
  "dependency_hosts": [],
  "environment": {},
  "dependencies": {},
  "profiles": {
    "standard": {
      "description": "Local acceptance checks",
      "acceptance": true,
      "gaps": ["Deployment and hosted-service tests are outside this profile."],
      "stages": [
        {
          "id": "test",
          "command": ["pwsh", "-NoLogo", "-NoProfile", "-File", "tests/run.ps1"],
          "working_directory": ".",
          "needs": [],
          "timeout_seconds": 1800
        }
      ]
    }
  }
}
```

Commands are argv arrays. Commit script files and invoke them; command-string interpreter flags such as `bash -c`, `pwsh -Command`, or `cmd /c` are rejected.

## Run one exact commit

```powershell
$sha = (git rev-parse HEAD).Trim()
agentlocalci run --profile standard --sha $sha
```

AgentLocalCI rejects `HEAD`, branch names, tags, abbreviated SHAs, uppercase SHAs, missing objects, and an SHA whose object is not a commit.

Useful commands:

```powershell
agentlocalci status
agentlocalci report <RUN_ID>
agentlocalci doctor --build-image
agentlocalci clean
agentlocalci clean --images
agentlocalci service start   # enables the on-demand policy; it does not start a daemon
agentlocalci service stop    # disables new runs; it does not stop a service
```

Exit codes:

| Code | Meaning |
|---:|---|
| 0 | Acceptance profile passed |
| 1 | A validation stage failed |
| 2 | Usage, configuration, or target error |
| 3 | Controller or infrastructure failure |
| 4 | Safety policy blocked the run |
| 5 | Cleanup could not be proven complete |
| 6 | Diagnostic-only profile completed |
| 130 | Cancelled |

## Supported dependency modes

- `npm`: online `npm ci --ignore-scripts` prepares a disposable cache; validation runs offline.
- `gradle`: a committed Gradle wrapper resolves dependencies into a disposable cache; validation runs offline.
- no dependency mode: arbitrary committed scripts and executables already present in the trusted image may run with `network=none`.

Examples are under [`examples/`](examples/).

## Trust and cleanup

The controller records container, network, and volume identity as `type + name + owner + run + kind`. Cleanup only acts on a dead or completed run after exact label matching, removes resources in dependency order, and verifies absence after deletion. Ambiguous or unclaimed owner-labelled resources are retained and make cleanup fail closed.

The same Windows user and anyone with Docker daemon access are inside the trusted host boundary. AgentLocalCI does not defend against a malicious host administrator or Docker operator.

## Development

```powershell
pwsh -NoProfile -File .\tests\run-unit.ps1
pwsh -NoProfile -File .\tests\run-docker-integration.ps1
pwsh -NoProfile -File .\tests\run-adversarial-e2e.ps1
pwsh -NoProfile -File .\tests\run-installer-integration.ps1
pwsh -NoProfile -File .\scripts\run-quality.ps1
```

This repository deliberately contains no GitHub Actions workflow. Maintainers run the same exact-commit gate locally and publish the resulting commit, report summary, SBOM, and checksums as release evidence.

## Project documents

- [Architecture](docs/architecture.md)
- [Configuration](docs/configuration.md)
- [Security](docs/security.md)
- [Threat model](THREAT_MODEL.md)
- [Limitations](docs/limitations.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
