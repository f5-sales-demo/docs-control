import { execFileSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';

const mode = process.argv[2];
if (!['root', 'fleet'].includes(mode)) throw Error('usage: node scripts/dispatch-shared-shell.mjs root|fleet');
const sites = JSON.parse(await readFile(new URL('../.github/config/docs-sites.json', import.meta.url)));
const repositories =
  mode === 'root'
    ? ['f5-sales-demo.github.io']
    : sites
        .filter((site) => site.rebuild_dispatch !== false)
        .map((site) => {
          const slug = new URL(site.url).pathname.split('/').filter(Boolean)[0];
          return slug.startsWith('llms') ? 'f5-sales-demo.github.io' : slug;
        });
for (const repository of new Set(repositories)) {
  execFileSync(
    'gh',
    ['workflow', 'run', 'github-pages-deploy.yml', '--repo', `f5-sales-demo/${repository}`, '--ref', 'main'],
    { stdio: 'inherit' },
  );
}
