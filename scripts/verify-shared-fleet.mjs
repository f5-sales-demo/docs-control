import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';

const root = 'https://f5-sales-demo.github.io/shared/';
async function get(url) {
  const response = await fetch(url, { cache: 'no-store', signal: AbortSignal.timeout(20000) });
  if (!response.ok) throw Error(`${url} returned ${response.status}`);
  return response;
}
const pointer = await (await get(`${root}v1/current.json`)).json();
if (pointer.contract !== 'v1') throw Error('Unsupported active shared contract');
const bytes = Buffer.from(await (await get(pointer.release.url)).arrayBuffer());
if (createHash('sha256').update(bytes).digest('hex') !== pointer.release.sha256)
  throw Error('Root release integrity mismatch');
const manifest = JSON.parse(bytes);
for (const asset of Object.values(manifest.assets)) {
  const bytes = Buffer.from(await (await get(asset.url)).arrayBuffer());
  if (bytes.length !== asset.bytes || createHash('sha256').update(bytes).digest('hex') !== asset.sha256)
    throw Error('Invalid published root asset');
}
const inventory = JSON.parse(await readFile(new URL('../.github/config/docs-sites.json', import.meta.url)));
const reports = [];
for (const site of inventory) {
  if (site.label === 'Dev Container') continue;
  const base = new URL(site.url);
  base.pathname = base.pathname.replace(/llms(?:-full)?\.txt$/, '');
  try {
    const receipt = await (await get(new URL('shared-shell-receipt.json', base))).json();
    const revision = await (await get(new URL('api/revision.json', base))).json();
    const html = await (
      await get(new URL(receipt.repository === 'f5-sales-demo/terraform-provider-xcsh' ? '' : 'en/', base))
    ).text();
    if (receipt.contract !== 'v1' || !html.includes('data-f5-shared-consumer') || !html.includes(`${root}assets/`))
      throw Error('Missing shared consumer');
    if (!revision.commit || !revision.builder_image.includes('@sha256:'))
      throw Error('Missing immutable deployment identity');
    reports.push({ site: site.label, base: base.href, receipt, revision });
  } catch (error) {
    reports.push({ site: site.label, base: base.href, error: error.message });
  }
}
await writeFile(
  process.argv[2] || 'shared-fleet-receipts.json',
  `${JSON.stringify({ active: pointer, sharedAssetBytes: Object.values(manifest.assets).reduce((sum, asset) => sum + asset.bytes, 0), sites: reports }, null, 2)}\n`,
);
const failed = reports.filter((report) => report.error);
console.log(`Verified ${reports.length - failed.length}/${reports.length} shared consumers`);
if (failed.length) process.exitCode = 1;
