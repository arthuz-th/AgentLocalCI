# Changelog

All notable changes are documented here. The project follows Semantic Versioning after 1.0; pre-1.0 releases may change configuration with explicit migration notes.

## [Unreleased]

### Added

- Exact-commit local CI controller for Windows and Docker Desktop.
- Unprivileged, read-only, offline validation containers.
- Exact-tree Git object-pack provenance.
- Machine-policy-controlled npm and Gradle dependency preparation.
- Sanitized JSON and Markdown reports.
- Fail-closed ownership-aware cleanup and dead-controller recovery.
- Unit, Docker fault-injection, installer lifecycle, dependency egress/offline, and symbolic-link adversarial tests.

### Security

- No host bind mounts, Docker socket, devices, ports, credentials, or implicit Git fetch.
- Command-string interpreter flags and secret-like configuration are rejected.
- Ambiguous cleanup resources are retained rather than deleted.
- Git submodule gitlinks and canonical-path symbolic-link escapes fail closed.
