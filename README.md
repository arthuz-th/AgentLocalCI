# AgentLocalCI

**Run exact-commit CI on your own Windows, macOS, or Linux machine—without sending routine jobs to GitHub Actions.**

AgentLocalCI is designed for developers who want a simple local quality gate without learning CI syntax first. It detects common npm or Gradle checks, runs one committed Git tree inside locked-down Linux containers, creates readable reports, and cleans up only Docker resources it can prove it owns.

> **Version 0.2 beta.** Windows is supported. macOS and Linux host support is beta. The security boundary is intentionally narrower than a general-purpose hosted runner.

## The beginner path

### 1. Install prerequisites

You need PowerShell 7.4+, Git, and a running Linux Docker engine.

**Windows:** install Git, PowerShell 7, and Docker Desktop using Linux containers.

**macOS:**

```bash
brew install powershell
brew install --cask docker
```

Open Docker Desktop once and wait until `docker info` works.

### 2. Install AgentLocalCI

```powershell
git clone https://github.com/arthuz-th/AgentLocalCI.git
cd AgentLocalCI
pwsh -NoProfile -File ./install.ps1
```

Open a new terminal after the installer updates PATH.

### 3. Run one guided command inside your project

```powershell
cd /path/to/your/project
agentlocalci quickstart --commit --open
```

That command:

1. checks PowerShell, Git, Docker, disk, policy, image, network isolation, and cleanup;
2. detects useful npm scripts or a committed Gradle wrapper;
3. creates `.agentlocalci/pipeline.yml`;
4. with `--commit`, creates one narrow commit containing only that file;
5. validates the resulting exact commit;
6. opens a self-contained HTML report.

AgentLocalCI refuses `--commit` when any other file is changed or staged.

## Everyday use

```powershell
agentlocalci check
```

`check` resolves the current full 40-character `HEAD` automatically. It refuses a dirty working tree, so the report always names immutable committed source rather than an ambiguous folder state.

Useful commands:

```powershell
agentlocalci why
agentlocalci doctor --build-image
agentlocalci check --profile fast
agentlocalci report --open
agentlocalci hook install --profile fast
agentlocalci hook status
agentlocalci hook remove
```

The optional pre-push hook is local and opt-in. It will not overwrite a hook that AgentLocalCI does not own.

## Why use this instead of only GitHub Actions?

| Need | AgentLocalCI | GitHub Actions |
|---|---|---|
| Routine checks without hosted-runner minutes | Yes—runs on your machine | Private-repository jobs can consume included or billable minutes |
| Immediate feedback without a hosted queue | Yes | Depends on runner availability |
| Source and logs remain local | Yes, unless you share the report | Source executes on hosted or self-hosted runner infrastructure |
| Exact committed tree and offline validation | Built in | Possible, but workflow authors must design it |
| Pull-request status visible to collaborators | No | Yes |
| Hosted OS/version matrices | No | Yes |
| Deployment and release automation | Intentionally no | Yes |
| Independent verification away from the contributor machine | No | Yes |

AgentLocalCI is strongest as the **first gate**, not as marketing-driven replacement for every hosted workflow:

> Run AgentLocalCI for every local commit or push. Keep a smaller hosted workflow for shared pull-request status, platform matrices, release publishing, and deployment.

See [Why local CI?](docs/why-local-ci.md) and [billing wording](docs/billing.md).

## Security boundary

Every validation stage uses a fresh Linux container with:

- non-root UID/GID `10001:10001`;
- read-only root filesystem;
- all Linux capabilities dropped;
- `no-new-privileges`;
- no host repository bind mount;
- no Docker socket, devices, published ports, credentials, SSH agent, or personal directories;
- `network=none` during validation;
- source materialized from an exact-tree Git object pack, not the host checkout.

When npm or Gradle dependencies are needed, a trusted preparation phase uses an exact-hostname HTTPS allowlist. Validation receives a disposable cache and remains offline.

Cleanup requires exact `type + name + owner + run + kind` agreement. Ambiguous resources are retained and turn the run into a cleanup failure rather than being broadly deleted.

Read [THREAT_MODEL.md](THREAT_MODEL.md) and [docs/security.md](docs/security.md).

## What automatic detection supports

### npm

With `package.json` and `package-lock.json`, setup detects only scripts that actually exist among:

- `lint`
- `typecheck`, `type-check`, or `check-types`
- `test` (placeholder “no test specified” scripts are ignored)
- `build`

The script body is never copied into the CI configuration. AgentLocalCI emits argv such as `npm run lint`, and npm resolves the committed script while validation is offline.

### Gradle

Setup detects committed wrappers at:

- `gradlew`
- `android/gradlew`
- `apps/android/gradlew`

It creates `fast` and `standard` profiles using the wrapper. Hardware devices, emulators, signing, and deployment remain declared gaps.

### Other projects

AgentLocalCI creates a clearly marked diagnostic profile rather than falsely claiming acceptance. Edit the generated argv-based stages and commit them.

## Reports

Each run writes:

```text
runtime/runs/<RUN_ID>/
  report.json
  summary.md
  report.html
  logs/
```

The HTML report has no external script, font, image, or network request. JSON remains the machine-readable source of truth. Logs are redacted and bounded before persistence.

## macOS status

The controller uses native PowerShell on macOS and a native `linux/arm64` trusted image on Apple Silicon; Intel Macs use `linux/amd64`. Tool downloads are checksum-pinned for both architectures.

macOS support is **beta**, not yet claimed as field-certified on every physical Mac/Docker Desktop combination. Release evidence includes parser/unit tests, Unix installer tests inside the trusted Linux environment, and native ARM64 image builds. See [macOS support](docs/macos.md).

## Advanced exact-target mode

```powershell
$sha = (git rev-parse HEAD).Trim()
agentlocalci validate-config --sha $sha
agentlocalci run --sha $sha --profile standard
```

Branch names, tags, `HEAD`, abbreviated SHAs, uppercase SHAs, missing objects, and non-commit objects are rejected by the advanced `run` command.

## Development and release gates

```powershell
pwsh -NoProfile -File ./tests/run-unit.ps1
pwsh -NoProfile -File ./tests/run-docker-integration.ps1
pwsh -NoProfile -File ./tests/run-adversarial-e2e.ps1
pwsh -NoProfile -File ./tests/run-installer-integration.ps1
pwsh -NoProfile -File ./scripts/run-quality.ps1
pwsh -NoProfile -File ./scripts/secret-scan.ps1 -IncludeHistory
```

This repository intentionally contains no GitHub Actions workflow and never turns a contributor pull request into a command on a maintainer’s machine.

## Documentation

- [Installing and upgrading](docs/installing.md)
- [macOS support](docs/macos.md)
- [Why local CI?](docs/why-local-ci.md)
- [Architecture](docs/architecture.md)
- [Configuration](docs/configuration.md)
- [Reports](docs/reporting.md)
- [Limitations](docs/limitations.md)
- [Security policy](SECURITY.md)

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
