# Release process

1. Freeze the candidate source tree.
2. Run unit tests, Docker fault-injection tests, symbolic-link adversarial tests, and installer lifecycle tests.
3. Commit all source, documentation, schemas, and tests.
4. Run AgentLocalCI against the exact candidate commit using the acceptance profile.
5. Confirm cleanup passed and no owner-labelled containers, networks, or volumes remain.
6. Run the full source and Git-history secret scan.
7. Generate an SPDX JSON SBOM and SHA-256 checksums.
8. Review the diff and complete public provenance scan for private names, paths, hosts, identifiers, logs, and repository history.
9. Tag the exact verified commit with a signed or otherwise verifiable tag when available.
10. Publish release notes with supported platforms, known gaps, exact commit, controller identity, trusted image digest, test evidence, SBOM, and checksums.

A release must not be published when cleanup, provenance, secret scanning, or exact-commit self-validation is incomplete.
