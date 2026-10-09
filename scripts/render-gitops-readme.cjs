#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const metadata = JSON.parse(fs.readFileSync(path.join(root, '.github/config/docs-sites.json')));
const site = metadata.find((entry) => entry.url === 'https://f5-sales-demo.github.io/gitops/llms-full.txt');
if (!site || site.label !== 'GitOps' || !site.readme_english_only) throw new Error('GitOps metadata is incomplete');
const text = `# ${site.label}

${site.description}.

${site.readme_content}

## Documentation

[Read the English guides](https://f5-sales-demo.github.io/gitops/en/).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution process.

## License

See [LICENSE](LICENSE).
`;
const output = path.join(root, 'content/gitops/README.md');
if (process.argv.includes('--check')) {
  if (fs.readFileSync(output, 'utf8') !== text) throw new Error('GitOps README projection is stale');
} else {
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(output, text);
}
