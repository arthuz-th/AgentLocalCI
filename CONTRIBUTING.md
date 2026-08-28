# Contributing

AgentLocalCI accepts focused issues and pull requests that preserve the fail-closed boundary.

## Before proposing code

1. Read [THREAT_MODEL.md](THREAT_MODEL.md), [docs/security.md](docs/security.md), and [docs/limitations.md](docs/limitations.md).
2. Search existing issues.
3. Report security weaknesses privately through [SECURITY.md](SECURITY.md).
4. Keep core changes independent of any private application, customer, company, local path, credential, or deployment system.

## Development environments

The controller targets:

- Windows (supported);
- macOS (beta, Intel and Apple Silicon);
- Linux (beta);
- PowerShell 7.4+;
- Git;
- a local Linux Docker engine on amd64 or arm64.

Run:

```powershell
pwsh -NoProfile -File ./tests/run-unit.ps1
pwsh -NoProfile -File ./tests/run-docker-integration.ps1
pwsh -NoProfile -File ./tests/run-adversarial-e2e.ps1
pwsh -NoProfile -File ./tests/run-installer-integration.ps1
pwsh -NoProfile -File ./scripts/run-quality.ps1
pwsh -NoProfile -File ./scripts/secret-scan.ps1 -IncludeHistory
```

Then commit the final tree and run AgentLocalCI against that exact SHA. Platform claims require platform-specific evidence; do not label physical macOS testing as passed when only a Linux/ARM64 contract build was performed.

## Change rules

- Do not add host bind mounts, Docker socket access, privileged mode, devices, ports, credential forwarding, implicit fetches, or remote-triggered execution.
- Do not weaken exact-SHA, clean-tree, canonical-path, installer ownership, hook ownership, or cleanup checks.
- Do not add `shell:` configuration or command-string execution flags.
- New dependency hosts remain machine-policy controlled.
- New formats require schemas, malformed-input tests, boundary tests, documentation, and migration notes.
- New cleanup behavior needs a negative test proving unrelated resources survive.
- Installer/profile/hook changes need negative tests proving foreign content survives.
- Reports and errors remain bounded, sanitized, and free of absolute personal paths.
- Keep generated, cache, runtime, and private fixture data out of Git.

## DCO and pull requests

Every contribution must certify the [Developer Certificate of Origin](DCO.md), normally with `git commit -s`.

A pull request should contain the problem/security impact, design and alternatives, exact tests/evidence, documentation/schema changes, compatibility/rollback notes, and confirmation that history secret scanning passed.
