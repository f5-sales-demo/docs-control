import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';

if (process.env.ANTIGRAVITY_UAT_BOUNDED_RUN !== '1') {
  const bounded = spawnSync(
    'timeout',
    ['--signal=TERM', '--kill-after=5s', '120s', process.execPath, ...process.argv.slice(1)],
    { env: { ...process.env, ANTIGRAVITY_UAT_BOUNDED_RUN: '1' }, stdio: 'inherit' },
  );
  if (bounded.status === 124 || bounded.signal) {
    throw new Error(`Antigravity CI UAT exceeded its 120-second timeout (${bounded.signal ?? bounded.status})`);
  }
  process.exit(bounded.status ?? 1);
}

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

function assertNoFixtureChildren() {
  const processes = spawnSync('ps', ['-eo', 'args='], { encoding: 'utf8', timeout: 5000 });
  assert.equal(processes.status, 0, processes.stderr);
  const leaked = processes.stdout
    .split('\n')
    .filter((line) => temporaryDirectories.some((directory) => line.includes(directory)));
  assert.deepEqual(leaked, [], `fixture child processes leaked:\n${leaked.join('\n')}`);
}

function read(file) {
  return fs.readFileSync(file, 'utf8');
}

function extractStepBlock(workflowPath, stepName, key = 'run') {
  const lines = read(workflowPath).split('\n');
  const start = lines.indexOf(`      - name: ${stepName}`);
  if (start === -1) throw new Error('workflow step is missing');
  const end = lines.findIndex((line, index) => index > start && /^ {6}- name: /.test(line));
  const block = lines.slice(start, end === -1 ? undefined : end);
  const marker = block.findIndex((line) => line === `        ${key}: |` || line === `          ${key}: |`);
  if (marker === -1) throw new Error('workflow step block is missing');
  const indentation = block[marker].search(/\S/) + 2;
  return block
    .slice(marker + 1)
    .map((line) => (line.length >= indentation ? line.slice(indentation) : ''))
    .join('\n');
}

function extractJobBlock(workflowPath, jobName) {
  const lines = read(workflowPath).split('\n');
  const start = lines.indexOf(`  ${jobName}:`);
  if (start === -1) throw new Error('workflow job is missing');
  const end = lines.findIndex((line, index) => index > start && /^ {2}[A-Za-z0-9_-]+:$/.test(line));
  return lines.slice(start, end === -1 ? undefined : end).join('\n');
}

function runShell(script, cwd, env = {}) {
  const environment = { ...process.env, AGY_PROGRESS_INTERVAL_SECONDS: '1' };
  for (const [name, value] of Object.entries(env)) {
    if (value === null) delete environment[name];
    else environment[name] = value;
  }
  return spawnSync(
    'timeout',
    ['--signal=TERM', '--kill-after=2s', '20s', 'bash', '-c', `set -euo pipefail\n${script}`],
    {
      cwd,
      encoding: 'utf8',
      env: environment,
      maxBuffer: 4 * 1024 * 1024,
    },
  );
}

function writeExecutable(file, body) {
  fs.writeFileSync(file, body, { mode: 0o755 });
}

function reviewTargetReceipt(base, head) {
  return createHash('sha256').update(`agy-review-target-v1\ncode\n${base}\n${head}\n`).digest('hex');
}

function reviewReport(base, head, workflow) {
  const targetReceipt = reviewTargetReceipt(base, head);
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
    reviewer: {
      verdict: 'approve',
      summary: 'clean',
      findings: [],
      next_steps: [],
      review_target_receipt: targetReceipt,
    },
    verifier: {
      verdict: 'approve',
      summary: 'verified',
      findings: [],
      next_steps: [],
      review_target_receipt: targetReceipt,
    },
    attempt_metadata: [
      { phase: 'reviewer', count: 1, class: 'success', exit_status: 0, elapsed_seconds: 0 },
      { phase: 'verifier', count: 1, class: 'success', exit_status: 0, elapsed_seconds: 0 },
    ],
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
  assert.match(review, /timeout-minutes: 45/);
  assert.match(reviewModel, /AGY_REVIEW_DIAGNOSTIC_DIR="\$RUNNER_TEMP\/review-artifact\/diagnostics"/);
  assert.match(reviewModel, /review_target_receipt/);
  assert.doesNotMatch(reviewModel, /AGY_REVIEW_(?:DEADLINE|ATTEMPT_TIMEOUT|ATTEMPT_CAP)_/);
  assert.match(review, /Review execution failed — no approval was granted/);
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
  const fullNameKey = ['full', 'name'].join('_');
  const pull = {
    base: { sha: base },
    head: { repo: { [fullNameKey]: 'f5-sales-demo/example' }, sha: head },
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
    pull.head.repo[fullNameKey] = 'outsider/fork';
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
    fs.writeFileSync(path.join(receiptDirectory, 'review-artifact/report.json'), `${JSON.stringify(report)}\n`);
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
    fs.writeFileSync(path.join(gateDirectory, 'review-artifact/report.json'), `${JSON.stringify(report)}\n`);
    return runShell(extractStepBlock(reviewWorkflow, 'Enforce Antigravity gate'), gateDirectory, {
      RUNNER_TEMP: gateDirectory,
    });
  };

  const valid = reviewReport(base, head, 'workflow-current');
  assert.equal(validateReceipt(valid).status, 0);
  assert.notEqual(validateReceipt(reviewReport(base, head, 'stale-workflow')).status, 0);
  assert.notEqual(validateReceipt({ ...valid, attempt_metadata: [] }).status, 0);
  assert.notEqual(
    validateReceipt({
      ...valid,
      reviewer: { ...valid.reviewer, verdict: 'pass' },
    }).status,
    0,
  );
  const mismatchedReceipt = structuredClone(valid);
  mismatchedReceipt.reviewer.review_target_receipt = '0'.repeat(64);
  assert.notEqual(validateReceipt(mismatchedReceipt).status, 0);
  assert.equal(validateGate(valid).status, 0);
  const blocking = structuredClone(valid);
  blocking.reviewer.findings.push({ severity: 'high' });
  assert.notEqual(validateGate(blocking).status, 0);
}

