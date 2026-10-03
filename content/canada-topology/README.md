# Canada Topology

[![GitHub Pages Deploy](https://github.com/f5-sales-demo/canada-topology/actions/workflows/github-pages-deploy.yml/badge.svg)](https://github.com/f5-sales-demo/canada-topology/actions/workflows/github-pages-deploy.yml)

Canadian regional F5 Distributed Cloud demo: three Azure Customer Edges, two FRR
relays, Azure Route Server, an internal load balancer and a Canadian origin.
Toronto and Montreal Regional Edges advertise the retained reserved public IP.

The deployment owns the `canada-topology` application namespace and its registration token.
CE sites remain in `system`; the reserved public-IP allocation remains in its
existing platform namespace. Independent local Terraform state lives in a protected directory outside the
Ubuntu checkout. Deployment uses the existing Azure CLI login and exclusive
operator and local-state locks.
Subscription Marketplace acceptance is a shared prerequisite.

Extracted with source attribution from
[f5-sales-demo/multi-cloud-networking](https://github.com/f5-sales-demo/multi-cloud-networking).
Terraform is pinned to 1.16.3 and xcsh to 12.4.0 with API 9.0.2, contract 7.0.0
and telemetry v2. Credentials, hostname, state configuration and workstation
egress addresses belong in private operator inputs.

## Documentation

Deployment, verification, failover, teardown and Terraform sources are published
at [https://f5-sales-demo.github.io/canada-topology/](https://f5-sales-demo.github.io/canada-topology/).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the governed contribution workflow.

## License

See [LICENSE](LICENSE).
