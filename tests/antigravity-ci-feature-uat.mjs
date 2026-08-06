import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';

if (!process.argv[2]) throw new Error('repository root is required');
const root = path.resolve(process.argv[2]);

const reviewWorkflow = path.join(root, '.github/workflows/antigravity-review.yml');
const translationWorkflow = path.join(root, '.github/workflows/antigravity-translate.yml');
const translationCaller = path.join(root, 'workflows/antigravity-translate.yml');
const watcherWorkflow = path.join(root, '.github/workflows/antigravity-fleet-watcher.yml');
const repositoryName = ['f5-sales-demo', 'example'].join('/');
const temporaryDirectories = [];
const require = createRequire(import.meta.url);
const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;

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

function extractStepBlock(workflowPath, stepName, key = 'run') {
  const lines = fs.readFileSync(workflowPath, 'utf8').split('\n');
  const step = lines.indexOf(`      - name: ${stepName}`);
  if (step === -1) throw new Error(`step not found: ${stepName}`);
  const end = lines.findIndex((line, index) => index > step && /^ {6}- name: /.test(line));
  const stepLines = lines.slice(step, end === -1 ? undefined : end);
  const marker = stepLines.findIndex((line) => line === `        ${key}: |` || line === `          ${key}: |`);
  if (marker === -1) throw new Error(`${key} block not found for step: ${stepName}`);
  const indentation = stepLines[marker].search(/\S/) + 2;
  return stepLines
    .slice(marker + 1)
    .map((line) => (line.length >= indentation ? line.slice(indentation) : ''))
    .join('\n');
}

function extractJobBlock(workflowPath, jobName) {
  const lines = fs.readFileSync(workflowPath, 'utf8').split('\n');
  const start = lines.indexOf(`  ${jobName}:`);
  if (start === -1) throw new Error(`job not found: ${jobName}`);
  const end = lines.findIndex((line, index) => index > start && /^ {2}[A-Za-z0-9_-]+:$/.test(line));
  return lines.slice(start, end === -1 ? undefined : end).join('\n');
}

