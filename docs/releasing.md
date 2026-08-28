# Release process

1. Freeze the candidate source tree.
2. Run unit, quality, full-history secret, Docker fault-injection, beginner quickstart, symbolic-link adversarial, and installer lifecycle tests.
3. Run the Unix controller/installer/profile contract in a locked-down Linux environment.
4. For a macOS-capable release, build the complete native `linux/arm64` trusted image and record whether testing used a physical Mac or only an ARM64/Linux build contract.
5. Commit source, documentation, schemas, and tests; review `git diff --check` and the complete tracked-file inventory.
6. Run AgentLocalCI against the exact candidate commit using the acceptance profile.
7. Confirm report schema, HTML report, cleanup, and absence of owner-labelled containers, networks, or volumes.
8. Repeat source and full Git-history secret/private-provenance scans on the committed history.
9. Generate a source archive, SPDX JSON image SBOM, release evidence, and SHA-256 checksums.
10. Verify an anonymous public clone, install, `why`, `doctor`, and exact-commit self-run from that clone.
11. Tag the exact verified commit and publish release notes with support status, known gaps, exact commit/tree, controller identity, native image digest/architecture, test evidence, SBOM, and checksums.

A release must not be published when cleanup, provenance, source/history scanning, exact-commit self-validation, or claimed-platform evidence is incomplete. A Linux ARM64 build is evidence for the Apple Silicon container path; it is not a substitute for a physical macOS field test and must not be described as one.
