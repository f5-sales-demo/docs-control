# f5-sales-demo

[![Reconcile Fleet Content](https://github.com/f5-sales-demo/docs-control/actions/workflows/reconcile-fleet-content.yml/badge.svg)](https://github.com/f5-sales-demo/docs-control/actions/workflows/reconcile-fleet-content.yml)
[![Reconcile Fleet Settings](https://github.com/f5-sales-demo/docs-control/actions/workflows/reconcile-fleet-settings.yml/badge.svg)](https://github.com/f5-sales-demo/docs-control/actions/workflows/reconcile-fleet-settings.yml)
[![Build Managed Files Manifest](https://github.com/f5-sales-demo/docs-control/actions/workflows/build-managed-files-manifest.yml/badge.svg)](https://github.com/f5-sales-demo/docs-control/actions/workflows/build-managed-files-manifest.yml)
[![GitHub Pages Deploy](https://github.com/f5-sales-demo/docs-control/actions/workflows/docs-site-deploy.yml/badge.svg)](https://github.com/f5-sales-demo/docs-control/actions/workflows/docs-site-deploy.yml)
[![Super-Linter](https://github.com/f5-sales-demo/docs-control/actions/workflows/super-linter.yml/badge.svg)](https://github.com/f5-sales-demo/docs-control/actions/workflows/super-linter.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for workflow rules,
branch naming, and CI requirements.

## Operations

See [Self-hosted runner operations](docs/self-hosted-runners.md) for the runner security model,
image release process, workstation provisioning, pilot procedure, and incident response.

## Backlog consolidation verification

The schema-v2 inventory in
[backlog-inventory-2026-09-01.json](.github/config/backlog-inventory-2026-09-01.json)
records every open issue and pull request across the exact governed catalog for
[#1953](https://github.com/f5-sales-demo/docs-control/issues/1953). It includes empty repositories,
timestamps, labels, native workstream relationships, pull-request heads, changed paths, checks,
dependencies, evidence, and dispositions.

```bash
python3 scripts/verify_backlog_consolidation.py verify \
  --inventory .github/config/backlog-inventory-2026-09-01.json
python3 scripts/verify_backlog_consolidation.py verify-live \
  --inventory .github/config/backlog-inventory-2026-09-01.json
```

`verify` is offline. `verify-live` uses the authenticated `gh` CLI and fails closed on pagination
errors, catalog or item drift, concurrent timestamp/head changes, incomplete taxonomy, malformed
responses, or missing relationships. Refresh the dated record deliberately with `collect --output
<path>` only after accepted lifecycle changes. The schema-v1 audit from
[#1902](https://github.com/f5-sales-demo/docs-control/issues/1902) remains available through the
legacy no-subcommand interface.

## License

See [LICENSE](LICENSE).
