import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';

if (!process.argv[2]) throw new Error('repository root is required');

const root = path.resolve(process.argv[2]);
const reviewWorkflow = path.join(root, '.github/workflows/antigravity-review.yml');
const watcherWorkflow = path.join(root, '.github/workflows/antigravity-fleet-watcher.yml');
const require = createRequire(import.meta.url);
const temporaryDirectories = [];

process.on('exit', () => {
  for (const directory of temporaryDirectories) {
    fs.rmSync(directory, { force: true, recursive: true });
  }
});

function temporaryDirectory(prefix) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  temporaryDirectories.push(directory);
  return directory;
}

function read(file) {
  return fs.readFileSync(file, 'utf8');
}

function extractStepBlock(workflowPath, stepName, key = 'run') {
  const lines = read(workflowPath).split('\n');
  const start = lines.indexOf('      - name: ' + stepName);
  if (start === -1) throw new Error('workflow step is missing');
  const end = lines.findIndex((line, index) => index > start && /^ {6}- name: /.test(line));
  const block = lines.slice(start, end === -1 ? undefined : end);
  const marker = block.findIndex((line) => line === '        ' + key + ': |' || line === '          ' + key + ': |');
  if (marker === -1) throw new Error('workflow step block is missing');
  const indentation = block[marker].search(/\S/) + 2;
  return block
    .slice(marker + 1)
    .map((line) => (line.length >= indentation ? line.slice(indentation) : ''))
    .join('\n');
}

function extractJobBlock(workflowPath, jobName) {
  const lines = read(workflowPath).split('\n');
  const start = lines.indexOf('  ' + jobName + ':');
  if (start === -1) throw new Error('workflow job is missing');
  const end = lines.findIndex((line, index) => index > start && /^ {2}[A-Za-z0-9_-]+:$/.test(line));
  return lines.slice(start, end === -1 ? undefined : end).join('\n');
}

function runShell(script, cwd, env) {
  return spawnSync('bash', ['-c', 'set -euo pipefail\n' + script], {
    cwd,
    encoding: 'utf8',
    env: { ...process.env, ...env },
  });
}

function reviewReport(base, head, workflow) {
  return {
    receipt: {
      repository: 'f5-sales-demo/example',
      base_sha: base,
      head_sha: head,
      workflow_sha: workflow,
      agy_version: '1.1.10',
      model: 'Gemini 3.6 Flash (High)',
      tool_status: 0,
    },
    reviewer: { verdict: 'pass', findings: [] },
    verifier: { verdict: 'pass', findings: [] },
  };
}

function testEnglishOnlyRetirement() {
  const settings = JSON.parse(read(path.join(root, '.github/config/repo-settings.json')));
  const retired = ['.github/workflows/antigravity-translate.yml', '.agents/skills/i18n-translate/SKILL.md'];

  for (const retiredPath of retired) {
    assert.equal(fs.existsSync(path.join(root, retiredPath)), false);
    assert.ok(settings.managed_files.absent_files.includes(retiredPath));
  }

  assert.equal(
    settings.managed_files.files.some(({ src }) => /antigravity-translate|i18n-translate/.test(src)),
    false,
  );
  assert.doesNotMatch(
    read(watcherWorkflow),
    /antigravity-translate|TRANSLATIONS_ENABLED|translationNeedsRecovery|needs_translation|reconcile_all|REPO_SYNC_TOKEN/,
  );
  assert.doesNotMatch(
    read(path.join(root, 'scripts/collect-antigravity-fleet-state.sh')),
    /antigravity-translate|TRANSLATIONS_ENABLED|translationNeedsRecovery|needs_translation|reconcile_all/,
  );
}

