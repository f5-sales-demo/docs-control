#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');

const modulePath = path.join(__dirname, '..', 'scripts', 'configure-antigravity-controls.cjs');

const locales = ['ar', 'de', 'es', 'fr', 'hi', 'it', 'ja', 'ko', 'pt-br', 'th', 'zh-cn', 'zh-tw'];
const translationHead = '1'.repeat(40);
const reviewHead = '2'.repeat(40);

function githubRepository(fullName, extra = {}) {
  const repository = { ...extra };
  repository.full_name = fullName;
  return repository;
}

function response(status, body, headers = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: {
      get(name) {
        return Object.entries(headers).find(([key]) => key.toLowerCase() === name.toLowerCase())?.[1] ?? null;
      },
    },
    async text() {
      return body === null || body === undefined ? '' : JSON.stringify(body);
    },
  };
}

function createApi({ proofLocaleCount = 12, existing = false, concurrentCreate = false } = {}) {
  const variables = new Map();
  const requests = [];
  if (existing) {
    variables.set('ANTIGRAVITY_REVIEW_ENABLED', {
      name: 'ANTIGRAVITY_REVIEW_ENABLED',
      value: 'true',
      visibility: 'selected',
      selected_repository_ids: [42],
    });
    variables.set('TRANSLATIONS_ENABLED', {
      name: 'TRANSLATIONS_ENABLED',
      value: 'true',
      visibility: 'selected',
      selected_repository_ids: [42],
    });
  }

  const fetch = async (url, options = {}) => {
    const parsed = new URL(url);
    const endpoint = `${parsed.pathname}${parsed.search}`;
    const method = options.method ?? 'GET';
    const body = options.body ? JSON.parse(options.body) : undefined;
    requests.push({ endpoint, method, body });

    if (method === 'GET' && parsed.pathname === '/repos/example/docs-control') {
      return response(
        200,
        githubRepository('example/docs-control', {
          id: 42,
          name: 'docs-control',
          owner: { login: 'example' },
        }),
      );
    }

    const selectedMatch = parsed.pathname.match(/^\/orgs\/example\/actions\/variables\/([^/]+)\/repositories$/);
    if (method === 'GET' && selectedMatch) {
      const variable = variables.get(selectedMatch[1]);
      const selected = variable?.visibility === 'selected' ? [{ id: 42, name: 'docs-control' }] : [];
      return response(200, { total_count: selected.length, repositories: selected });
    }

    const variableMatch = parsed.pathname.match(/^\/orgs\/example\/actions\/variables\/([^/]+)$/);
    if (method === 'GET' && variableMatch) {
      const variable = variables.get(variableMatch[1]);
      return variable ? response(200, variable) : response(404, { message: 'Not Found' });
    }
    if (method === 'PATCH' && variableMatch) {
      if (!variables.has(variableMatch[1])) return response(404, { message: 'Not Found' });
      variables.set(variableMatch[1], { ...body });
      return response(204, null);
    }
    if (method === 'POST' && parsed.pathname === '/orgs/example/actions/variables') {
      if (variables.has(body.name)) return response(422, { message: 'Variable already exists' });
      variables.set(body.name, { ...body });
      if (concurrentCreate) return response(422, { message: 'Variable already exists' });
      return response(201, null);
    }

    if (method === 'GET' && parsed.pathname === '/repos/example/docs-control/pulls/7') {
      return response(200, {
        number: 7,
        state: 'open',
        base: { ref: 'main', repo: githubRepository('example/docs-control') },
        head: { sha: reviewHead, repo: githubRepository('example/docs-control') },
      });
    }

    const runMatch = parsed.pathname.match(/^\/repos\/example\/docs-control\/actions\/runs\/(101|102)$/);
    if (method === 'GET' && runMatch) {
      const review = runMatch[1] === '101';
      return response(200, {
        id: Number(runMatch[1]),
        event: 'workflow_dispatch',
        status: 'completed',
        conclusion: 'success',
        path: review ? '.github/workflows/antigravity-review.yml' : '.github/workflows/antigravity-translate.yml',
        display_title: review
          ? `Antigravity review PR 7 @ ${reviewHead}`
          : `Antigravity translation PR 7 @ ${translationHead}`,
        repository: githubRepository('example/docs-control'),
        head_repository: githubRepository('example/docs-control'),
      });
    }

    const jobsMatch = parsed.pathname.match(/^\/repos\/example\/docs-control\/actions\/runs\/(101|102)\/jobs$/);
    if (method === 'GET' && jobsMatch) {
      const review = jobsMatch[1] === '101';
      const names = review
        ? ['PR review with Antigravity', 'Publish exact-head review']
        : ['Generate isolated translations', 'Publish exact-head translations'];
      return response(200, {
        total_count: 2,
        jobs: names.map((name) => ({ name, status: 'completed', conclusion: 'success' })),
      });
    }

    const artifactsMatch = parsed.pathname.match(
      /^\/repos\/example\/docs-control\/actions\/runs\/(101|102)\/artifacts$/,
    );
    if (method === 'GET' && artifactsMatch) {
      const review = artifactsMatch[1] === '101';
      return response(200, {
        total_count: 1,
        artifacts: [
          {
            expired: false,
            name: review ? `antigravity-review-${reviewHead}` : `antigravity-translation-${translationHead}`,
          },
        ],
      });
    }

    if (method === 'GET' && parsed.pathname === '/repos/example/docs-control/issues/7/comments') {
      return response(200, [
        {
          user: { type: 'Bot' },
          body: `<!-- antigravity-pr-review:${reviewHead} -->\n## Antigravity PR review`,
        },
      ]);
    }

    if (
      method === 'GET' &&
      parsed.pathname === `/repos/example/docs-control/compare/${translationHead}...${reviewHead}`
    ) {
      return response(200, {
        status: 'ahead',
        ahead_by: 1,
        commits: [{ commit: { message: 'chore(i18n): update translations via Antigravity' } }],
        files: locales.slice(0, proofLocaleCount).map((locale) => ({
          filename: `docs/${locale}/automation-pilot.mdx`,
          status: 'modified',
        })),
      });
    }

    return response(500, { message: `unexpected ${method} ${endpoint}` });
  };

  return { fetch, requests, variables };
}

