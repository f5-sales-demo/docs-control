#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
node - "$root/scripts/fleet-reconciler.cjs" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {ACTIVE_PR_LIMIT, ApiQueue, aggregateProtection, assertAttestableRecovery, branchName, closeMergedReconciliationIssues, contentDiff, currentProtection, desiredEntries, desiredProtection, managedCommitMessage, manifestStateDigest, parseSelection, reconcileContent, reconciliationBranchPrefix, requireSha, settingsDelta, validateManifest} = require(process.argv[2]);
(async () => {
const sha = 'a'.repeat(40);
const makeManifest = (files, absent_paths = []) => ({schema_version:2,source_commit:sha,files,absent_paths,state_digest:manifestStateDigest(files,absent_paths)});
assert.equal(manifestStateDigest([{path:'a',src:'a',sha,size:1,mode:'100644'}], ['retired']), 'sha256:47c0b77c8b70000308f8bea71916953a269e66b98a35361ed8c6382b554149a4');
assert.equal(requireSha(sha), sha);
assert.equal(managedCommitMessage(sha), `chore: reconcile governed files @ ${sha.slice(0,12)}`);
assert.match(
  branchName(sha, 'one'),
  new RegExp(`^governance/sync-managed-files-${sha.slice(0, 12)}-[1-9][0-9]*-1$`),
);
assert.equal(branchName(sha, 'one', 'governance/bootstrap'), `governance/bootstrap-${sha.slice(0,12)}-one`);
assert.equal(reconciliationBranchPrefix('governance/bootstrap'), 'governance/bootstrap');
assert.match(
  branchName(sha, 'one', 'governance/sync-managed-files'),
  new RegExp(`^governance/sync-managed-files-${sha.slice(0, 12)}-[1-9][0-9]*-1$`),
);
assert.equal(reconciliationBranchPrefix('governance/sync-managed-files'), 'governance/sync-managed-files');
assert.throws(() => reconciliationBranchPrefix('bootstrap/reconcile'), /prefix is invalid/);
assert.throws(() => requireSha('short'));
assert.deepEqual(parseSelection('one,two', ['one', 'two']), ['one', 'two']);
assert.throws(() => parseSelection('missing', ['one']));
const config = {managed_files:{files:[{src:'a',dest:'a'},{src:'b',dest:'b',only_repos:['one']}],absent_files:['retired'],skip_files:{two:['a']}}};
const manifest = makeManifest([{path:'a',src:'a',sha,size:1,mode:'100644'},{path:'b',src:'b',sha:'b'.repeat(40),size:1,mode:'100755'}], ['retired']);
assert.deepEqual(desiredEntries(config, manifest, 'one').files.map(x => x.path), ['a','b']);
assert.deepEqual(desiredEntries(config, manifest, 'two').files.map(x => x.path), []);
assert.throws(() => validateManifest(config, {...manifest,state_digest:`sha256:${'0'.repeat(64)}`}), /state digest/);
assert.throws(() => validateManifest(config, {...manifest,absent_paths:[]}), /configuration and manifest/);
assert.throws(() => validateManifest(config, makeManifest(manifest.files, ['a','retired'])), /sorted and unique/);
assert.deepEqual(contentDiff({tree:[{path:'a',type:'blob',sha:'c'.repeat(40),mode:'100644'},{path:'retired',type:'blob',sha:sha,mode:'100644'}]}, desiredEntries(config, manifest, 'one')).map(x => x.action), ['upsert','upsert','delete']);
assert.deepEqual(settingsDelta({has_issues:true,has_wiki:true}, {has_issues:true,has_wiki:false}), {has_wiki:false});
const protection = desiredProtection({branch_protection:[{branch:'main',enforce_admins:true,required_status_checks:{strict:true,contexts:['lint / Lint'],self_contexts:['Lint']},required_pull_request_reviews:null,restrictions:null,required_linear_history:false,allow_force_pushes:false,allow_deletions:false,block_creations:false,required_conversation_resolution:false,lock_branch:false,allow_fork_syncing:false}],repo_overrides:{one:{additional_contexts:['Extra']}}}, 'one');
assert.deepEqual(protection.required_status_checks.contexts, []);
assert.deepEqual(protection.required_status_checks.checks, [{context:'Extra',app_id:-1},{context:'lint / Lint',app_id:-1}]);
const attestedProtection = desiredProtection({branch_protection:[{branch:'main',enforce_admins:true,required_status_checks:{strict:true,contexts:['Check linked issues','lint / Lint Code Base','lint / Shell Unit Tests']},required_pull_request_reviews:null,restrictions:null}]}, 'one');
assert.deepEqual(attestedProtection.required_status_checks.checks, [{context:'Check linked issues',app_id:-1},{context:'lint / Lint Code Base',app_id:-1},{context:'lint / Shell Unit Tests',app_id:-1}]);
const canonicalSettings = JSON.parse(fs.readFileSync(path.join(path.dirname(process.argv[2]), '..', '.github/config/repo-settings.json'), 'utf8'));
const xcshProtection = desiredProtection(canonicalSettings, 'xcsh');
assert.deepEqual(xcshProtection.required_status_checks.checks, [
  {context:'Check linked issues',app_id:-1}, {context:'lint / Lint Code Base',app_id:-1}, {context:'lint / Shell Unit Tests',app_id:-1},
]);
const mixedCaseProtection = desiredProtection({branch_protection:[{branch:'main',required_status_checks:{strict:true,contexts:['Python test suite','lint / Lint Code Base']}}]}, 'one');
assert.deepEqual(mixedCaseProtection.required_status_checks.checks.map(x => x.context), ['lint / Lint Code Base','Python test suite']);
assert.deepEqual(aggregateProtection(attestedProtection).required_status_checks, {strict:true,contexts:['Check linked issues','lint / Lint Code Base','lint / Shell Unit Tests']});
assert.equal(currentProtection({enforce_admins:{enabled:true},required_status_checks:{strict:true,contexts:['Extra','Lint']},required_pull_request_reviews:null,restrictions:null,required_linear_history:{enabled:false},allow_force_pushes:{enabled:false},allow_deletions:{enabled:false},block_creations:{enabled:false},required_conversation_resolution:{enabled:false},lock_branch:{enabled:false},allow_fork_syncing:{enabled:false}}).enforce_admins, true);
assert.deepEqual(currentProtection({required_status_checks:{strict:true,checks:[{context:'lint / Lint',app_id:-1}]},required_pull_request_reviews:null,restrictions:null}).required_status_checks, {strict:true,contexts:[],checks:[{context:'lint / Lint',app_id:-1}]});
assert.equal(currentProtection({enforce_admins:{enabled:true},required_status_checks:null,required_pull_request_reviews:null,restrictions:{users:[],teams:[],apps:[]}}).restrictions, null);
assert.deepEqual(currentProtection({enforce_admins:{enabled:true},required_status_checks:null,required_pull_request_reviews:null,restrictions:{users:[{login:'alice'}],teams:[],apps:[]}}).restrictions, {users:['alice'],teams:[],apps:[]});
assert.equal(ACTIVE_PR_LIMIT, 2);
const recovery = {pr:{base:{ref:'main'},body:'marker\n\nCloses #1'},note:'marker',changes:[{path:'a'}],files:[{filename:'a'}],headTree:{tree:[{path:'a',type:'blob',sha,mode:'100644'}]},desired:{files:[{path:'a',sha,mode:'100644'}],deletes:[]}};
assert.doesNotThrow(() => assertAttestableRecovery(recovery));
assert.throws(() => assertAttestableRecovery({...recovery,pr:{base:{ref:'main'},body:'marker'}}), /metadata/);
assert.throws(() => assertAttestableRecovery({...recovery,files:[{filename:'a'},{filename:'unmanaged'}]}), /unexpected paths/);
assert.throws(() => assertAttestableRecovery({...recovery,headTree:{tree:[]}}), /desired managed tree/);
const renameRecovery = {
  ...recovery,
  changes:[{path:'old.py'},{path:'new.py'}],
  files:[{filename:'new.py',status:'renamed',previous_filename:'old.py'}],
  headTree:{tree:[{path:'new.py',type:'blob',sha,mode:'100644'}]},
  desired:{files:[{path:'new.py',sha,mode:'100644'}],deletes:['old.py']},
};
assert.doesNotThrow(() => assertAttestableRecovery(renameRecovery));
assert.throws(() => assertAttestableRecovery({...renameRecovery,files:[{filename:'new.py',status:'renamed'}]}), /unexpected paths/);
const calls=[]; const headers=[]; let now=0; const api = new ApiQueue({token:'x', now:()=>now, sleep:async(ms)=>{calls.push(ms); now += ms;}, fetch:async(_url, request)=>{headers.push(request.headers); return new Response('{}',{status:200,headers:{etag:'"fleet"'}});}});
await api.request('one',{method:'POST'}); now=10; await api.request('two',{method:'PATCH'}); assert.deepEqual(calls,[990]);
await api.request('read'); await api.request('read'); assert.equal(headers.at(-1)['if-none-match'], '"fleet"');
const trackerWrites=[];
const trackerApi={request:async(route, options={})=>{
  if (options.method === 'PATCH') { trackerWrites.push({route,body:options.body}); return {number:12}; }
  if (route.includes('/issues?')) return [{number:12,title:`Governance reconciliation @ ${sha.slice(0,12)}`,body:`<!-- governance-reconciler source=${sha} desired-tree=${'d'.repeat(64)} -->`,pull_request:null}];
  if (route.includes('/pulls?')) return [{number:13,merged_at:'2026-09-01T00:00:00Z',base:{ref:'main'},head:{ref:`governance/reconcile-${sha.slice(0,12)}-one`},body:`<!-- governance-reconciler source=${sha} desired-tree=${'d'.repeat(64)} -->\n\nCloses #12`}];
  throw new Error(`unexpected route ${route}`);
}};
assert.deepEqual(await closeMergedReconciliationIssues(trackerApi,'f5','one','full'),[{issue:12,pull:13,status:'closed'}]);
assert.deepEqual(trackerWrites,[{route:'repos/f5/one/issues/12',body:{state:'closed',state_reason:'completed'}}]);
trackerWrites.length=0;
assert.deepEqual(await closeMergedReconciliationIssues(trackerApi,'f5','one','dry-run'),[{issue:12,pull:13,status:'would-close'}]);
assert.deepEqual(trackerWrites,[]);
const unmergedApi={request:async(route)=>route.includes('/issues?') ? [{number:12,title:`Governance reconciliation @ ${sha.slice(0,12)}`,body:`<!-- governance-reconciler source=${sha} desired-tree=${'d'.repeat(64)} -->`}] : [{number:13,merged_at:null,base:{ref:'main'},head:{ref:`governance/reconcile-${sha.slice(0,12)}-one`},body:`Closes #12`} ]};
assert.deepEqual(await closeMergedReconciliationIssues(unmergedApi,'f5','one','full'),[]);
const writes=[];
const fleetApi = new ApiQueue({token:'x', sleep:async()=>{}, now:()=>Number.MAX_SAFE_INTEGER, fetch:async(url, request) => {
  const route = String(url); const method = request.method; if (method !== 'GET') writes.push(route);
  let data = {};
  if (route.includes('/pulls?')) data = [];
  else if (route.includes('/commits/main')) data = {sha:'c'.repeat(40)};
  else if (route.includes('/git/trees/') && method === 'GET') data = {tree:[]};
  else if (route.includes('/git/commits/') && method === 'GET') data = {tree:{sha:'t'.repeat(40)}};
  else if (route.endsWith('/git/trees')) data = {sha:'n'.repeat(40)};
  else if (route.endsWith('/git/commits')) data = {sha:'m'.repeat(40)};
  else if (route.includes('/issues?') && method === 'GET') data = [];
  else if (route.endsWith('/issues')) data = {number:1};
  else if (route.endsWith('/pulls')) data = {number:1,node_id:'P'};
  return new Response(JSON.stringify(data), {status:200});
}});
const oneFileManifest=makeManifest([{path:'README',src:'README.md',sha,size:1,mode:'100644'}]);
const admission = await reconcileContent({api:fleetApi, owner:'f5', sourceSha:sha, mode:'full', inventory:['one','two','three'], selection:'', sourceRoot:process.cwd(), manifest:oneFileManifest, config:{managed_files:{files:[{src:'README.md',dest:'README'}],absent_files:[],skip_files:{}},branch_protection:[{branch:'main',required_status_checks:{strict:true,contexts:['Check linked issues','lint / Lint Code Base','lint / Shell Unit Tests']}}],repo_overrides:{one:{additional_contexts:['Extra']}}}});
assert.equal(admission.repositories.filter((entry) => entry.status === 'created').length, 2);
assert.equal(admission.repositories.find((entry) => entry.repo === 'three').status, 'deferred-capacity');
assert.equal(writes.filter((route) => route.endsWith('/pulls')).length, 2);
assert.equal(writes.filter((route) => route.includes('/statuses/')).length, 0);
assert.equal(writes.filter((route) => route.endsWith('/graphql')).length, 2);
const recoveryWrites=[];
const recoveryDesired={files:[{path:'README',sha,mode:'100644',src:'README.md'}],deletes:[]};
const recoveryTree=require('node:crypto').createHash('sha256').update(JSON.stringify(recoveryDesired)).digest('hex');
const recoveryNote=`<!-- governance-reconciler source=${sha} desired-tree=${recoveryTree} -->`;
const recoveryApi = new ApiQueue({token:'x', sleep:async()=>{}, now:()=>Number.MAX_SAFE_INTEGER, fetch:async(url, request) => {
  const route=String(url); const method=request.method; if (method !== 'GET') recoveryWrites.push(route);
  let data={};
  if (route.includes('/pulls?state=open&per_page=100')) {
    const repo=route.match(/repos\/f5\/([^/]+)/)[1];
    data=['one','two'].includes(repo) ? [{head:{ref:branchName(sha, repo)}}] : [];
  } else if (route.includes('/pulls?state=open&head=')) {
    const repo=route.match(/repos\/f5\/([^/]+)/)[1];
    data=['one','two'].includes(repo) ? [{number:1,node_id:'P',base:{ref:'main'},body:`${recoveryNote}\n\nCloses #1`,head:{sha}}] : [];
  } else if (route.includes('/pulls/1/files')) data=[{filename:'README'}];
  else if (route.includes('/commits/main')) data={sha:'c'.repeat(40)};
  else if (route.includes(`/git/trees/${sha}`)) data={tree:[{path:'README',type:'blob',sha,mode:'100644'}]};
  else if (route.includes('/git/trees/')) data={tree:[]};
  return new Response(JSON.stringify(data),{status:200});
}});
const recovered = await reconcileContent({api:recoveryApi, owner:'f5', sourceSha:sha, mode:'full', inventory:['one','two','three'], selection:'', sourceRoot:process.cwd(), manifest:oneFileManifest, config:{managed_files:{files:[{src:'README.md',dest:'README'}],absent_files:[],skip_files:{}}}});
assert.deepEqual(recovered.repositories.map(x => x.status), ['recovered','recovered','deferred-capacity']);
assert.equal(recoveryWrites.filter(route => route.includes('/statuses/')).length, 0);
assert.equal(recoveryWrites.filter(route => route.endsWith('/pulls')).length, 0);
const workflow = fs.readFileSync(path.join(path.dirname(process.argv[2]), '..', '.github/workflows/reconcile-fleet-content.yml'), 'utf8');
assert.match(workflow, /^  group: fleet-content-reconciler-v2$/m);
assert.match(workflow, /^  cancel-in-progress: false$/m);
assert.doesNotMatch(workflow, /^  group: fleet-content-reconciler$/m);
console.log('[OK] fleet reconciler contracts');
})().catch((error) => { console.error(error); process.exit(1); });
NODE
