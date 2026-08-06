#!/usr/bin/env node
'use strict';

const { requestGitHubApi } = require('./github-api-resilience.cjs');

const CONTROL_NAMES = ['ANTIGRAVITY_REVIEW_ENABLED', 'TRANSLATIONS_ENABLED'];
const REQUIRED_LOCALES = ['ar', 'de', 'es', 'fr', 'hi', 'it', 'ja', 'ko', 'pt-br', 'th', 'zh-cn', 'zh-tw'];
const PHASES = {
  disabled: { value: 'false', visibility: 'all' },
  pilot: { value: 'true', visibility: 'selected' },
  all: { value: 'true', visibility: 'all' },
};

function validSlug(value) {
  return typeof value === 'string' && /^[A-Za-z0-9_.-]+$/.test(value);
}

function positiveInteger(value, label) {
  if (!/^\d+$/.test(String(value ?? ''))) throw new Error(`${label} must be a positive integer`);
  const result = Number(value);
  if (!Number.isSafeInteger(result) || result < 1) throw new Error(`${label} must be a positive integer`);
  return result;
}

function sha(value, label) {
  if (!/^[0-9a-f]{40}$/.test(value ?? '')) throw new Error(`${label} must be a full commit SHA`);
  return value;
}

function requestOptions(options, overrides = {}) {
  return {
    token: options.token,
    fetch: options.fetch,
    maxAttempts: options.maxAttempts,
    totalWaitBudgetSeconds: options.totalWaitBudgetSeconds,
    sleepSeconds: options.sleepSeconds,
    nowSeconds: options.nowSeconds,
    jitterSeconds: options.jitterSeconds,
    random: options.random,
    onProgress: options.onProgress,
    ...overrides,
  };
}

function progress(options, message) {
  const output = options.onStatus ?? ((line) => console.error(line));
  output(`[PROGRESS] antigravity-controls ${message}`);
}

async function api(endpoint, options, overrides = {}) {
  return requestGitHubApi(endpoint, requestOptions(options, overrides));
}

function normalizeProof(proof) {
  if (!proof) throw new Error('pilot proof is required before phase all');
  return {
    pullRequestNumber: positiveInteger(proof.pullRequestNumber, 'pilot pull-request number'),
    reviewRunId: positiveInteger(proof.reviewRunId, 'pilot review run ID'),
    translationRunId: positiveInteger(proof.translationRunId, 'pilot translation run ID'),
    reviewHeadSha: sha(proof.reviewHeadSha, 'pilot review head SHA'),
    translationHeadSha: sha(proof.translationHeadSha, 'pilot translation head SHA'),
  };
}

function assertRun(run, expected) {
  const expectedTitle = `${expected.titlePrefix} PR ${expected.pullRequestNumber} @ ${expected.headSha}`;
  if (
    run?.id !== expected.runId ||
    run?.event !== 'workflow_dispatch' ||
    run?.status !== 'completed' ||
    run?.conclusion !== 'success' ||
    run?.path !== expected.path ||
    run?.display_title !== expectedTitle ||
    run?.repository?.full_name !== expected.repository ||
    run?.head_repository?.full_name !== expected.repository
  ) {
    throw new Error(`${expected.label} is not a successful trusted same-repository dispatch`);
  }
}

function assertSuccessfulJobs(payload, expectedNames, label) {
  if (!Array.isArray(payload?.jobs)) throw new Error(`${label} returned a malformed job inventory`);
  const matching = payload.jobs.filter((job) => expectedNames.includes(job?.name));
  if (
    matching.length !== expectedNames.length ||
    expectedNames.some(
      (name) =>
        !matching.some((job) => job.name === name && job.status === 'completed' && job.conclusion === 'success'),
    )
  ) {
    throw new Error(`${label} did not execute every required Antigravity job successfully`);
  }
}

function assertArtifact(payload, expectedName, label) {
  if (
    !Array.isArray(payload?.artifacts) ||
    !payload.artifacts.some((artifact) => artifact?.name === expectedName && artifact.expired === false)
  ) {
    throw new Error(`${label} exact-head receipt artifact is absent or expired`);
  }
}

