# Client-Side Defense

🌐 English |
[日本語](https://f5-sales-demo.github.io/client-side-defense/ja/) |
[한국어](https://f5-sales-demo.github.io/client-side-defense/ko/) |
[简体中文](https://f5-sales-demo.github.io/client-side-defense/zh-cn/) |
[繁體中文](https://f5-sales-demo.github.io/client-side-defense/zh-tw/) |
[Español](https://f5-sales-demo.github.io/client-side-defense/es/) |
[Português](https://f5-sales-demo.github.io/client-side-defense/pt-br/) |
[Français](https://f5-sales-demo.github.io/client-side-defense/fr/) |
[Deutsch](https://f5-sales-demo.github.io/client-side-defense/de/) |
[Italiano](https://f5-sales-demo.github.io/client-side-defense/it/) |
[العربية](https://f5-sales-demo.github.io/client-side-defense/ar/) |
[हिन्दी](https://f5-sales-demo.github.io/client-side-defense/hi/) |
[ไทย](https://f5-sales-demo.github.io/client-side-defense/th/)

[![GitHub Pages Deploy](https://github.com/f5-sales-demo/client-side-defense/actions/workflows/github-pages-deploy.yml/badge.svg)](https://github.com/f5-sales-demo/client-side-defense/actions/workflows/github-pages-deploy.yml)
[![Repository Settings](https://github.com/f5-sales-demo/docs-control/actions/workflows/reconcile-fleet-settings.yml/badge.svg)](https://github.com/f5-sales-demo/docs-control/actions/workflows/reconcile-fleet-settings.yml)
[![License](https://img.shields.io/github/license/f5-sales-demo/client-side-defense)](LICENSE)

F5 Distributed Cloud Client-Side Defense reference deployment and demonstration.

## Deployment modes

The reference architecture uses namespace `client-side-defense`, domain
`client-side-defense.f5-sales-demo.com`, one HTTPS auto-certificate HTTP load balancer with
HTTP redirect, one origin pool, and CSD JavaScript insertion on all pages. The AWS origin pool
uses the deployed Application Load Balancer hostname; the Azure alternate uses a public IP.

Choose exactly one deployment owner:

- [API workflow](https://f5-sales-demo.github.io/client-side-defense/en/demo/) for direct F5 Distributed Cloud API lifecycle.
- [Terraform](https://f5-sales-demo.github.io/client-side-defense/en/terraform/) for the complete AWS origin and F5 Distributed Cloud lifecycle.

Choose one ownership mode. Never run the API create/update/delete workflow against resources present in Terraform state.

## Documentation

Full documentation is available at __[https://f5-sales-demo.github.io/client-side-defense/](https://f5-sales-demo.github.io/client-side-defense/)__.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for workflow rules,
branch naming, and CI requirements.

## License

See [LICENSE](LICENSE).
