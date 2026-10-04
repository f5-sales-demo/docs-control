# Customer Edge use cases

[![GitHub Pages Deploy](https://github.com/f5-sales-demo/canada/actions/workflows/github-pages-deploy.yml/badge.svg)](https://github.com/f5-sales-demo/canada/actions/workflows/github-pages-deploy.yml)

These repositories document two distinct F5 Distributed Cloud patterns:

| Use case | Purpose |
| --- | --- |
| [Multi-Cloud Networking](https://f5-sales-demo.github.io/multi-cloud-networking/) | Advanced Azure/AWS/KVM CE interface binding, registration, BGP/ECMP, TGW Connect, HA, upgrades and lifecycle automation |
| [Canada Topology](https://f5-sales-demo.github.io/canada/en/use-case/) | Canadian hosting and regional access control through DNS, regional advertisement, actual-source authorization and Canadian CE origin discovery |

MCN and Canada own separate infrastructure and Terraform states.

## Canada Topology

The [primary article](https://f5-sales-demo.github.io/canada/en/use-case/) follows a request from tenant-managed DNS to a reserved public allocation, Toronto/Montreal Regional Edges, an explicitly selected country policy, and an origin discovered through Canadian Customer Edges. Annotated API JSON excerpts explain each control for existing F5 Distributed Cloud users.

The demonstrated policy allows `COUNTRY_CA` and denies other or unknown classifications, with forwarding-header trust disabled. Canadian origin placement, Canadian public advertisement and source-country authorization are independent decisions. Origin infrastructure ingress uses a separate ACL.

Three Azure Customer Edges, two FRR relays, Azure Route Server, an internal load balancer and an origin stage the demonstration in Canada Central. Its node recovery exercise does
not establish cross-region redundancy, comprehensive Canadian data residency or legal compliance. Internal diagnostic listeners are separate from public advertisement. Public IPv6
remains unpublished pending equivalent enforcement verification.

[Understand the tests](https://f5-sales-demo.github.io/canada/en/verification/) or consult the [configuration mapping](https://f5-sales-demo.github.io/canada/en/architecture/) and [Terraform sources](https://f5-sales-demo.github.io/canada/en/terraform/). Staging, proof sequence, recovery, symptoms and ownership remain informational references at their existing URLs.

Terraform is supporting implementation reference. Its source is extracted with attribution from
[f5-sales-demo/multi-cloud-networking](https://github.com/f5-sales-demo/multi-cloud-networking). The Canada application namespace and registration token are separately owned; CE
sites remain in `system`, and the reserved allocation remains platform-owned. Deployment state and credentials belong in protected local inputs. Shared Marketplace acceptance is a
subscription prerequisite.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the governed contribution workflow.

## License

See [LICENSE](LICENSE).
