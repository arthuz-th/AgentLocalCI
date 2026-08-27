# GitHub Actions billing and AgentLocalCI

AgentLocalCI runs as a local CLI and does not submit jobs to GitHub Actions. Therefore, an AgentLocalCI run itself does not consume GitHub Actions hosted-runner minutes or GitHub Actions cloud execution charges.

That statement does **not** mean local CI is cost-free. The user supplies the computer, electricity, storage, Docker image downloads, dependency bandwidth, maintenance, and execution time.

As of August 2026, GitHub documents:

- GitHub Free: 2,000 included Actions minutes per month for private repositories.
- GitHub Pro: 3,000 included Actions minutes per month for private repositories.
- Usage beyond the included allowance can be billed.
- Standard GitHub-hosted runners for public repositories are free and unlimited.
- Self-hosted runner usage is described separately by GitHub and may change; AgentLocalCI is not a GitHub Actions self-hosted runner.

Official references:

- https://docs.github.com/en/billing/concepts/product-billing/github-actions
- https://docs.github.com/en/actions/concepts/billing-and-usage
- https://docs.github.com/en/actions/reference/runners/github-hosted-runners

Recommended project wording:

> Run exact-commit CI on your own Windows and Docker Desktop machine. Routine AgentLocalCI runs happen outside GitHub Actions, so they do not consume GitHub Actions minutes. Local hardware and operating costs still apply. Public repositories can already use GitHub's standard hosted runners free and unlimited.

Avoid claims such as "CI is free," "replaces all GitHub Actions," or "public repositories need this to avoid minutes."
