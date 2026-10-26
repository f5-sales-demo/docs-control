# Prompt Charity

Useful prompts, freely shared. Review a plan, then approve the complete workflow.

Prompt Charity is an English library of use cases and copyable prompts
that begin in the planning mode of your chosen AI harness and guide implementation
after explicit approval. The prompt uses instructions shared across AI harnesses
and operating systems; your agent discovers the required tools and appropriate
native commands.

[Browse the prompt library](https://f5-sales-demo.github.io/prompt-charity/en/).

## Start here

1. Choose a use case and copy its prompt.
2. Replace the bracketed inputs with your context and constraints.
3. Enable your harness's planning mode, then submit the prompt.
4. Review the assumptions, proposed steps, verification, and acceptance criteria.
5. Explicitly approve the scoped plan when ready, then keep the same session active
   through implementation, verification and authorized cleanup.

If planning mode is unavailable, ask for a written plan with read-only investigation
and keep write tools disabled. Prompt wording does not enforce permissions.

## First use case

[Deploy a Customer Edge in GCP](https://f5-sales-demo.github.io/prompt-charity/en/use-cases/gcp-customer-edge/)
provides a complete copyable prompt, plain-text download and step-by-step Terraform
fallback for one dual-interface Secure Mesh Site v2. Obtain an invitation to the
private `F5Networks/terraform-provider-f5xc-preview` repository and authenticate
release access before starting; missing private-repository access can appear as a 404.

Completion requires `ONLINE`, verified SLO/SLI interface roles and a zero-change
post-registration Terraform plan. Qualification evidence is candidate-specific;
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
