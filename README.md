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

The dated policy in
[backlog-consolidation-2026-08-30.json](.github/config/backlog-consolidation-2026-08-30.json)
records the accepted issue, transfer, relationship, pull request, and branch state from
[#1902](https://github.com/f5-sales-demo/docs-control/issues/1902). Verify current GitHub state
without making changes:

```bash
python3 scripts/verify_backlog_consolidation.py
```

The command uses the authenticated `gh` CLI and fails closed on API errors, malformed data, or
policy drift. To capture live input for later diagnosis, add `--write-snapshot <path>`. To replay
that input without network access, use `--snapshot <path>`. Update the versioned policy deliberately
when accepted backlog state changes; do not weaken checks to accommodate unexplained drift.

## License

See [LICENSE](LICENSE).
