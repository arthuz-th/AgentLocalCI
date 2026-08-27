# Governance

AgentLocalCI uses maintainer-led governance during the pre-1.0 period.

Maintainers set the security boundary, approve releases, review contributions, and may reject a feature that increases host exposure, remote attack surface, credential handling, cleanup ambiguity, or unsupported marketing claims.

## Decision order

1. Prevent host, credential, and unrelated-resource exposure.
2. Preserve exact-commit provenance and fail-closed results.
3. Keep behavior testable and documented.
4. Maintain compatibility within the published support matrix.
5. Improve usability and performance.

## Becoming a maintainer

Sustained contributors may be invited after demonstrating sound security judgment, review quality, respectful participation, and reliable release work. Access is least-privilege and may be removed when no longer needed.

## Releases

A maintainer must verify the exact release commit locally, audit the full public history for secrets and private provenance, generate checksums and an SBOM, and publish known limitations. No single test result authorizes deployment to another project.
