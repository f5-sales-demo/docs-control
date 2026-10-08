import { execFileSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';

const mode = process.argv[2];
if (!['root', 'fleet'].includes(mode)) throw Error('usage: node scripts/dispatch-shared-shell.mjs root|fleet');
const sites = JSON.parse(await readFile(new URL('../.github/config/docs-sites.json', import.meta.url)));
const repositories =
  mode === 'root'
    ? ['f5-sales-demo.github.io']
    : sites
        .filter((site) => site.rebuild_dispatch !== false || site.shared_shell?.workflow)
        .map((site) => {
          const slug = new URL(site.url).pathname.split('/').filter(Boolean)[0];
          return slug.startsWith('llms') ? 'f5-sales-demo.github.io' : slug;
        });
for (const repository of new Set(repositories)) {
  const site = sites.find((site) => new URL(site.url).pathname.startsWith(`/${repository}/`));
  const workflow = site?.shared_shell?.workflow || 'github-pages-deploy.yml';
  execFileSync('gh', ['workflow', 'run', workflow, '--repo', `f5-sales-demo/${repository}`, '--ref', 'main'], {
    stdio: 'inherit',
  });
}