async function validatePilotProof(options = {}) {
  if (!options.token) throw new Error('GitHub API token is required');
  if (!validSlug(options.organization)) throw new Error('organization is invalid');
  if (!validSlug(options.pilotRepository)) throw new Error('pilot repository is invalid');
  const proof = normalizeProof(options.pilotProof);
  const repository = `${options.organization}/${options.pilotRepository}`;
  const pullEndpoint = `repos/${repository}/pulls/${proof.pullRequestNumber}`;

  progress(options, `phase=all state=validating-pilot repository=${repository}`);
  const pull = await api(pullEndpoint, options, {
    operationName: `validate Antigravity pilot pull request ${repository}#${proof.pullRequestNumber}`,
  });
  if (
    pull?.number !== proof.pullRequestNumber ||
    pull?.state !== 'open' ||
    pull?.base?.ref !== 'main' ||
    pull?.base?.repo?.full_name !== repository ||
    pull?.head?.repo?.full_name !== repository ||
    pull?.head?.sha !== proof.reviewHeadSha
  ) {
    throw new Error('pilot pull request no longer matches the trusted exact review head');
  }

  const reviewRun = await api(`repos/${repository}/actions/runs/${proof.reviewRunId}`, options, {
    operationName: `read Antigravity pilot review run ${proof.reviewRunId}`,
  });
  assertRun(reviewRun, {
    label: 'pilot review run',
    runId: proof.reviewRunId,
    path: '.github/workflows/antigravity-review.yml',
    titlePrefix: 'Antigravity review',
    pullRequestNumber: proof.pullRequestNumber,
    headSha: proof.reviewHeadSha,
    repository,
  });

  const translationRun = await api(`repos/${repository}/actions/runs/${proof.translationRunId}`, options, {
    operationName: `read Antigravity pilot translation run ${proof.translationRunId}`,
  });
  assertRun(translationRun, {
    label: 'pilot translation run',
    runId: proof.translationRunId,
    path: '.github/workflows/antigravity-translate.yml',
    titlePrefix: 'Antigravity translation',
    pullRequestNumber: proof.pullRequestNumber,
    headSha: proof.translationHeadSha,
    repository,
  });

  const reviewJobs = await api(`repos/${repository}/actions/runs/${proof.reviewRunId}/jobs?per_page=100`, options, {
    operationName: `validate Antigravity pilot review jobs ${proof.reviewRunId}`,
  });
  assertSuccessfulJobs(reviewJobs, ['PR review with Antigravity', 'Publish exact-head review'], 'pilot review run');

  const translationJobs = await api(
    `repos/${repository}/actions/runs/${proof.translationRunId}/jobs?per_page=100`,
    options,
    { operationName: `validate Antigravity pilot translation jobs ${proof.translationRunId}` },
  );
  assertSuccessfulJobs(
    translationJobs,
    ['Generate isolated translations', 'Publish exact-head translations'],
    'pilot translation run',
  );

  const reviewArtifacts = await api(
    `repos/${repository}/actions/runs/${proof.reviewRunId}/artifacts?per_page=100`,
    options,
    { operationName: `validate Antigravity pilot review receipt ${proof.reviewRunId}` },
  );
  assertArtifact(reviewArtifacts, `antigravity-review-${proof.reviewHeadSha}`, 'pilot review');

  const translationArtifacts = await api(
    `repos/${repository}/actions/runs/${proof.translationRunId}/artifacts?per_page=100`,
    options,
    { operationName: `validate Antigravity pilot translation receipt ${proof.translationRunId}` },
  );
  assertArtifact(translationArtifacts, `antigravity-translation-${proof.translationHeadSha}`, 'pilot translation');

  const comments = await api(`repos/${repository}/issues/${proof.pullRequestNumber}/comments?per_page=100`, options, {
    paginate: true,
    operationName: `validate Antigravity pilot review marker ${proof.reviewHeadSha}`,
  });
  const marker = `<!-- antigravity-pr-review:${proof.reviewHeadSha} -->`;
  if (
    !Array.isArray(comments) ||
    !comments.some((comment) => comment?.user?.type === 'Bot' && comment?.body?.includes(marker))
  ) {
    throw new Error('pilot review exact-head publication marker is absent');
  }

  const comparison = await api(
    `repos/${repository}/compare/${proof.translationHeadSha}...${proof.reviewHeadSha}`,
    options,
    { operationName: `validate 12-locale Antigravity pilot publication ${proof.reviewHeadSha}` },
  );
  if (
    comparison?.status !== 'ahead' ||
    comparison?.ahead_by !== 1 ||
    !Array.isArray(comparison?.commits) ||
    comparison.commits.length !== 1 ||
    comparison.commits[0]?.commit?.message !== 'chore(i18n): update translations via Antigravity'
  ) {
    throw new Error('pilot translation publication is not the single guarded Antigravity commit');
  }
  if (!Array.isArray(comparison?.files) || comparison.files.length !== REQUIRED_LOCALES.length) {
    throw new Error('pilot publication must contain exactly 12 locale outputs');
  }
  const outputPattern = new RegExp(`^(docs|src/content/docs)/(${REQUIRED_LOCALES.join('|')})/(.+\\.mdx?)$`);
  const outputs = comparison.files.map((file) => {
    if (!['added', 'modified'].includes(file?.status)) return undefined;
    return outputPattern.exec(file?.filename ?? '');
  });
  if (outputs.some((match) => !match)) {
    throw new Error('pilot publication contains a path outside the 12 locale outputs');
  }
  const roots = new Set(outputs.map((match) => match[1]));
  const foundLocales = [...new Set(outputs.map((match) => match[2]))].sort();
  const relativePaths = new Set(outputs.map((match) => match[3]));
  if (
    roots.size !== 1 ||
    relativePaths.size !== 1 ||
    foundLocales.length !== REQUIRED_LOCALES.length ||
    foundLocales.some((locale, index) => locale !== REQUIRED_LOCALES[index])
  ) {
    throw new Error('pilot publication must contain one corresponding output for every required locale');
  }

  progress(options, `phase=all state=pilot-validated outputs=${foundLocales.length}`);
  return {
    pullRequestNumber: proof.pullRequestNumber,
    reviewHeadSha: proof.reviewHeadSha,
    translationHeadSha: proof.translationHeadSha,
    outputCount: foundLocales.length,
    locales: foundLocales,
  };
}

