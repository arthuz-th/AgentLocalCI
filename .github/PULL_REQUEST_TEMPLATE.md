## Problem and scope

## Security-boundary impact

- [ ] No host bind mount, Docker socket, privileged mode, device, published port, credential forwarding, implicit fetch, or remote trigger was added.
- [ ] Exact-SHA, provenance, runtime inspection, and cleanup behavior remain fail closed.
- [ ] New cleanup behavior has a negative test proving unrelated resources survive.

## Tests and exact evidence

## Configuration/schema/documentation changes

## Compatibility, limitations, and rollback

## Public-source audit

- [ ] `tests/run-unit.ps1` passed.
- [ ] `tests/run-docker-integration.ps1` passed when Docker behavior changed.
- [ ] `scripts/run-quality.ps1` passed.
- [ ] `scripts/secret-scan.ps1 -IncludeHistory` passed.
- [ ] Commits are signed off under the DCO.
