# GitHub Actions billing and AgentLocalCI

AgentLocalCI runs as a local CLI and does not submit jobs to GitHub Actions. An AgentLocalCI run itself therefore does not consume GitHub Actions hosted-runner minutes or GitHub Actions cloud execution charges.

That does **not** mean local CI is cost-free. The user supplies the computer, electricity, storage, Docker image downloads, dependency bandwidth, maintenance, and execution time. Docker Desktop licensing can also depend on the user's organization and use case.

As of August 2026, GitHub documents included Actions minutes for private repositories, including 2,000 minutes for GitHub Free and 3,000 minutes for GitHub Pro. Usage beyond the included allowance can be billable. GitHub also documents standard hosted runners for public repositories separately as free and unlimited.

Official references:

- https://docs.github.com/en/billing/concepts/product-billing/github-actions
- https://docs.github.com/en/actions/concepts/billing-and-usage
- https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- https://docs.docker.com/subscription/desktop-license/

Recommended wording:

> Run exact-commit CI on your own Windows, macOS, or Linux machine. Routine AgentLocalCI runs happen outside GitHub Actions, so they do not consume GitHub Actions minutes. Local hardware, operating, and applicable Docker licensing costs still apply.

Avoid claims such as “CI is free,” “replaces all GitHub Actions,” or “public repositories need this to avoid minutes.” Hosted CI remains useful for shared status, matrices, independent verification, releases, and deployment.
