# Contributing

AgentLocalCI accepts focused issues and pull requests that preserve the fail-closed boundary.

## Before proposing code

1. Read [THREAT_MODEL.md](THREAT_MODEL.md), [docs/security.md](docs/security.md), and [docs/limitations.md](docs/limitations.md).
2. Search existing issues.
3. For a security weakness, use the private process in [SECURITY.md](SECURITY.md), not a public issue.
4. Keep generic core changes independent of any private application, customer, company, path, credential, or deployment system.

## Development environment

- Windows
- PowerShell 7.4+
- Git for Windows
- Docker Desktop using Linux containers

Run:

```powershell
pwsh -NoProfile -File .\tests\run-unit.ps1
pwsh -NoProfile -File .\tests\run-docker-integration.ps1
pwsh -NoProfile -File .\scripts\run-quality.ps1
```

Then commit the final tree and run AgentLocalCI against that exact SHA.

## Change rules

- Do not add host bind mounts, Docker socket access, privileged mode, device mappings, published ports, credential forwarding, implicit fetches, or remote-triggered execution.
- Do not weaken exact-SHA validation or cleanup ownership checks.
- Do not add a `shell:` pipeline field or command-string execution flags.
- New dependency hosts must remain machine-policy controlled.
- New formats require schemas, malformed-input tests, boundary tests, documentation, and migration notes.
- New cleanup behavior requires a negative test proving unrelated resources survive.
- Reports and errors must be bounded, sanitized, and free of absolute personal paths.
- Keep generated, cache, runtime, and private fixture data out of Git.

## Commits and DCO

Every contribution must certify the [Developer Certificate of Origin](DCO.md). Sign off commits with:

```text
Signed-off-by: Your Name <you@example.com>
```

Use `git commit -s` to add the line.

## Pull requests

A pull request should contain:

- problem and security impact;
- design and alternatives;
- exact tests run and results;
- documentation and schema changes;
- compatibility and rollback notes;
- confirmation that `scripts/secret-scan.ps1` passed across the proposed history.

Maintainers may request smaller commits or a dedicated security review before merge.