async function readVariable(name, options) {
  try {
    return await api(`orgs/${options.organization}/actions/variables/${name}`, options, {
      operationName: `read organization variable ${name}`,
    });
  } catch (error) {
    if (error?.status === 404) return undefined;
    throw error;
  }
}

async function selectedRepositories(name, options) {
  const payload = await api(
    `orgs/${options.organization}/actions/variables/${name}/repositories?per_page=100`,
    options,
    { operationName: `read selected repositories for ${name}` },
  );
  if (!Array.isArray(payload?.repositories)) {
    throw new Error(`${name} selected-repository response is malformed`);
  }
  return payload.repositories;
}

async function exactVariableState(name, desired, options) {
  const current = await readVariable(name, options);
  if (current?.name !== name || current?.value !== desired.value || current?.visibility !== desired.visibility) {
    return false;
  }
  if (desired.visibility !== 'selected') return true;
  const repositories = await selectedRepositories(name, options);
  return (
    repositories.length === 1 &&
    repositories[0]?.id === desired.selected_repository_ids[0] &&
    repositories[0]?.name === options.pilotRepository
  );
}

async function upsertVariable(name, desired, options) {
  if (await exactVariableState(name, desired, options)) {
    progress(options, `phase=${options.phase} variable=${name} state=unchanged`);
    return;
  }
  const existing = await readVariable(name, options);
  const body = { name, ...desired };
  if (existing) {
    progress(options, `phase=${options.phase} variable=${name} state=updating`);
    await api(`orgs/${options.organization}/actions/variables/${name}`, options, {
      method: 'PATCH',
      body,
      operationName: `update organization variable ${name}`,
    });
  } else {
    progress(options, `phase=${options.phase} variable=${name} state=creating`);
    try {
      await api(`orgs/${options.organization}/actions/variables`, options, {
        method: 'POST',
        body,
        operationName: `create organization variable ${name}`,
        recover: async () => {
          if (await exactVariableState(name, desired, options)) return { recovered: true };
          return undefined;
        },
      });
    } catch (error) {
      if (error?.status !== 422 || !(await exactVariableState(name, desired, options))) throw error;
      progress(options, `phase=${options.phase} variable=${name} state=concurrent-create-recovered`);
    }
  }
  if (!(await exactVariableState(name, desired, options))) {
    throw new Error(`${name} did not converge to the requested organization control state`);
  }
  progress(options, `phase=${options.phase} variable=${name} state=verified`);
}