function testReviewerAndWatcherTrustBoundaries() {
  const review = read(reviewWorkflow);
  const watcher = read(watcherWorkflow);
  const reviewModel = extractStepBlock(reviewWorkflow, 'Run isolated reviewer and verifier');
  const triageModel = extractStepBlock(watcherWorkflow, 'Triage redacted failure logs');

  assert.doesNotMatch(review, /pull_request_target/);
  assert.match(review, /ref: \$\{\{ inputs\.expected_base_sha \}\}/);
  assert.match(review, /git fetch --no-tags origin "\+refs\/pull\/\$\{PR_NUMBER\}\/head:refs\/agy\/pr-head"/);
  assert.match(extractJobBlock(reviewWorkflow, 'review'), /permissions:\n {6}contents: read/);
  assert.doesNotMatch(reviewModel, /GH_TOKEN|GITHUB_TOKEN|REPO_SYNC_TOKEN/);
  assert.match(reviewModel, /chmod 0600 "\$credential_tmp"/);
  assert.match(extractJobBlock(watcherWorkflow, 'triage'), /permissions:\n {6}contents: read/);
  assert.doesNotMatch(extractJobBlock(watcherWorkflow, 'triage'), /REPO_SETTINGS_TOKEN|REPO_SYNC_TOKEN/);
  assert.match(triageModel, /env -u GH_TOKEN -u GITHUB_TOKEN -u GATEWAY_TOKEN -u GATEWAY_URL/);
  assert.match(triageModel, /agy --new-project --sandbox --mode plan --disable-slash-commands/);
  assert.match(triageModel, /Do not review code, edit files, contact GitHub, or infer missing secrets/);
  assert.match(watcher, /cancel-in-progress: false/);
}

async function testExactHeadValidation() {
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const script = new AsyncFunction(
    'github',
    'context',
    'core',
    'require',
    extractStepBlock(reviewWorkflow, 'Validate exact pull-request head', 'script'),
  );
  const base = 'b'.repeat(40);
  const head = 'h'.repeat(40);
  const pull = {
    base: { sha: base },
    head: { repo: { full_name: 'f5-sales-demo/example' }, sha: head },
  };
  const names = ['BASE_SHA', 'GITHUB_REPOSITORY', 'GITHUB_WORKSPACE', 'HEAD_SHA', 'PR_NUMBER'];
  const previous = Object.fromEntries(names.map((name) => [name, process.env[name]]));
  Object.assign(process.env, {
    BASE_SHA: base,
    GITHUB_REPOSITORY: 'f5-sales-demo/example',
    GITHUB_WORKSPACE: root,
    HEAD_SHA: head,
    PR_NUMBER: '42',
  });
  const github = {
    request: async () => ({ data: { resources: { core: { remaining: 5000, reset: 0 } } } }),
    rest: { pulls: { get: async () => ({ data: pull }) } },
  };

  try {
    await script(github, { repo: { owner: 'f5-sales-demo', repo: 'example' } }, {}, require);
    pull.head.repo.full_name = 'outsider/fork';
    await assert.rejects(
      script(github, { repo: { owner: 'f5-sales-demo', repo: 'example' } }, {}, require),
      /exact review receipt/,
    );
  } finally {
    for (const [name, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  }
}

function testReceiptAndGate() {
  const base = 'b'.repeat(40);
  const head = 'h'.repeat(40);
  const receiptDirectory = temporaryDirectory('agy-review-receipt-');
  const gateDirectory = temporaryDirectory('agy-review-gate-');
  fs.mkdirSync(path.join(receiptDirectory, 'review-artifact'));
  fs.mkdirSync(path.join(gateDirectory, 'review-artifact'));

  const validateReceipt = (report) => {
    fs.writeFileSync(path.join(receiptDirectory, 'review-artifact/report.json'), JSON.stringify(report) + '\n');
    return runShell(extractStepBlock(reviewWorkflow, 'Validate receipt'), receiptDirectory, {
      AGY_VERSION: '1.1.10',
      BASE_SHA: base,
      GITHUB_REPOSITORY: 'f5-sales-demo/example',
      HEAD_SHA: head,
      PR_NUMBER: '42',
      RUNNER_TEMP: receiptDirectory,
      WORKFLOW_SHA: 'workflow-current',
    });
  };
  const validateGate = (report) => {
    fs.writeFileSync(path.join(gateDirectory, 'review-artifact/report.json'), JSON.stringify(report) + '\n');
    return runShell(extractStepBlock(reviewWorkflow, 'Enforce Antigravity gate'), gateDirectory, {
      RUNNER_TEMP: gateDirectory,
    });
  };

  const valid = reviewReport(base, head, 'workflow-current');
  assert.equal(validateReceipt(valid).status, 0);
  assert.notEqual(validateReceipt(reviewReport(base, head, 'stale-workflow')).status, 0);
  assert.equal(validateGate(valid).status, 0);
  const blocking = structuredClone(valid);
  blocking.reviewer.findings.push({ severity: 'high' });
  assert.notEqual(validateGate(blocking).status, 0);
}

testEnglishOnlyRetirement();
testReviewerAndWatcherTrustBoundaries();
await testExactHeadValidation();
testReceiptAndGate();

console.log('PASS: Antigravity reviewer, watcher, and English-only feature UAT');
