# Dependency preparation and proxy

Validation containers never have network access. A stage that declares `npm` or `gradle` first triggers a trusted preparation phase.

## Topology

- A per-run internal bridge network has an isolated IPv4 gateway and IPv6 disabled.
- Fetch containers attach only to that internal network.
- A trusted proxy attaches to the internal network and Docker's default bridge.
- The proxy accepts exact allowlisted hostnames, HTTPS CONNECT, and port 443 only.
- The proxy resolves IPv4 A records, rejects private/special ranges, and connects to the resolved address.
- A probe verifies that fetch containers cannot directly reach the allowlisted public host, common public resolver IPs, Docker host aliases, metadata addresses, private gateways, or common Docker daemon ports.

## npm

Preparation runs `npm ci --ignore-scripts --no-audit --no-fund`. Validation copies the cache, runs a second `npm ci --ignore-scripts --offline`, then executes the stage with offline npm environment variables.

## Gradle

Preparation uses the committed wrapper, a trusted init script, a bounded worker count, and a disposable Gradle user home. Validation copies that cache read-only and enforces `--offline`, `--no-daemon`, `--console=plain`, and the machine-policy worker limit.

## Limitations

Redirects and CDN hosts must be listed exactly in both project configuration and machine policy. Wildcards, IP literals, HTTP, non-443 ports, private registries, credentials, and IPv6 destinations are unsupported in 0.2.