async function runExactHeadValidation(workflowPath, stepName, pull, expected = {}) {
  const script = new AsyncFunction(
    'github',
    'context',
    'core',
    'require',
    extractStepBlock(workflowPath, stepName, 'script'),
  );
  const environment = {
    BASE_SHA: expected.baseSha ?? pull.base.sha,
    GITHUB_REPOSITORY: repositoryName,
    GITHUB_WORKSPACE: root,
    HEAD_SHA: expected.headSha ?? pull.head.sha,
    PR_NUMBER: '42',
  };
  const previous = Object.fromEntries([...Object.keys(environment), 'HEAD_REF'].map((key) => [key, process.env[key]]));
  Object.assign(process.env, environment);
  const exported = {};
  try {
    await script(
      {
        request: async () => {
          throw new Error('rate-limit lookup was not expected');
        },
        rest: { pulls: { get: async () => ({ data: pull }) } },
      },
      { repo: { owner: 'f5-sales-demo', repo: 'example' } },
      {
        exportVariable(name, value) {
          exported[name] = value;
          process.env[name] = String(value);
        },
      },
      require,
    );
    return { exported, status: 0 };
  } catch (error) {
    return { error, exported, status: 1 };
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

function testNoAppTokenRouting() {
  const translation = fs.readFileSync(translationWorkflow, 'utf8');
  const caller = fs.readFileSync(translationCaller, 'utf8');
  const watcher = fs.readFileSync(watcherWorkflow, 'utf8');
  const translateJob = extractJobBlock(translationWorkflow, 'translate');
  const translationPublishJob = extractJobBlock(translationWorkflow, 'publish');
  const collectJob = extractJobBlock(watcherWorkflow, 'collect');
  const triageJob = extractJobBlock(watcherWorkflow, 'triage');
  const watcherPublishJob = extractJobBlock(watcherWorkflow, 'publish');

  for (const [name, contents] of [
    ['translation workflow', translation],
    ['translation caller', caller],
    ['fleet watcher', watcher],
  ]) {
    assert.doesNotMatch(contents, /AUTOMATION_APP_(?:ID|PRIVATE_KEY)/, `${name} must not require a GitHub App`);
    assert.doesNotMatch(contents, /actions\/create-github-app-token/, `${name} must not mint GitHub App tokens`);
  }

  assert.match(
    translation,
    /REPO_SYNC_TOKEN:\n\s+required: true/,
    'reusable translation must require the existing fleet PAT',
  );
  assert.match(
    caller,
    /REPO_SYNC_TOKEN: \$\{\{ secrets\.REPO_SYNC_TOKEN \}\}/,
    'managed translation caller must explicitly pass the existing fleet PAT',
  );
  assert.doesNotMatch(translateJob, /REPO_SYNC_TOKEN/, 'translation model job must not receive the publication token');
  assert.match(
    translationPublishJob,
    /GH_TOKEN: \$\{\{ secrets\.REPO_SYNC_TOKEN \}\}/,
    'translation publication must use the existing fleet PAT so the push retriggers CI',
  );

  assert.match(
    collectJob,
    /GH_TOKEN: \$\{\{ secrets\.REPO_SETTINGS_TOKEN \}\}/,
    'watcher collection must use REPO_SETTINGS_TOKEN',
  );
  assert.doesNotMatch(
    triageJob,
    /REPO_SETTINGS_TOKEN|REPO_SYNC_TOKEN/,
    'Antigravity triage must receive no governance token',
  );
  assert.match(
    watcherPublishJob,
    /github-token: \$\{\{ secrets\.REPO_SETTINGS_TOKEN \}\}/,
    'watcher publication must use REPO_SETTINGS_TOKEN',
  );
}

function testProgressRouting() {
  const review = fs.readFileSync(reviewWorkflow, 'utf8');
  const translation = fs.readFileSync(translationWorkflow, 'utf8');
  const watcher = fs.readFileSync(watcherWorkflow, 'utf8');
  assert.match(review, /cp scripts\/agy-review[.]sh scripts\/run-with-progress[.]sh/);
  assert.match(review, /2>&1 \| tee "\$RUNNER_TEMP\/review[.]log"/);
  assert.match(translation, /\/opt\/agy-translation-contract\/run-with-progress[.]sh --phase translation-generation/);
  assert.match(watcher, /scripts\/run-with-progress[.]sh --phase fleet-triage/);
}

function testHeadlessKeyringBootstrap() {
  for (const [workflow, stepName] of [
    [reviewWorkflow, 'Run isolated reviewer and verifier'],
    [translationWorkflow, 'Generate translations without write credentials'],
    [watcherWorkflow, 'Triage redacted failure logs'],
  ]) {
    const script = extractStepBlock(workflow, stepName);
    assert.match(script, /keyring_password=\$\(openssl rand -hex 32\)/);
    assert.match(
      script,
      /printf '%s\\n' "\$keyring_password" \| gnome-keyring-daemon --unlock --daemonize --components=secrets/,
    );
    assert.match(script, /unset keyring_password/);
    assert.doesNotMatch(script, /printf '' \| gnome-keyring-daemon/);
  }
}

function writeExecutable(file, body) {
  fs.writeFileSync(file, body, { mode: 0o755 });
}

function runShell(script, { cwd, env = {} }) {
  const environment = { ...process.env };
  for (const [name, value] of Object.entries(env)) {
    if (value === null) delete environment[name];
    else environment[name] = value;
  }
  return spawnSync('bash', ['-c', `set -euo pipefail\n${script}`], {
    cwd,
    encoding: 'utf8',
    env: environment,
  });
}

function run(command, args, { cwd, env = {} } = {}) {
  const result = spawnSync(command, args, {
    cwd,
    encoding: 'utf8',
    env: { ...process.env, ...env },
  });
  assert.equal(result.status, 0, `${command} ${args.join(' ')} failed:\n${result.stdout}${result.stderr}`);
  return result.stdout.trim();
}

function git(cwd, ...args) {
  return run('git', args, { cwd });
}

function initializeGitRepository(directory) {
  fs.mkdirSync(directory, { recursive: true });
  git(directory, 'init', '-q');
  git(directory, 'config', 'user.email', 'fixture@example.com');
  git(directory, 'config', 'user.name', 'Fixture');
}

function sha256Prefix(file) {
  return createHash('sha256').update(fs.readFileSync(file)).digest('hex').slice(0, 12);
}

function repositoryIdentity() {
  return { ['full' + '_name']: repositoryName };
}

function validReviewReport({ base, head, workflow }) {
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
    reviewer: { verdict: 'pass', summary: 'clean', findings: [], next_steps: [] },
    verifier: { verdict: 'pass', summary: 'verified', findings: [], next_steps: [] },
  };
}

function runReviewReceiptValidation({ report, pull }) {
  const work = temporaryDirectory('agy-review-receipt-');
  const artifact = path.join(work, 'review-artifact');
  fs.mkdirSync(artifact);
  fs.writeFileSync(path.join(artifact, 'report.json'), `${JSON.stringify(report)}\n`);
  return runShell(extractStepBlock(reviewWorkflow, 'Validate receipt'), {
    cwd: work,
    env: {
      AGY_VERSION: '1.1.10',
      BASE_SHA: pull.base.sha,
      GITHUB_REPOSITORY: 'f5-sales-demo/example',
      HEAD_SHA: pull.head.sha,
      PR_NUMBER: '42',
      RUNNER_TEMP: work,
      WORKFLOW_SHA: 'workflow-current',
    },
  });
}

function runTranslationReceiptValidation({ receipt, pull }) {
  const work = temporaryDirectory('agy-translation-receipt-');
  const artifact = path.join(work, 'translation-artifact');
  fs.mkdirSync(artifact);
  fs.writeFileSync(path.join(artifact, 'receipt.json'), `${JSON.stringify(receipt)}\n`);
  fs.writeFileSync(path.join(artifact, 'translations.patch'), '');
  return runShell(extractStepBlock(translationWorkflow, 'Validate, commit, and publish translations'), {
    cwd: work,
    env: {
      AGY_VERSION: '1.1.10',
      BASE_SHA: pull.base.sha,
      GH_TOKEN: 'fixture-token',
      GITHUB_REPOSITORY: 'f5-sales-demo/example',
      HEAD_SHA: pull.head.sha,
      HEAD_REF: pull.head.ref,
      PR_NUMBER: '42',
      RUNNER_TEMP: work,
      WORKFLOW_SHA: 'workflow-current',
    },
  });
}

function initializeExactHeadFixture() {
  const work = temporaryDirectory('agy-exact-head-');
  const repository = path.join(work, 'repository');
  const remote = path.join(work, 'remote.git');
  initializeGitRepository(repository);
  run('git', ['init', '--bare', '-q', remote], { cwd: work });
  fs.mkdirSync(path.join(repository, 'scripts'));
  fs.mkdirSync(path.join(repository, '.agents/skills/i18n-translate'), { recursive: true });
  fs.mkdirSync(path.join(repository, 'docs/en'), { recursive: true });
  writeExecutable(path.join(repository, 'scripts/agy-review.sh'), '#!/usr/bin/env bash\necho trusted-review-tool\n');
  writeExecutable(
    path.join(repository, 'scripts/run-with-progress.sh'),
    '#!/usr/bin/env bash\necho trusted-progress-tool\n',
  );
  fs.writeFileSync(path.join(repository, 'scripts/agy-review-output.schema.json'), '{}\n');
  writeExecutable(
    path.join(repository, 'scripts/validate-translations.sh'),
    '#!/usr/bin/env bash\necho trusted-validator\n',
  );
  fs.writeFileSync(path.join(repository, '.agents/skills/i18n-translate/SKILL.md'), 'trusted translation contract\n');
  fs.writeFileSync(path.join(repository, 'docs/en/page.mdx'), '---\ntitle: Page\n---\n\nBase.\n');
  git(repository, 'add', '.');
  git(repository, 'commit', '-qm', 'base');
  const base = git(repository, 'rev-parse', 'HEAD');
  git(repository, 'remote', 'add', 'origin', remote);
  git(repository, 'push', '-q', 'origin', 'HEAD:refs/heads/main');

  fs.writeFileSync(path.join(repository, 'scripts/agy-review.sh'), '#!/usr/bin/env bash\necho untrusted-head-tool\n');
  fs.writeFileSync(
    path.join(repository, 'scripts/run-with-progress.sh'),
    '#!/usr/bin/env bash\necho untrusted-head-progress-tool\n',
  );
  fs.writeFileSync(
    path.join(repository, 'scripts/validate-translations.sh'),
    '#!/usr/bin/env bash\necho untrusted-head-validator\n',
  );
  fs.writeFileSync(path.join(repository, '.agents/skills/i18n-translate/SKILL.md'), 'untrusted head contract\n');
  fs.appendFileSync(path.join(repository, 'docs/en/page.mdx'), '\nChanged English.\n');
  git(repository, 'add', '.');
  git(repository, 'commit', '-qm', 'head');
  const head = git(repository, 'rev-parse', 'HEAD');
  git(repository, 'push', '-q', 'origin', 'HEAD:refs/heads/feature/1246-uat');
  git(repository, 'push', '-q', 'origin', 'HEAD:refs/pull/42/head');
  git(repository, 'checkout', '-q', '--detach', base);
  return {
    base,
    head,
    repository,
    pull: {
      base: { ref: 'main', sha: base },
      head: {
        ref: 'feature/1246-uat',
        repo: repositoryIdentity(),
        sha: head,
      },
    },
  };
}

function runReviewerPreparation(fixture) {
  const runner = temporaryDirectory('agy-review-prepare-');
  const result = runShell(extractStepBlock(reviewWorkflow, 'Fetch exact pull-request head as data'), {
    cwd: fixture.repository,
    env: {
      BASE_SHA: fixture.base,
      GITHUB_REPOSITORY: 'f5-sales-demo/example',
      HEAD_SHA: fixture.head,
      PR_NUMBER: '42',
      RUNNER_TEMP: runner,
    },
  });
  return { result, runner };
}

async function testReviewerPreparation() {
  const fixture = initializeExactHeadFixture();
  assert.equal(
    (await runExactHeadValidation(reviewWorkflow, 'Validate exact pull-request head', fixture.pull)).status,
    0,
  );
  const { result, runner } = runReviewerPreparation(fixture);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(git(fixture.repository, 'rev-parse', 'HEAD'), fixture.head);
  assert.match(fs.readFileSync(path.join(runner, 'agy-review-tool/agy-review.sh'), 'utf8'), /trusted-review-tool/);
  assert.match(
    fs.readFileSync(path.join(runner, 'agy-review-tool/run-with-progress.sh'), 'utf8'),
    /trusted-progress-tool/,
  );
  assert.doesNotMatch(
    fs.readFileSync(path.join(runner, 'agy-review-tool/agy-review.sh'), 'utf8'),
    /untrusted-head-tool/,
  );
  assert.doesNotMatch(
    fs.readFileSync(path.join(runner, 'agy-review-tool/run-with-progress.sh'), 'utf8'),
    /untrusted-head-progress-tool/,
  );

  const forkFixture = initializeExactHeadFixture();
  const fork = structuredClone(forkFixture.pull);
  fork.head.repo.full_name = 'outsider/fork';
  assert.notEqual((await runExactHeadValidation(reviewWorkflow, 'Validate exact pull-request head', fork)).status, 0);

  const staleFixture = initializeExactHeadFixture();
  const stale = structuredClone(staleFixture.pull);
  stale.head.sha = 'd'.repeat(40);
  assert.notEqual(
    (
      await runExactHeadValidation(reviewWorkflow, 'Validate exact pull-request head', stale, {
        headSha: staleFixture.head,
      })
    ).status,
    0,
  );
}

function runTranslationPreparation(fixture) {
  const runner = temporaryDirectory('agy-translation-prepare-');
  const bin = path.join(runner, 'bin');
  const installed = path.join(runner, 'installed');
  fs.mkdirSync(bin);
  fs.mkdirSync(installed);
  writeExecutable(
    path.join(bin, 'sudo'),
    `#!/usr/bin/env bash
set -euo pipefail
test "$1" = install
shift
if [ "\${1:-}" = -d ]; then
  exit 0
fi
previous=""
for argument in "$@"; do
  source_path=$previous
  previous=$argument
done
cp "$source_path" "$FAKE_INSTALL_DIR/$(basename "$previous")"
`,
  );
  const result = runShell(extractStepBlock(translationWorkflow, 'Prepare exact pull-request snapshot'), {
    cwd: fixture.repository,
    env: {
      BASE_SHA: fixture.base,
      FAKE_INSTALL_DIR: installed,
      GH_TOKEN: 'read-only-fixture',
      GITHUB_REPOSITORY: 'f5-sales-demo/example',
      HEAD_SHA: fixture.head,
      PATH: `${bin}:${process.env.PATH}`,
      PR_NUMBER: '42',
      RUNNER_TEMP: runner,
    },
  });
  return { installed, result };
}

async function testTranslationPreparation() {
  const fixture = initializeExactHeadFixture();
  const validation = await runExactHeadValidation(
    translationWorkflow,
    'Validate exact pull-request head',
    fixture.pull,
  );
  assert.equal(validation.status, 0);
  assert.equal(validation.exported.HEAD_REF, 'feature/1246-uat');
  const prepared = runTranslationPreparation(fixture);
  assert.equal(prepared.result.status, 0, prepared.result.stderr);
  assert.equal(git(fixture.repository, 'rev-parse', 'HEAD'), fixture.head);
  assert.match(fs.readFileSync(path.join(prepared.installed, 'SKILL.md'), 'utf8'), /trusted/);
  assert.doesNotMatch(
    fs.readFileSync(path.join(prepared.installed, 'validate-translations.sh'), 'utf8'),
    /untrusted-head/,
  );
  assert.match(fs.readFileSync(path.join(prepared.installed, 'run-with-progress.sh'), 'utf8'), /trusted-progress-tool/);
  assert.doesNotMatch(
    fs.readFileSync(path.join(prepared.installed, 'run-with-progress.sh'), 'utf8'),
    /untrusted-head-progress-tool/,
  );
  assert.equal(fs.readFileSync(path.join(prepared.installed, 'changed-english.txt'), 'utf8'), 'docs/en/page.mdx\n');
  const expectedHash = createHash('sha256')
    .update(fs.readFileSync(path.join(fixture.repository, 'docs/en/page.mdx')))
    .digest('hex')
    .slice(0, 12);
  assert.equal(
    fs.readFileSync(path.join(prepared.installed, 'expected-source-hashes.tsv'), 'utf8'),
    `docs/en/page.mdx\t${expectedHash}\n`,
    'the root-owned contract must carry the exact checked-out English source hash',
  );

  const forkFixture = initializeExactHeadFixture();
  const fork = structuredClone(forkFixture.pull);
  fork.head.repo.full_name = 'outsider/fork';
  assert.notEqual(
    (await runExactHeadValidation(translationWorkflow, 'Validate exact pull-request head', fork)).status,
    0,
  );
}

function runPinnedInstaller(workflowPath, { digestOverride, runtimeVersion = '1.1.10' } = {}) {
  const work = temporaryDirectory('agy-installer-');
  const bin = path.join(work, 'bin');
  const archiveSource = path.join(work, 'archive-source');
  const archive = path.join(work, 'runtime.tar.gz');
  fs.mkdirSync(bin);
  fs.mkdirSync(archiveSource);
  writeExecutable(
    path.join(archiveSource, 'antigravity'),
    `#!/usr/bin/env bash\nif [ "\${1:-}" = --version ]; then echo ${runtimeVersion}; fi\n`,
  );
  run('tar', ['-czf', archive, '-C', archiveSource, 'antigravity']);
  const digest = createHash('sha512').update(fs.readFileSync(archive)).digest('hex');
  writeExecutable(
    path.join(bin, 'curl'),
    `#!/usr/bin/env bash
set -euo pipefail
output=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then
    output=$2
    shift 2
  else
    shift
  fi
done
cp "$ARCHIVE_FIXTURE" "$output"
`,
  );
  writeExecutable(
    path.join(bin, 'sudo'),
    `#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = apt-get ]; then
  exit 0
fi
test "$1" = install
shift
previous=""
for argument in "$@"; do
  source_path=$previous
  previous=$argument
done
rm -f "$FAKE_AGY_PATH"
cp "$source_path" "$FAKE_AGY_PATH"
chmod 0555 "$FAKE_AGY_PATH"
`,
  );
  writeExecutable(
    path.join(bin, 'sha512sum'),
    `#!/usr/bin/env bash
set -euo pipefail
test "$1" = --check
test "$2" = --strict
read -r expected file
actual=$(/usr/bin/shasum -a 512 "$file" | awk '{print $1}')
test "$actual" = "$expected"
`,
  );
  const options = {
    cwd: work,
    env: {
      AGY_SHA512: digestOverride ?? digest,
      AGY_URL: 'https://example.com/immutable-fixture.tar.gz',
      AGY_VERSION: '1.1.10',
      ARCHIVE_FIXTURE: archive,
      FAKE_AGY_PATH: path.join(bin, 'agy'),
      PATH: `${bin}:${process.env.PATH}`,
      RUNNER_TEMP: work,
    },
  };
  const block = extractStepBlock(workflowPath, 'Install pinned Antigravity runtime');
  const firstRun = runShell(block, options);
  if (firstRun.status !== 0) return firstRun;
  return runShell(block, options);
}

function testPinnedInstallers() {
  const review = runPinnedInstaller(reviewWorkflow);
  assert.equal(review.status, 0, review.stderr);
  const translation = runPinnedInstaller(translationWorkflow);
  assert.equal(translation.status, 0, translation.stderr);
  assert.notEqual(runPinnedInstaller(reviewWorkflow, { digestOverride: '0'.repeat(128) }).status, 0);
  assert.notEqual(runPinnedInstaller(translationWorkflow, { runtimeVersion: '9.9.9' }).status, 0);
}

function writeSandboxCommandFakes(bin) {
  writeExecutable(
    path.join(bin, 'dbus-run-session'),
    '#!/usr/bin/env bash\nset -euo pipefail\ntest "$1" = --\nshift\nexec "$@"\n',
  );
  writeExecutable(
    path.join(bin, 'gnome-keyring-daemon'),
    `#!/usr/bin/env bash
set -euo pipefail
test "$*" = "--unlock --daemonize --components=secrets"
IFS= read -r password
test "\${#password}" -eq 64
printf 'GNOME_KEYRING_CONTROL=%q\nGNOME_KEYRING_PID=%q\n' "$RUNNER_TEMP/keyring" "12345"
`,
  );
  writeExecutable(path.join(bin, 'python3'), '#!/usr/bin/env bash\ncat >/dev/null\n');
}

function runReviewerModel({ fail = false, missingSecret = false } = {}) {
  const work = temporaryDirectory('agy-review-model-');
  const bin = path.join(work, 'bin');
  const tool = path.join(work, 'agy-review-tool');
  fs.mkdirSync(bin);
  fs.mkdirSync(tool);
  fs.mkdirSync(path.join(work, 'home'));
  writeSandboxCommandFakes(bin);
  writeExecutable(path.join(bin, 'agy'), `#!/usr/bin/env bash\nif [ "\${1:-}" = --version ]; then echo 1.1.10; fi\n`);
  writeExecutable(
    path.join(tool, 'agy-review.sh'),
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$RUNNER_TEMP/review-invocation"
printf '%s\n' '[PROGRESS] component=antigravity phase=fixture state=running elapsed_seconds=1' >&2
if [ "\${STUB_REVIEW_FAIL:-false}" = true ]; then
  exit 19
fi
printf '%s\n' '{"reviewer":{"verdict":"pass","summary":"clean","findings":[],"next_steps":[]},"verifier":{"verdict":"pass","summary":"verified","findings":[],"next_steps":[]}}' >"$AGY_REVIEW_REPORT_FILE"
`,
  );
  const result = runShell(extractStepBlock(reviewWorkflow, 'Run isolated reviewer and verifier'), {
    cwd: work,
    env: {
      AGY_VERSION: '1.1.10',
      ANTIGRAVITY_TOKEN: missingSecret ? null : 'go-keyring-base64:dGVzdA==',
      BASE_SHA: 'b'.repeat(40),
      GCP_PROJECT_ID: 'fixture-project',
      GITHUB_REPOSITORY: 'f5-sales-demo/example',
      GITHUB_WORKFLOW_SHA: 'workflow-current',
      GITHUB_WORKSPACE: work,
      HEAD_SHA: 'h'.repeat(40),
      HOME: path.join(work, 'home'),
      PATH: `${bin}:${process.env.PATH}`,
      RUNNER_TEMP: work,
      STUB_REVIEW_FAIL: fail ? 'true' : 'false',
    },
  });
  return { result, work };
}

function runReviewGate(report) {
  const work = temporaryDirectory('agy-review-gate-');
  const artifact = path.join(work, 'review-artifact');
  fs.mkdirSync(artifact);
  fs.writeFileSync(path.join(artifact, 'report.json'), `${JSON.stringify(report)}\n`);
  return runShell(extractStepBlock(reviewWorkflow, 'Enforce Antigravity gate'), {
    cwd: work,
    env: { RUNNER_TEMP: work },
  });
}

function testReviewerModelAndGate() {
  const completed = runReviewerModel();
  assert.equal(completed.result.status, 0, completed.result.stderr);
  assert.match(completed.result.stdout, /component=antigravity phase=fixture state=running/);
  assert.equal(
    fs.readFileSync(path.join(completed.work, 'review-invocation'), 'utf8').trim(),
    `code --base ${'b'.repeat(40)}`,
  );
  const report = JSON.parse(fs.readFileSync(path.join(completed.work, 'review-artifact/report.json'), 'utf8'));
  assert.deepEqual(report.receipt, {
    agy_version: '1.1.10',
    base_sha: 'b'.repeat(40),
    head_sha: 'h'.repeat(40),
    model: 'Gemini 3.6 Flash (High)',
    repository: 'f5-sales-demo/example',
    tool_status: 0,
    workflow_sha: 'workflow-current',
  });
  assert.equal(runReviewGate(report).status, 0);

  const failed = runReviewerModel({ fail: true });
  assert.equal(failed.result.status, 0, failed.result.stderr);
  const failedReport = JSON.parse(fs.readFileSync(path.join(failed.work, 'review-artifact/report.json'), 'utf8'));
  assert.equal(failedReport.receipt.tool_status, 19);
  assert.equal(failedReport.reviewer.findings[0].severity, 'critical');
  assert.notEqual(runReviewGate(failedReport).status, 0);
  assert.notEqual(runReviewerModel({ missingSecret: true }).result.status, 0);

  const highFinding = structuredClone(report);
  highFinding.reviewer.findings.push({ severity: 'high' });
  assert.notEqual(runReviewGate(highFinding).status, 0);
}

async function testReviewCommentPublication() {
  const work = temporaryDirectory('agy-review-comment-');
  const reportPath = path.join(work, 'report.json');
  const duplicateFinding = {
    body: 'A verified medium-severity finding.',
    file: 'example.js',
    line_end: 7,
    line_start: 7,
    severity: 'medium',
    title: 'Example finding',
  };
  const report = validReviewReport({
    base: 'b'.repeat(40),
    head: 'h'.repeat(40),
    workflow: 'workflow-current',
  });
  report.reviewer.findings.push(duplicateFinding);
  report.verifier.findings.push(structuredClone(duplicateFinding));
  fs.writeFileSync(reportPath, `${JSON.stringify(report)}\n`);
  const script = new AsyncFunction(
    'github',
    'context',
    'require',
    extractStepBlock(reviewWorkflow, 'Publish deduplicated review comment', 'script'),
  );
  const created = [];
  const updated = [];
  let existingComments = [];
  const issues = {
    createComment: async (parameters) => created.push(parameters),
    listComments: async () => existingComments,
    updateComment: async (parameters) => updated.push(parameters),
  };
  const github = {
    paginate: async (endpoint, parameters) => endpoint(parameters),
    rest: new Proxy(
      { issues },
      {
        get(target, property) {
          if (property !== 'issues') throw new Error(`unexpected mutation API: ${String(property)}`);
          return target[property];
        },
      },
    ),
  };
  const previousReportPath = process.env.REPORT_PATH;
  const previousPullNumber = process.env.PR_NUMBER;
  const previousWorkspace = process.env.GITHUB_WORKSPACE;
  process.env.REPORT_PATH = reportPath;
  process.env.PR_NUMBER = '42';
  process.env.GITHUB_WORKSPACE = root;
  try {
    await script(github, { repo: { owner: 'f5-sales-demo', repo: 'example' } }, require);
    assert.equal(created.length, 1);
    assert.equal((created[0].body.match(/Example finding/g) ?? []).length, 1);
    assert.match(created[0].body, /<!-- antigravity-pr-review:h{40} -->/);

    existingComments = [{ body: created[0].body, id: 99, user: { type: 'Bot' } }];
    await script(github, { repo: { owner: 'f5-sales-demo', repo: 'example' } }, require);
    assert.equal(created.length, 1);
    assert.deepEqual(
      updated.map(({ comment_id }) => comment_id),
      [99],
    );

    process.env.PR_NUMBER = 'not-a-number';
    await assert.rejects(
      script(github, { repo: { owner: 'f5-sales-demo', repo: 'example' } }, require),
      /invalid pull-request number/,
    );
  } finally {
    if (previousReportPath === undefined) delete process.env.REPORT_PATH;
    else process.env.REPORT_PATH = previousReportPath;
    if (previousPullNumber === undefined) delete process.env.PR_NUMBER;
    else process.env.PR_NUMBER = previousPullNumber;
    if (previousWorkspace === undefined) delete process.env.GITHUB_WORKSPACE;
    else process.env.GITHUB_WORKSPACE = previousWorkspace;
  }
}

function runTranslationModel({ missingSecret = false, modelResult = 'success' } = {}) {
  const work = temporaryDirectory('agy-translation-model-');
  const bin = path.join(work, 'bin');
  fs.mkdirSync(bin);
  fs.mkdirSync(path.join(work, 'home'));
  writeSandboxCommandFakes(bin);
  writeExecutable(
    path.join(bin, 'agy'),
    `#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = --version ]; then
  echo 1.1.10
  exit 0
fi
printf '%s\n' "$@" >"$RUNNER_TEMP/translation-arguments"
printf '%s|%s|%s|%s\n' "\${GH_TOKEN:-}" "\${GITHUB_TOKEN:-}" "\${GATEWAY_TOKEN:-}" "\${GATEWAY_URL:-}" >"$RUNNER_TEMP/translation-credentials"
case "\${AGY_MODEL_RESULT:-success}" in
success)
  printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"translations completed"}}'
  ;;
