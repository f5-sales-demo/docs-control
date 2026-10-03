# Customer Edge Demonstrations

[![GitHub Pages Deploy](https://github.com/f5-sales-demo/canada-topology/actions/workflows/github-pages-deploy.yml/badge.svg)](https://github.com/f5-sales-demo/canada-topology/actions/workflows/github-pages-deploy.yml)

The repositories demonstrate two distinct capabilities:

| Demonstration | Purpose |
| --- | --- |
| [Multi-Cloud Networking](https://f5-sales-demo.github.io/multi-cloud-networking/) | Advanced Azure/AWS/KVM CE deployment: interface binding, registration, BGP/ECMP, TGW Connect, HA, upgrades and lifecycle automation |
| [Canada Topology](https://f5-sales-demo.github.io/canada-topology/) | Canadian hosting and origin isolation, Toronto/Montreal advertisement, tenant-managed `.ca` DNS, GeoIP access control and regional failure/recovery |

MCN and Canada own separate infrastructure and Terraform states.

## Canada Topology

Canadian hosting and regional access control demo: three Azure Customer Edges, two FRR
relays, Azure Route Server, an internal load balancer and a Canadian origin.
`canada.f5-sales-demo.ca` uses tenant-managed `.ca` DNS and the retained reserved
public IP exclusively on Toronto and Montreal Regional Edges. An explicitly
selected GeoIP service policy allows only actual sources classified by XC as
Canada, with default denial, no exceptions and no trust in forwarding headers.
Unknown classifications are denied. Public IPv6 remains unpublished.

CE BGP, primary-IP and ILB diagnostics use `internal.canada.f5-sales-demo.ca`
without public advertisement or managed public DNS. Canadian CE origin discovery
and the origin infrastructure-source ACL are separate from client geofencing.
Regional failure and recovery verification covers public and internal paths.

The deployment owns the `canada-topology` application namespace and its registration token.
CE sites remain in `system`; the reserved public-IP allocation remains in its
existing platform namespace. Independent local Terraform state lives in a protected directory outside the
Ubuntu checkout. Deployment uses the existing Azure CLI login and exclusive
operator and local-state locks.
Subscription Marketplace acceptance is a shared prerequisite.

Extracted with source attribution from
[f5-sales-demo/multi-cloud-networking](https://github.com/f5-sales-demo/multi-cloud-networking).
Terraform is pinned to 1.16.3 and xcsh to 13.0.3 with API 10.0.0, contract 7.0.0
and telemetry v2. Credentials, state configuration and workstation
egress addresses belong in private operator inputs.

## Documentation

The sales presenter and operator guide covers use case, architecture, deployment,
presentation, verification, failover, troubleshooting, teardown and Terraform reference.
These pages are published
at [https://f5-sales-demo.github.io/canada-topology/](https://f5-sales-demo.github.io/canada-topology/).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the governed contribution workflow.

## License

See [LICENSE](LICENSE).
