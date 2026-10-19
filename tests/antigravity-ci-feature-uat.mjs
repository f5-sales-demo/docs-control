import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import process from 'node:process';

const root = path.resolve(process.argv[2] || '.');
const workflow = fs.readFileSync(path.join(root, '.github/workflows/antigravity-review.yml'), 'utf8');
const require = createRequire(import.meta.url);

function script(name) {
  const block = workflow.split(`      - name: ${name}\n`)[1]?.split('\n      - name: ')[0];
  assert.ok(block, `missing workflow step ${name}`);
  return block.split('          script: |\n')[1].split('\n').map((line) => line.slice(12)).join('\n');
}

assert.match(workflow, /timeout-minutes: 50/);
assert.match(workflow, /repository: f5-sales-demo\/docs-control/);
assert.match(workflow, /path: review-tools/);
assert.match(workflow, /path: review-target/);
assert.doesNotMatch(workflow, /cp scripts\/agy-review|Gemini 3.6 Flash|1.1.10/);
assert.match(workflow, /agy_review_report.py/);
assert.match(workflow, /sha512sum --check --strict/);
assert.match(workflow, /vars.ANTIGRAVITY_REVIEW_ENABLED == 'true'/);
const settings = JSON.parse(fs.readFileSync(path.join(root, '.github/config/repo-settings.json'), 'utf8'));
assert.ok(settings.managed_files.absent_files.includes('scripts/agy-review.sh'));
assert.equal(settings.managed_files.files.some(({ src }) => /antigravity-translate|i18n-translate/.test(src)), false);

// Execute the exact-head GitHub script, including rejection after head/base changes.
const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
const validate = new AsyncFunction('github', 'context', 'core', 'require', script('Validate exact pull-request head'));
const base = 'b'.repeat(40);
const head = 'a'.repeat(40);
const pull = { base: { sha: base }, head: { sha: head, repo: { full_name: 'f5-sales-demo/example' } } };
const github = {
  request: async () => ({ data: { resources: { core: { remaining: 5000, reset: 0 } } } }),
  rest: { pulls: { get: async () => ({ data: pull }) } },
};
const old = { ...process.env };
Object.assign(process.env, { BASE_SHA: base, HEAD_SHA: head, PR_NUMBER: '42', GITHUB_REPOSITORY: 'f5-sales-demo/example', GITHUB_WORKSPACE: root });
// Resolve trusted tools from the separate checkout in the real script.
const trustedRequire = (file) => require(file.replace('/review-tools/scripts/', '/scripts/'));
try {
  await validate(github, { repo: { owner: 'f5-sales-demo', repo: 'example' } }, {}, trustedRequire);
  pull.head.sha = '0'.repeat(40);
  await assert.rejects(validate(github, { repo: {} }, {}, trustedRequire), /exact review receipt/);
  pull.head.sha = head;
  pull.base.sha = '0'.repeat(40);
  await assert.rejects(validate(github, { repo: {} }, {}, trustedRequire), /exact review receipt/);
  pull.base.sha = base;
  pull.head.repo.full_name = 'outsider/fork';
  await assert.rejects(validate(github, { repo: {} }, {}, trustedRequire), /exact review receipt/);
} finally {
  process.env = old;
}

const tests = spawnSync('python3', ['-m', 'unittest', 'discover', '-s', 'tests', '-p', 'test_agy_review.py'], {
  cwd: root, stdio: 'inherit', timeout: 120000,
});
assert.equal(tests.status, 0, 'production wrapper regression tests failed');
console.log('PASS: trusted checkout, exact-head publication guards and real wrapper UAT');