permission-denied)
  printf '{"event":"step_update","step_update":{"state":"DONE","step_type":"tool","tool_info":{"name":"view_file","parameters":{"AbsolutePath":"%s/docs/en/page.mdx"},"output":"read_file permission was auto-denied"}}}\n' "$RUNNER_TEMP"
  printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"no output produced because a read_file permission was denied"}}'
  ;;
permission-recovered)
  printf '{"event":"step_update","step_update":{"state":"DONE","step_type":"tool","tool_info":{"name":"view_file","parameters":{"AbsolutePath":"%s/.git/logs/HEAD"},"output":"read_file permission was auto-denied"}}}\n' "$RUNNER_TEMP"
  printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"translations completed"}}'
  ;;
failed)
  printf '%s\n' '{"event":"result","result":{"status":"ERROR","response":"model execution failed"}}'
  ;;
*)
  printf '%s\n' 'not-json'
  ;;
esac
`,
  );
  const changedEnglish = path.join(work, 'changed-english.txt');
  fs.writeFileSync(changedEnglish, 'docs/en/page.mdx\n');
  const script = extractStepBlock(translationWorkflow, 'Generate translations without write credentials').replace(
    '/opt/agy-translation-contract/run-with-progress.sh',
    path.join(root, 'scripts/run-with-progress.sh'),
  );
  const result = runShell(script, {
    cwd: work,
    env: {
      AGY_VERSION: '1.1.10',
      ANTIGRAVITY_TOKEN: missingSecret ? null : 'go-keyring-base64:dGVzdA==',
      GATEWAY_TOKEN: 'must-not-reach-model',
      GATEWAY_URL: 'must-not-reach-model',
      GCP_PROJECT_ID: 'fixture-project',
      GH_TOKEN: 'must-not-reach-model',
      GITHUB_TOKEN: 'must-not-reach-model',
      GITHUB_WORKSPACE: work,
      HOME: path.join(work, 'home'),
      AGY_MODEL_RESULT: modelResult,
      PATH: `${bin}:${process.env.PATH}`,
      RUNNER_TEMP: work,
    },
  });
  return { result, work };
}

function testTranslationModel() {
  const completed = runTranslationModel();
  assert.equal(completed.result.status, 0, completed.result.stderr);
  const argumentsUsed = fs.readFileSync(path.join(completed.work, 'translation-arguments'), 'utf8');
  for (const argument of [
    '--sandbox',
    '--mode',
    'accept-edits',
    '--disable-slash-commands',
    '--output-format',
    'stream-json',
  ]) {
    assert.match(argumentsUsed, new RegExp(`^${argument}$`, 'm'));
  }
  assert.match(
    argumentsUsed,
    /\/opt\/agy-translation-contract\/changed-english[.]txt/,
    'the translator prompt must use the exact-head manifest copied into its sandbox-readable contract directory',
  );
  assert.match(
    argumentsUsed,
    /\/opt\/agy-translation-contract\/expected-source-hashes[.]tsv/,
    'the translator prompt must use deterministic hashes derived from the exact PR head',
  );
  assert.doesNotMatch(argumentsUsed, /--dangerously-skip-permissions/);
  assert.match(
    argumentsUsed,
    /Use only sandboxed terminal commands for file inspection and updates/,
    'the headless translator must use the already-authorized command route instead of interactive file prompts',
  );
  assert.match(argumentsUsed, /Do not inspect Git metadata/);
  const settings = JSON.parse(
    fs.readFileSync(path.join(completed.work, 'home/.gemini/antigravity-cli/settings.json'), 'utf8'),
  );
  assert.deepEqual(settings.permissions, {
    allow: [
      'command(*)',
      `read_file(${completed.work})`,
      'read_file(/opt/agy-translation-contract)',
      ...locales.map((locale) => `write_file(${completed.work}/docs/${locale})`),
      ...locales.map((locale) => `write_file(${completed.work}/src/content/docs/${locale})`),
    ],
    deny: [
      'unsandboxed(*)',
      'read_url(*)',
      'execute_url(*)',
      'write_file(/opt/agy-translation-contract)',
      `write_file(${completed.work}/docs/en)`,
      `write_file(${completed.work}/src/content/docs/en)`,
      `read_file(${completed.work}/.git)`,
    ],
  });
  assert.equal(
    fs.readFileSync(path.join(completed.work, 'translation-credentials'), 'utf8').trim(),
    '|||',
    'the sandboxed translator must not receive GitHub or gateway credentials',
  );
  const denied = runTranslationModel({ modelResult: 'permission-denied' });
  assert.notEqual(denied.result.status, 0, 'a soft-denied Antigravity tool must fail the model step');
  assert.match(
    fs.readFileSync(path.join(denied.work, 'translation.stream'), 'utf8'),
    /"name":"view_file"/,
    'the diagnostic stream must retain the denied tool metadata',
  );
  assert.match(denied.result.stderr, /model tool=view_file target=.*docs\/en\/page[.]mdx/);
  assert.equal(
    runTranslationModel({ modelResult: 'permission-recovered' }).result.status,
    0,
    'an intermediate denial may recover when the final result and deterministic locale validation succeed',
  );
  assert.notEqual(
    runTranslationModel({ modelResult: 'failed' }).result.status,
    0,
    'a non-success Antigravity result must fail even when the CLI exits zero',
  );
  assert.notEqual(
    runTranslationModel({ modelResult: 'malformed' }).result.status,
    0,
    'malformed Antigravity event streams must fail closed',
  );
  assert.notEqual(runTranslationModel({ missingSecret: true }).result.status, 0);
}

const locales = ['fr', 'es', 'de', 'pt-br', 'ja', 'ko', 'zh-cn', 'zh-tw', 'ar', 'it', 'hi', 'th'];

function writeEnglishSource(repository, suffix) {
  fs.mkdirSync(path.join(repository, 'docs/en'), { recursive: true });
  fs.writeFileSync(path.join(repository, 'docs/en/page.mdx'), `---\ntitle: Page\n---\n\nEnglish body.${suffix}\n`);
}

function writeLocale(repository, locale, sourceHash) {
  const directory = path.join(repository, 'docs', locale);
  fs.mkdirSync(directory, { recursive: true });
  fs.writeFileSync(
    path.join(directory, 'page.mdx'),
    `---\ntitle: Page ${locale}\ni18n:\n  sourceHash: "${sourceHash}"\n  translator: "machine"\n---\n\nTranslated body.\n`,
  );
}

function initializeTranslationFixture() {
  const work = temporaryDirectory('agy-translation-fixture-');
  const repository = path.join(work, 'repository');
  const remote = path.join(work, 'remote.git');
  initializeGitRepository(repository);
  run('git', ['init', '--bare', '-q', remote], { cwd: work });
  writeEnglishSource(repository, '');
  let hash = sha256Prefix(path.join(repository, 'docs/en/page.mdx'));
  for (const locale of locales) writeLocale(repository, locale, hash);
  git(repository, 'add', '.');
  git(repository, 'commit', '-qm', 'base');
  const base = git(repository, 'rev-parse', 'HEAD');
  git(repository, 'remote', 'add', 'origin', remote);
  git(repository, 'push', '-q', 'origin', 'HEAD:refs/heads/main');

  writeEnglishSource(repository, '\nChanged English.');
  git(repository, 'add', 'docs/en/page.mdx');
  git(repository, 'commit', '-qm', 'English update');
  const head = git(repository, 'rev-parse', 'HEAD');
  git(repository, 'push', '-q', 'origin', 'HEAD:refs/heads/feature/1246-uat');
  git(repository, 'push', '-q', 'origin', 'HEAD:refs/pull/42/head');
  hash = sha256Prefix(path.join(repository, 'docs/en/page.mdx'));
  for (const locale of locales) writeLocale(repository, locale, hash);
  return {
    base,
    head,
    hash,
    remote,
    repository,
    pull: {
      base: { sha: base },
      head: {
        ref: 'feature/1246-uat',
        repo: repositoryIdentity(),
        sha: head,
      },
    },
  };
}

function runTranslationPackage(fixture) {
  const runner = temporaryDirectory('agy-translation-package-');
  const script = extractStepBlock(translationWorkflow, 'Validate and package allowlisted translation patch').replace(
    '/opt/agy-translation-contract/validate-translations.sh',
    path.join(root, 'scripts/validate-translations.sh'),
  );
  const result = runShell(script, {
    cwd: fixture.repository,
    env: {
      AGY_VERSION: '1.1.10',
      BASE_SHA: fixture.base,
      GITHUB_REPOSITORY: 'f5-sales-demo/example',
      GITHUB_WORKFLOW_SHA: 'workflow-current',
      HEAD_REF: fixture.pull.head.ref,
      HEAD_SHA: fixture.head,
      RUNNER_TEMP: runner,
    },
  });
  return { fixture, result, runner };
}

function testTranslationPackaging() {
  const completed = runTranslationPackage(initializeTranslationFixture());
  assert.equal(completed.result.status, 0, completed.result.stderr);
  const changedOutput = git(completed.fixture.repository, 'diff', '--cached', '--name-only');
  const changed = changedOutput ? changedOutput.split('\n') : [];
  assert.equal(
    changed.length,
    12,
    `expected 12 staged locales, got:\n${changedOutput}\n${git(completed.fixture.repository, 'status', '--short')}`,
  );
  assert.deepEqual(changed.sort(), locales.map((locale) => `docs/${locale}/page.mdx`).sort());
  const receipt = JSON.parse(fs.readFileSync(path.join(completed.runner, 'translation-artifact/receipt.json'), 'utf8'));
  assert.deepEqual(receipt, {
    agy_version: '1.1.10',
    base_sha: completed.fixture.base,
    head_ref: 'feature/1246-uat',
    head_sha: completed.fixture.head,
    model: 'Gemini 3.6 Flash (High)',
    repository: 'f5-sales-demo/example',
    workflow_sha: 'workflow-current',
  });
  assert.ok(fs.statSync(path.join(completed.runner, 'translation-artifact/translations.patch')).size > 0);

  const missing = initializeTranslationFixture();
  fs.rmSync(path.join(missing.repository, 'docs/th/page.mdx'));
  assert.notEqual(runTranslationPackage(missing).result.status, 0);

  const sourceMutation = initializeTranslationFixture();
  fs.appendFileSync(path.join(sourceMutation.repository, 'docs/en/page.mdx'), '\nUntrusted edit.\n');
  assert.notEqual(runTranslationPackage(sourceMutation).result.status, 0);

  const outside = initializeTranslationFixture();
  fs.writeFileSync(path.join(outside.repository, 'outside.txt'), 'out of scope\n');
  assert.notEqual(runTranslationPackage(outside).result.status, 0);

  const executable = initializeTranslationFixture();
  fs.chmodSync(path.join(executable.repository, 'docs/fr/page.mdx'), 0o755);
  assert.notEqual(runTranslationPackage(executable).result.status, 0);
}

function advanceRemoteHead(fixture) {
  const checkout = path.join(temporaryDirectory('agy-translation-drift-'), 'repository');
  run('git', ['clone', '-q', fixture.remote, checkout]);
  git(checkout, 'config', 'user.email', 'fixture@example.com');
  git(checkout, 'config', 'user.name', 'Fixture');
  git(checkout, 'checkout', '-q', '-B', 'feature/1246-uat', 'origin/feature/1246-uat');
  fs.writeFileSync(path.join(checkout, 'remote-drift.txt'), 'remote drift\n');
  git(checkout, 'add', 'remote-drift.txt');
  git(checkout, 'commit', '-qm', 'remote drift');
  git(checkout, 'push', '-q', 'origin', 'HEAD:refs/heads/feature/1246-uat');
}

function runTranslationPublication(packaged, { missingToken = false, remoteDrift = false } = {}) {
  if (remoteDrift) advanceRemoteHead(packaged.fixture);
  const work = temporaryDirectory('agy-translation-publish-');
  const repository = path.join(work, 'repository');
  const runner = path.join(work, 'runner');
  const artifact = path.join(runner, 'translation-artifact');
  fs.mkdirSync(runner);
  fs.mkdirSync(artifact);
  run('git', ['clone', '-q', packaged.fixture.remote, repository]);
  git(repository, 'checkout', '-q', '--detach', packaged.fixture.head);
  fs.copyFileSync(path.join(packaged.runner, 'translation-artifact/receipt.json'), path.join(artifact, 'receipt.json'));
  fs.copyFileSync(
    path.join(packaged.runner, 'translation-artifact/translations.patch'),
    path.join(artifact, 'translations.patch'),
  );
  const script = extractStepBlock(translationWorkflow, 'Validate, commit, and publish translations').replace(
    '/opt/agy-publication-validator/validate-translations.sh',
    path.join(root, 'scripts/validate-translations.sh'),
  );
  const result = runShell(script, {
    cwd: repository,
    env: {
      AGY_VERSION: '1.1.10',
      BASE_SHA: packaged.fixture.base,
      GH_TOKEN: missingToken ? null : 'fixture-publication-token',
      GITHUB_REPOSITORY: 'f5-sales-demo/example',
      HEAD_SHA: packaged.fixture.head,
      HEAD_REF: packaged.fixture.pull.head.ref,
      PR_NUMBER: '42',
      RUNNER_TEMP: runner,
      WORKFLOW_SHA: 'workflow-current',
    },
  });
  return { repository, result };
}

function testTranslationPublication() {
  const packaged = runTranslationPackage(initializeTranslationFixture());
  assert.equal(packaged.result.status, 0, packaged.result.stderr);
  const published = runTranslationPublication(packaged);
  assert.equal(published.result.status, 0, published.result.stderr);
  const publishedHead = run('git', ['--git-dir', packaged.fixture.remote, 'rev-parse', 'refs/heads/feature/1246-uat']);
  assert.notEqual(publishedHead, packaged.fixture.head);
  assert.equal(
    run('git', ['--git-dir', packaged.fixture.remote, 'log', '-1', '--format=%s', publishedHead]),
    'chore(i18n): update translations via Antigravity',
  );
  const publishedPaths = run('git', [
    '--git-dir',
    packaged.fixture.remote,
    'ls-tree',
    '-r',
    '--name-only',
    publishedHead,
  ])
    .split('\n')
    .filter((file) => /^docs\/(?:fr|es|de|pt-br|ja|ko|zh-cn|zh-tw|ar|it|hi|th)\//.test(file));
  assert.equal(publishedPaths.length, 12);

  const stale = runTranslationPackage(initializeTranslationFixture());
  assert.equal(stale.result.status, 0, stale.result.stderr);
  assert.notEqual(runTranslationPublication(stale, { remoteDrift: true }).result.status, 0);

  const noToken = runTranslationPackage(initializeTranslationFixture());
  assert.equal(noToken.result.status, 0, noToken.result.stderr);
  assert.notEqual(runTranslationPublication(noToken, { missingToken: true }).result.status, 0);
}

const base = 'b'.repeat(40);
const head = 'h'.repeat(40);
const pull = {
  base: { sha: base },
  head: { ref: 'feature/1246-uat', repo: repositoryIdentity(), sha: head },
};

const validReview = validReviewReport({ base, head, workflow: 'workflow-current' });
assert.equal(runReviewReceiptValidation({ report: validReview, pull }).status, 0);
assert.notEqual(
  runReviewReceiptValidation({
    report: validReviewReport({ base, head, workflow: 'workflow-stale' }),
    pull,
  }).status,
  0,
  'review publication must reject a stale workflow receipt',
);
assert.notEqual(
  runReviewReceiptValidation({
    report: validReviewReport({ base: 'c'.repeat(40), head, workflow: 'workflow-current' }),
    pull,
  }).status,
  0,
  'review publication must reject a stale base receipt',
);
assert.notEqual(
  runReviewReceiptValidation({
    report: { ...validReview, receipt: { ...validReview.receipt, agy_version: '9.9.9' } },
    pull,
  }).status,
  0,
  'review publication must reject an unexpected runtime receipt',
);
const forkPull = structuredClone(pull);
forkPull.head.repo.full_name = 'outsider/fork';
assert.notEqual(
  (await runExactHeadValidation(reviewWorkflow, 'Validate exact current head', forkPull)).status,
  0,
  'review publication must reject a fork head',
);

const validTranslation = {
  repository: 'f5-sales-demo/example',
  base_sha: base,
  head_sha: head,
  head_ref: pull.head.ref,
  workflow_sha: 'workflow-current',
  agy_version: '1.1.10',
  model: 'Gemini 3.6 Flash (High)',
};
assert.equal(runTranslationReceiptValidation({ receipt: validTranslation, pull }).status, 0);
assert.notEqual(
  runTranslationReceiptValidation({
    receipt: { ...validTranslation, workflow_sha: 'workflow-stale' },
    pull,
  }).status,
  0,
  'translation publication must reject a stale workflow receipt',
);
assert.notEqual(
  runTranslationReceiptValidation({
    receipt: { ...validTranslation, head_sha: 's'.repeat(40) },
    pull,
  }).status,
  0,
  'translation publication must reject a stale head receipt',
);
assert.notEqual(
  runTranslationReceiptValidation({
    receipt: { ...validTranslation, agy_version: '9.9.9' },
    pull,
  }).status,
  0,
  'translation publication must reject an unexpected runtime receipt',
);
assert.notEqual(
  (await runExactHeadValidation(translationWorkflow, 'Validate exact pull-request head', forkPull)).status,
  0,
  'translation publication must reject a fork head',
);

await testReviewerPreparation();
testNoAppTokenRouting();
testProgressRouting();
testHeadlessKeyringBootstrap();
await testTranslationPreparation();
testPinnedInstallers();
testReviewerModelAndGate();
await testReviewCommentPublication();
testTranslationModel();
testTranslationPackaging();
testTranslationPublication();

console.log('PASS: Antigravity CI feature UAT');
