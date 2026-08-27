# Reports and evidence

Each run stores local state under the selected AgentLocalCI home:

```text
runtime/runs/<RUN_ID>/
  state.json
  report.json
  summary.md
  logs/
```

Reports contain the exact commit and tree, pack digest and object count, profile scope and declared gaps, controller and image identity, pipeline/policy/repository-path fingerprints, stage timing and bounded log filenames, security-boundary assertions, cleanup proof, result, and exit code.

The raw repository path is not written; only a SHA-256 fingerprint is stored. Logs are redacted before persistence. Target code writes only to a Docker evidence volume in 0.1; it cannot write the host report.

## Interpret results narrowly

- `Passed`: every configured stage passed and cleanup was proven complete for an acceptance profile.
- `DiagnosticOnly`: configured stages completed for a non-acceptance profile; exit code 6 prevents accidental promotion.
- `Failed`: a stage failed.
- `SafetyBlocked`: machine policy or runtime inspection refused the boundary.
- `CleanupFailed`: the result is not an acceptance pass even when stages succeeded.

A report proves only the declared profile on the exact commit. It does not authorize merge, release, deployment, payment, production, or tests listed as gaps.