async function configureOrganizationControls(options = {}) {
  const phase = options.phase;
  if (!Object.hasOwn(PHASES, phase)) throw new Error('phase must be one of disabled, pilot, all');
  if (!options.token) throw new Error('GitHub API token is required');
  if (!validSlug(options.organization)) throw new Error('organization is invalid');
  if (!validSlug(options.pilotRepository)) throw new Error('pilot repository is invalid');

  if (phase === 'all') await validatePilotProof(options);

  const desired = { ...PHASES[phase] };
  let selectedRepositoriesResult = [];
  if (phase === 'pilot') {
    progress(options, `phase=pilot state=resolving repository=${options.pilotRepository}`);
    const repository = await api(`repos/${options.organization}/${options.pilotRepository}`, options, {
      operationName: `resolve selected pilot repository ${options.pilotRepository}`,
    });
    if (
      !Number.isSafeInteger(repository?.id) ||
      repository.id < 1 ||
      repository?.full_name !== `${options.organization}/${options.pilotRepository}`
    ) {
      throw new Error('GitHub returned an invalid selected pilot repository');
    }
    desired.selected_repository_ids = [repository.id];
    selectedRepositoriesResult = [options.pilotRepository];
  }

  for (const name of CONTROL_NAMES) await upsertVariable(name, desired, { ...options, phase });

  progress(options, `phase=${phase} state=complete visibility=${desired.visibility}`);
  return {
    phase,
    value: desired.value,
    visibility: desired.visibility,
    selectedRepositories: selectedRepositoriesResult,
  };
}

function proofFromEnvironment(environment) {
  const values = [
    environment.PILOT_PR_NUMBER,
    environment.PILOT_REVIEW_RUN_ID,
    environment.PILOT_TRANSLATION_RUN_ID,
    environment.PILOT_REVIEW_HEAD_SHA,
    environment.PILOT_TRANSLATION_HEAD_SHA,
  ];
  if (values.every((value) => !value)) return undefined;
  return {
    pullRequestNumber: environment.PILOT_PR_NUMBER,
    reviewRunId: environment.PILOT_REVIEW_RUN_ID,
    translationRunId: environment.PILOT_TRANSLATION_RUN_ID,
    reviewHeadSha: environment.PILOT_REVIEW_HEAD_SHA,
    translationHeadSha: environment.PILOT_TRANSLATION_HEAD_SHA,
  };
}

module.exports = {
  CONTROL_NAMES,
  PHASES,
  REQUIRED_LOCALES,
  configureOrganizationControls,
  validatePilotProof,
};

async function main(argv, environment) {
  const waitBudget = environment.CONTROL_WAIT_BUDGET_SECONDS ?? '900';
  if (!/^\d+$/.test(waitBudget)) {
    throw new Error('CONTROL_WAIT_BUDGET_SECONDS must be a non-negative integer');
  }
  const result = await configureOrganizationControls({
    phase: argv[0],
    organization: environment.GITHUB_ORGANIZATION ?? 'f5-sales-demo',
    pilotRepository: environment.PILOT_REPOSITORY ?? 'docs-control',
    pilotProof: proofFromEnvironment(environment),
    token: environment.GH_TOKEN || environment.GITHUB_TOKEN,
    totalWaitBudgetSeconds: Number(waitBudget),
  });
  console.log(`[OK] Antigravity controls configured ${JSON.stringify(result)}`);
}

if (require.main === module) {
  main(process.argv.slice(2), process.env).catch((error) => {
    console.error(`[ERROR] ${error.message}`);
    process.exitCode = error?.code === 84 ? 84 : 1;
  });
}
