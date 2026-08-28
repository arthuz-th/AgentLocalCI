# Changelog

All notable changes are documented here. The project follows Semantic Versioning after 1.0; pre-1.0 releases may change configuration with explicit migration notes.

## [0.2.0-beta.1] - 2026-08-28

### Added

- Beginner `quickstart` command with machine diagnostics, npm/Gradle detection, narrow optional config commit, exact-HEAD run, and report opening.
- `check` command that resolves full HEAD automatically and refuses dirty source.
- Balanced `why` guidance explaining when local CI helps and when hosted CI remains necessary.
- Self-contained HTML reports and `report --open`.
- Opt-in ownership-guarded pre-push hook management.
- macOS and Linux beta controller/installer support.
- Native trusted images for Linux amd64 and arm64 with architecture-specific checksums.
- Host and image platform/architecture evidence in reports.
- Doctor remediation guidance.

### Changed

- Automatic npm configuration uses only detected scripts and does not copy script bodies.
- Gradle detection supports root, `android`, and `apps/android` wrappers.
- Installer uses platform-specific user-local roots and owner-marked shell-profile PATH blocks.

### Security

- Existing foreign pre-push hooks are never overwritten or removed.
- Automatic config commit refuses every change except the generated pipeline.
- Dirty working trees cannot pass the beginner `check` path.
- Cross-platform Git isolation uses the host's real null device and case semantics.

## [0.2.0-alpha.1] - 2026-08-28

- Initial Windows-first exact-commit controller, offline validation, controlled dependency preparation, redacted reports, ownership-aware cleanup, and public security model.
