# Customer Edge use cases

[![GitHub Pages Deploy](https://github.com/f5-sales-demo/canada/actions/workflows/github-pages-deploy.yml/badge.svg)](https://github.com/f5-sales-demo/canada/actions/workflows/github-pages-deploy.yml)

These repositories document two distinct F5 Distributed Cloud patterns:

| Use case | Purpose |
| --- | --- |
| [Multi-Cloud Networking](https://f5-sales-demo.github.io/multi-cloud-networking/) | Advanced Azure/AWS/KVM CE interface binding, registration, BGP/ECMP, TGW Connect, HA, upgrades and lifecycle automation |
| [Canada Topology](https://f5-sales-demo.github.io/canada/en/) | Canadian traffic path through DNS, Regional Edge advertisement, actual-source authorization and Canadian CE origin discovery |

MCN and Canada own separate infrastructure and Terraform states.

## Canada Topology

The [Canadian traffic path](https://f5-sales-demo.github.io/canada/en/use-case/) follows a request from tenant-managed DNS to a reserved public allocation, Toronto/Montreal Regional Edges, an explicitly selected country policy, and an origin discovered through Canadian Customer Edges. Annotated API JSON excerpts explain each control for existing F5 Distributed Cloud users.

The demonstrated policy allows `COUNTRY_CA` and denies other or unknown classifications, with forwarding-header trust disabled. Canadian origin placement, Canadian public advertisement and source-country authorization are independent decisions. Origin infrastructure ingress uses a separate ACL.

Three Azure Customer Edges, two FRR relays, Azure Route Server, an internal load balancer and an origin stage the demonstration in Canada Central. Its node recovery exercise does
not establish cross-region redundancy, comprehensive Canadian data residency or legal compliance. Internal diagnostic listeners are separate from public advertisement. Public IPv6
remains unpublished pending equivalent enforcement verification.

The documentation follows [Design](https://f5-sales-demo.github.io/canada/en/design/), [Deploy](https://f5-sales-demo.github.io/canada/en/deploy/),
[Verify](https://f5-sales-demo.github.io/canada/en/verify/) and [Operate](https://f5-sales-demo.github.io/canada/en/operate/).
The [configuration map](https://f5-sales-demo.github.io/canada/en/architecture/) and [Terraform source](https://f5-sales-demo.github.io/canada/en/terraform/) retain their existing URLs.

Terraform is supporting implementation reference. Its source is extracted with attribution from
[f5-sales-demo/multi-cloud-networking](https://github.com/f5-sales-demo/multi-cloud-networking). The Canada application namespace and registration token are separately owned; CE
sites remain in `system`, and the reserved allocation remains platform-owned. Independent local Terraform state and backups live outside the Ubuntu checkout in protected storage. Deployment uses the existing Azure CLI login and exclusive deployment/state locks. Credentials belong in private inputs. Shared Marketplace acceptance is a
subscription prerequisite.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the governed contribution workflow.

## License

See [LICENSE](LICENSE).
