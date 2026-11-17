import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import path from 'node:path';

const require = createRequire(import.meta.url);
const { binding, ensureManifestIssue, validateManifestPrIssue } = require(
  path.join(process.argv[2], 'scripts/manifest-linked-issue.cjs'),
);
const repository = 'f5-sales-demo/docs-control';
const source = 'a'.repeat(40);
const head = 'b'.repeat(40);
const marker = binding(repository, source, head);
const title = `Publish managed manifest @ ${source}`;
const issue = {
  number: 77,
  repository_url: `https://api.github.com/repos/${repository}`,
  state: 'open',
  title,
  body: marker,
  user: { id: 101 },
};
function mock({ inventory = [], saved = issue, fresh = saved, actor = { id: 101 }, metadata = {}, error = null } = {}) {
  const writes = [];
  const reads = [];
  const api = {
    request: async (route, options = {}) => {
      if (error) throw new Error(error);
      if (options.method === 'POST') {
        writes.push({ route, body: options.body });
        return { ...saved, title: options.body.title, body: options.body.body };
      }
      reads.push(route);
      if (route === `repos/${repository}`)
        return { full_name: repository, private: false, archived: false, ...metadata };
      if (route === 'user') return actor;
      if (route.includes('/issues?')) return inventory;
      if (route === `repos/${repository}/issues/77`)
        return writes.length ? { ...fresh, body: fresh === saved ? writes[0].body.body : fresh.body } : fresh;
      if (route.endsWith('/pulls/42'))
        return {
          state: 'open',
          head: { sha: head, ref: `sync/manifest-${source}`, repo: { full_name: repository } },
          base: { ref: 'main', repo: { full_name: repository } },
          body: 'Closes #77',
          user: { id: 101 },
        };
      throw new Error(`unexpected route ${route}`);
    },
  };
  return { api, writes, reads };
}
{
  const m = mock();
  const result = await ensureManifestIssue({ ...m, repository, source, head });
  assert.equal(m.writes.length, 1);
  assert.equal(result.number, 77);
  assert.match(result.pullRequestBody, /^Closes #77$/m);
  assert.ok(m.writes[0].body.body.includes('Acceptance criteria'));
  assert.ok(m.writes[0].body.body.includes(marker));
}
{
  const m = mock({ inventory: [issue] });
  assert.equal((await ensureManifestIssue({ ...m, repository, source, head })).number, 77);
  assert.equal(m.writes.length, 0);
}
for (const inventory of [
  [issue, issue],
  [{ ...issue, state: 'closed' }],
  [{ ...issue, user: { id: 202 } }],
  [{ ...issue, body: 'foreign binding' }],
  [{ ...issue, pull_request: {} }],
  [{ ...issue, body: marker.replace(head, 'c'.repeat(40)) }],
]) {
  const m = mock({ inventory });
  await assert.rejects(ensureManifestIssue({ ...m, repository, source, head }));
  assert.equal(m.writes.length, 0);
}
for (const options of [
  { actor: {} },
  { metadata: { private: true } },
  { metadata: { archived: true } },
  { error: 'service unavailable' },
]) {
  const m = mock(options);
  await assert.rejects(ensureManifestIssue({ ...m, repository, source, head }));
  assert.equal(m.writes.length, 0);
}
{
  const m = mock({ inventory: [issue], fresh: { ...issue, body: `${marker}\nchanged` } });
  await assert.rejects(ensureManifestIssue({ ...m, repository, source, head }), /changed/);
  assert.equal(m.writes.length, 0);
}
{
  const m = mock({ inventory: [issue] });
  assert.equal(
    (await validateManifestPrIssue({ ...m, repository, source, head, pullNumber: 42, issueNumber: 77 })).number,
    77,
  );
  assert.equal(m.writes.length, 0);
}
for (const invalid of [{ source: 'unresolved' }, { head: 'unresolved' }, { repository: '../foreign' }]) {
  const m = mock();
  await assert.rejects(ensureManifestIssue({ ...m, repository, source, head, ...invalid }));
  assert.equal(m.reads.length, 0);
  assert.equal(m.writes.length, 0);
}
console.log(
  'PASS: exact owned manifest issues create/reuse and reject foreign, closed, duplicate, changed and unavailable bindings',
);
