# Prompt Charity

Useful prompts, freely shared. Review a plan, then approve the complete workflow.

Prompt Charity is an English library of use cases and copyable prompts
that describe desired outcomes, essential constraints and observable success criteria.
Use your chosen AI harness's native planning and approval controls and continue approved work through verification. The prompt uses instructions shared across AI harnesses
and operating systems; your agent discovers the required tools and appropriate
native commands.

[Browse the prompt library](https://f5-sales-demo.github.io/prompt-charity/en/).

## Start here

1. Choose a use case and copy its prompt.
2. Replace the bracketed inputs with your context and constraints.
3. Submit the prompt using your harness's native planning and approval controls.
4. Review infrastructure scope, cost, assumptions, verification and acceptance criteria.
5. Approve the scoped infrastructure plan when ready and continue through implementation,
   verification and authorized cleanup. Preserve approved scope, identities, ownership
   and original deadlines across supported handoffs or resumes.

Let the harness manage ordinary planning artifacts and execution choices within workspace
conventions. Use read-only discovery before dependent operations and review infrastructure
changes before applying their saved Terraform plans.

## First use case

[Deploy a Customer Edge in GCP](https://f5-sales-demo.github.io/prompt-charity/en/use-cases/gcp-customer-edge/)
provides a complete copyable prompt, plain-text download and step-by-step Terraform
fallback for one dual-interface Secure Mesh Site v2. Obtain an invitation to the
private `F5Networks/terraform-provider-f5xc-preview` repository and authenticate
release access before starting; missing private-repository access can appear as a 404.

Recommend at least 120 GB of `pd-balanced` boot storage per CE for headroom during code upgrades.
Increase this when current service or image requirements demand it.

Completion requires stable `ONLINE`, verified SLO/SLI interface roles, disk evidence and
a zero-change post-registration Terraform plan followed by another `ONLINE` observation. Qualification evidence is candidate-specific;
see the use-case page for its current status. Keep credentials, sensitive state,
VM metadata and raw transcripts private. Teardown must prove owned resources and
the XC site are absent.

## Why the name?

We use **Prompt Charity** to mean sharing useful prompts and interpreting a user's
intent constructively. The philosophical [principle of charity](https://en.wikipedia.org/wiki/Principle_of_charity)
asks readers to consider the strongest reasonable interpretation of a statement.
Applied here, that means clarifying ambiguity and recording assumptions while
preserving the user's goals and constraints. This is the project's interpretation
of the name; the exact phrase is not claimed as an established technical term.

## English source

Write and maintain English content here. Translation belongs to a separate process.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the governed contribution process and
[DEVELOPING.md](DEVELOPING.md) for the prompt format and validation commands.

## License

See [LICENSE](LICENSE).