function options(api, phase, overrides = {}) {
  return {
    phase,
    organization: 'example',
    pilotRepository: 'docs-control',
    token: 'synthetic-token',
    fetch: api.fetch,
    jitterSeconds: 0,
    sleepSeconds: async () => {},
    onProgress: () => {},
    ...overrides,
  };
}

(async () => {
  const { configureOrganizationControls, validatePilotProof } = require(modulePath);

  const pilotApi = createApi();
  const pilot = await configureOrganizationControls(options(pilotApi, 'pilot'));
  assert.deepEqual(pilot, {
    phase: 'pilot',
    value: 'true',
    visibility: 'selected',
    selectedRepositories: ['docs-control'],
  });
  for (const name of ['ANTIGRAVITY_REVIEW_ENABLED', 'TRANSLATIONS_ENABLED']) {
    assert.deepEqual(pilotApi.variables.get(name), {
      name,
      value: 'true',
      visibility: 'selected',
      selected_repository_ids: [42],
    });
  }
  assert.equal(
    pilotApi.requests.filter(({ method }) => method === 'POST').length,
    2,
    'missing organization variables must be created exactly once',
  );

  await configureOrganizationControls(options(pilotApi, 'pilot'));
  assert.equal(
    pilotApi.requests.filter(({ method }) => method === 'PATCH').length,
    0,
    'a repeated pilot transition must be an idempotent no-op',
  );

  const concurrentApi = createApi({ concurrentCreate: true });
  const concurrent = await configureOrganizationControls(options(concurrentApi, 'pilot'));
  assert.equal(concurrent.phase, 'pilot');
  assert.equal(concurrentApi.variables.size, 2);
  assert.equal(
    concurrentApi.requests.filter(({ method }) => method === 'POST').length,
    2,
    'a concurrent create race must converge without duplicate mutation retries',
  );

  const disabledApi = createApi({ existing: true });
  const disabled = await configureOrganizationControls(options(disabledApi, 'disabled'));
  assert.equal(disabled.value, 'false');
  assert.equal(disabled.visibility, 'all');
  for (const variable of disabledApi.variables.values()) {
    assert.equal(variable.value, 'false');
    assert.equal(variable.visibility, 'all');
    assert.equal('selected_repository_ids' in variable, false);
  }

  const missingProofApi = createApi({ existing: true });
  await assert.rejects(configureOrganizationControls(options(missingProofApi, 'all')), /pilot proof is required/);
  assert.equal(
    missingProofApi.requests.some(({ method }) => ['POST', 'PATCH'].includes(method)),
    false,
    'all visibility must fail before any mutation when pilot evidence is absent',
  );

  const proof = {
    pullRequestNumber: 7,
    reviewRunId: 101,
    translationRunId: 102,
    reviewHeadSha: reviewHead,
    translationHeadSha: translationHead,
  };
  const allApi = createApi({ existing: true });
  const proofResult = await validatePilotProof(options(allApi, 'all', { pilotProof: proof }));
  assert.deepEqual(proofResult.locales, locales);
  assert.equal(proofResult.outputCount, 12);
  const all = await configureOrganizationControls(options(allApi, 'all', { pilotProof: proof }));
  assert.equal(all.value, 'true');
  assert.equal(all.visibility, 'all');
  for (const variable of allApi.variables.values()) {
    assert.equal(variable.value, 'true');
    assert.equal(variable.visibility, 'all');
  }

  const incompleteApi = createApi({ existing: true, proofLocaleCount: 11 });
  await assert.rejects(
    configureOrganizationControls(options(incompleteApi, 'all', { pilotProof: proof })),
    /exactly 12 locale outputs/,
  );
  assert.equal(
    incompleteApi.requests.some(({ method }) => ['POST', 'PATCH'].includes(method)),
    false,
    'incomplete locale evidence must fail before organization-variable mutation',
  );

  await assert.rejects(
    configureOrganizationControls(options(createApi(), 'unknown')),
    /phase must be one of disabled, pilot, all/,
  );

  const limitedFetch = async () =>
    response(403, { message: 'You have exceeded a secondary rate limit' }, { 'Retry-After': '120' });
  await assert.rejects(
    configureOrganizationControls({
      ...options({ fetch: limitedFetch }, 'disabled'),
      totalWaitBudgetSeconds: 60,
    }),
    (error) => error?.code === 84 && error?.kind === 'secondary',
  );

  console.log('[OK] Antigravity control phase transitions and pilot proof');
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