function childReport(verdict = 'approve', findings = []) {
  return {
    verdict,
    summary: verdict === 'approve' ? 'clean' : 'review unavailable',
    findings,
    next_steps: verdict === 'approve' ? [] : ['rerun'],
    review_target_receipt: reviewTargetReceipt('b'.repeat(40), 'h'.repeat(40)),
  };
}

const syntheticFinding = {
  severity: 'critical',
  title: 'Review execution unavailable',
  body: 'No approval was granted.',
  file: 'scripts/agy-review.sh',
  line_start: 1,
  line_end: 1,
  confidence: 1,
  recommendation: 'rerun',
};

function runReviewWorkflow(report, status) {
  const work = temporaryDirectory('agy-review-workflow-');
  const bin = path.join(work, 'bin');
  const tool = path.join(work, 'agy-review-tool');
  fs.mkdirSync(bin);
  fs.mkdirSync(tool);
  fs.mkdirSync(path.join(work, 'home'));
  writeExecutable(
    path.join(bin, 'dbus-run-session'),
    '#!/usr/bin/env bash\nset -euo pipefail\ntest "$1" = --\nshift\nexec "$@"\n',
  );
  writeExecutable(
    path.join(bin, 'gnome-keyring-daemon'),
    `#!/usr/bin/env bash
IFS= read -r password
test "\${#password}" -eq 64
printf "GNOME_KEYRING_CONTROL=%q\\nGNOME_KEYRING_PID=%q\\n" "$RUNNER_TEMP/keyring" 12345
`,
  );
  writeExecutable(path.join(bin, 'python3'), '#!/usr/bin/env bash\ncat >/dev/null\n');
  writeExecutable(path.join(bin, 'agy'), '#!/usr/bin/env bash\necho 1.1.10\n');
  writeExecutable(
    path.join(tool, 'agy-review.sh'),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'antigravity=%s github=%s gateway=%s\n' "\${ANTIGRAVITY_TOKEN:-}" "\${GITHUB_TOKEN:-}" "\${GATEWAY_TOKEN:-}" >"$RUNNER_TEMP/model-credentials"
mkdir -p "$AGY_REVIEW_DIAGNOSTIC_DIR"
printf '%s\n' 'provider token=[REDACTED]' >"$AGY_REVIEW_DIAGNOSTIC_DIR/reviewer-attempt-1.stderr-summary.txt"
if [ "\${STUB_STATUS:-0}" -eq 19 ]; then exit 19; fi
printf '%s\n' "$STUB_REPORT" >"$AGY_REVIEW_REPORT_FILE"
exit "\${STUB_STATUS:-0}"
`,
  );
  const checksum = spawnSync('sha512sum', [path.join(bin, 'agy')], { encoding: 'utf8' });
  assert.equal(checksum.status, 0, checksum.stderr);
  fs.writeFileSync(path.join(work, 'agy-review-bin.sha512'), checksum.stdout);
  const result = runShell(extractStepBlock(reviewWorkflow, 'Run isolated reviewer and verifier'), work, {
    AGY_VERSION: '1.1.10',
    ANTIGRAVITY_TOKEN: 'go-keyring-base64:dGVzdA==',
    BASE_SHA: 'b'.repeat(40),
    GCP_PROJECT_ID: 'fixture-project',
    GITHUB_REPOSITORY: 'f5-sales-demo/example',
    GITHUB_WORKFLOW_SHA: 'workflow-current',
    GITHUB_WORKSPACE: work,
    HEAD_SHA: 'h'.repeat(40),
    HOME: path.join(work, 'home'),
    PATH: `${bin}:${process.env.PATH}`,
    RUNNER_TEMP: work,
    STUB_REPORT: report === null ? '' : JSON.stringify(report),
    STUB_STATUS: String(status),
  });
  return { result, work };
}

function testWorkflowOutcomes() {
  const successAttempts = [
    { phase: 'reviewer', count: 1, class: 'success', exit_status: 0, elapsed_seconds: 0 },
    { phase: 'verifier', count: 1, class: 'success', exit_status: 0, elapsed_seconds: 0 },
  ];
  const finding = { ...syntheticFinding, severity: 'high', title: 'Model finding' };
  const scenarios = [
    ['clean', { reviewer: childReport(), verifier: childReport(), attempt_metadata: successAttempts }, 0],
    [
      'model finding',
      {
        reviewer: childReport('needs-attention', [finding]),
        verifier: childReport(),
        attempt_metadata: successAttempts,
      },
      3,
    ],
    [
      'reviewer failure',
      {
        reviewer: childReport('needs-attention', [syntheticFinding]),
        verifier: childReport('needs-attention'),
        attempt_metadata: [1, 2, 3].map((count) => ({
          phase: 'reviewer',
          count,
          class: 'transient-cli-failure',
          exit_status: 19,
          elapsed_seconds: 1,
        })),
      },
      3,
    ],
    [
      'verifier failure',
      {
        reviewer: childReport(),
        verifier: childReport('needs-attention', [syntheticFinding]),
        attempt_metadata: [
          successAttempts[0],
          ...[1, 2, 3].map((count) => ({
            phase: 'verifier',
            count,
            class: 'transient-cli-failure',
            exit_status: 19,
            elapsed_seconds: 1,
          })),
        ],
      },
      3,
    ],
    ['wrapper catastrophe', null, 19],
  ];

  for (const [label, sourceReport, status] of scenarios) {
    const outcome = runReviewWorkflow(sourceReport, status);
    assert.equal(outcome.result.status, 0, `${label}: ${outcome.result.stderr}`);
    const artifact = path.join(outcome.work, 'review-artifact');
    const report = JSON.parse(read(path.join(artifact, 'report.json')));
    assert.equal(read(path.join(artifact, 'tool-status')).trim(), String(status));
    assert.ok(fs.statSync(path.join(artifact, 'diagnostics')).isDirectory());
    assert.equal(report.receipt.tool_status, status);
    assert.ok(report.attempt_metadata.length >= 1 && report.attempt_metadata.length <= 6);
    for (const phase of ['reviewer', 'verifier']) {
      assert.match(report[phase].verdict, /^(?:approve|needs-attention)$/);
      assert.ok(Array.isArray(report[phase].findings));
    }
    assert.equal(read(path.join(outcome.work, 'model-credentials')).trim(), 'antigravity= github= gateway=');
    assert.doesNotMatch(JSON.stringify(report), /fixture-secret|raw provider diagnostic/i);
  }
}

async function testFailureComment() {
  const work = temporaryDirectory('agy-review-comment-');
  const report = reviewReport('b'.repeat(40), 'h'.repeat(40), 'workflow-current');
  report.receipt.tool_status = 3;
  report.verifier = childReport('needs-attention', [syntheticFinding]);
  report.attempt_metadata = [
    report.attempt_metadata[0],
    ...[1, 2, 3].map((count) => ({
      phase: 'verifier',
      count,
      class: 'transient-cli-failure',
      exit_status: 19,
      elapsed_seconds: 1,
    })),
  ];
  const reportPath = path.join(work, 'report.json');
  fs.writeFileSync(reportPath, `${JSON.stringify(report)}\n`);
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const script = new AsyncFunction(
    'github',
    'context',
    'require',
    extractStepBlock(reviewWorkflow, 'Publish deduplicated review comment', 'script'),
  );
  const created = [];
  const issues = {
    createComment: async (parameters) => created.push(parameters),
    listComments: async () => [],
    updateComment: async () => {},
  };
  const github = {
    paginate: async (endpoint, parameters) => endpoint(parameters),
    request: async () => ({ data: { resources: { core: { remaining: 5000, reset: 0 } } } }),
    rest: { issues },
  };
  const previous = {
    REPORT_PATH: process.env.REPORT_PATH,
    PR_NUMBER: process.env.PR_NUMBER,
    GITHUB_WORKSPACE: process.env.GITHUB_WORKSPACE,
  };
  Object.assign(process.env, { REPORT_PATH: reportPath, PR_NUMBER: '42', GITHUB_WORKSPACE: root });
  try {
    await script(github, { repo: { owner: 'f5-sales-demo', repo: 'example' } }, require);
    const body = created[0].body;
    assert.match(body, /<!-- antigravity-pr-review:h{40} -->/);
    assert.match(body, /Review execution failed — no approval was granted/);
    assert.match(body, /Phase: verifier/);
    assert.match(body, /Retry count: 3/);
    assert.match(body, /Failure class: transient-cli-failure/);
    assert.match(body, /Please re-run this workflow/);
    assert.doesNotMatch(body, /token=|password=|raw provider diagnostic/i);
  } finally {
    for (const [name, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  }
}

testEnglishOnlyRetirement();
testReviewerAndWatcherTrustBoundaries();
await testExactHeadValidation();
testReceiptAndGate();
testWorkflowOutcomes();
await testFailureComment();
assertNoFixtureChildren();

console.log('PASS: Antigravity reviewer, watcher, and English-only feature UAT');
