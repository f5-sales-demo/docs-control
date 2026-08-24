#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
node - "$root/scripts/fleet-reconciler.cjs" <<'NODE'
const assert = require('node:assert/strict');
const {ACTIVE_PR_LIMIT, ATTESTED_CONTEXTS, ApiQueue, aggregateProtection, assertAttestableRecovery, contentDiff, currentProtection, desiredEntries, desiredProtection, parseSelection, reconcileContent, requireSha, settingsDelta} = require(process.argv[2]);
(async () => {
const sha = 'a'.repeat(40);
assert.equal(requireSha(sha), sha);
assert.throws(() => requireSha('short'));
assert.deepEqual(parseSelection('one,two', ['one', 'two']), ['one', 'two']);
assert.throws(() => parseSelection('missing', ['one']));
const config = {managed_files:{files:[{src:'a',dest:'a'},{src:'b',dest:'b',only_repos:['one']}],absent_files:['retired'],skip_files:{two:['a']}}};
const manifest = {files:{a:{src:'a',sha,size:1,mode:'100644'},b:{src:'b',sha:'b'.repeat(40),size:1,mode:'100755'}}};
assert.deepEqual(desiredEntries(config, manifest, 'one').files.map(x => x.path), ['a','b']);
assert.deepEqual(desiredEntries(config, manifest, 'two').files.map(x => x.path), []);
assert.deepEqual(contentDiff({tree:[{path:'a',type:'blob',sha:'c'.repeat(40),mode:'100644'},{path:'retired',type:'blob',sha:sha,mode:'100644'}]}, desiredEntries(config, manifest, 'one')).map(x => x.action), ['upsert','upsert','delete']);
assert.deepEqual(settingsDelta({has_issues:true,has_wiki:true}, {has_issues:true,has_wiki:false}), {has_wiki:false});
const protection = desiredProtection({branch_protection:[{branch:'main',enforce_admins:true,required_status_checks:{strict:true,contexts:['lint / Lint'],self_contexts:['Lint']},required_pull_request_reviews:null,restrictions:null,required_linear_history:false,allow_force_pushes:false,allow_deletions:false,block_creations:false,required_conversation_resolution:false,lock_branch:false,allow_fork_syncing:false}],repo_overrides:{one:{additional_contexts:['Extra']}}}, 'one');
assert.deepEqual(protection.required_status_checks.contexts, []);
assert.deepEqual(protection.required_status_checks.checks, [{context:'Extra',app_id:15368},{context:'lint / Lint',app_id:15368}]);
const attestedProtection = desiredProtection({branch_protection:[{branch:'main',enforce_admins:true,required_status_checks:{strict:true,contexts:['Check linked issues','lint / Lint Code Base','lint / Shell Unit Tests']},required_pull_request_reviews:null,restrictions:null}]}, 'one');
assert.deepEqual(attestedProtection.required_status_checks.checks, [{context:'Check linked issues',app_id:15368},{context:'lint / Lint Code Base',app_id:-1},{context:'lint / Shell Unit Tests',app_id:-1}]);
assert.deepEqual(aggregateProtection(attestedProtection).required_status_checks, {strict:true,contexts:['Check linked issues','lint / Lint Code Base','lint / Shell Unit Tests']});
assert.equal(currentProtection({enforce_admins:{enabled:true},required_status_checks:{strict:true,contexts:['Extra','Lint']},required_pull_request_reviews:null,restrictions:null,required_linear_history:{enabled:false},allow_force_pushes:{enabled:false},allow_deletions:{enabled:false},block_creations:{enabled:false},required_conversation_resolution:{enabled:false},lock_branch:{enabled:false},allow_fork_syncing:{enabled:false}}).enforce_admins, true);
assert.deepEqual(currentProtection({required_status_checks:{strict:true,checks:[{context:'lint / Lint',app_id:-1}]},required_pull_request_reviews:null,restrictions:null}).required_status_checks, {strict:true,contexts:[],checks:[{context:'lint / Lint',app_id:-1}]});
assert.equal(currentProtection({enforce_admins:{enabled:true},required_status_checks:null,required_pull_request_reviews:null,restrictions:{users:[],teams:[],apps:[]}}).restrictions, null);
assert.deepEqual(currentProtection({enforce_admins:{enabled:true},required_status_checks:null,required_pull_request_reviews:null,restrictions:{users:[{login:'alice'}],teams:[],apps:[]}}).restrictions, {users:['alice'],teams:[],apps:[]});
assert.equal(ACTIVE_PR_LIMIT, 2);
assert.deepEqual(ATTESTED_CONTEXTS, ['lint / Lint Code Base', 'lint / Shell Unit Tests']);
const recovery = {pr:{base:{ref:'main'},body:'marker'},note:'marker',changes:[{path:'a'}],files:[{filename:'a'}],headTree:{tree:[{path:'a',type:'blob',sha,mode:'100644'}]},desired:{files:[{path:'a',sha,mode:'100644'}],deletes:[]}};
assert.doesNotThrow(() => assertAttestableRecovery(recovery));
assert.throws(() => assertAttestableRecovery({...recovery,files:[{filename:'a'},{filename:'unmanaged'}]}), /unexpected paths/);
assert.throws(() => assertAttestableRecovery({...recovery,headTree:{tree:[]}}), /desired managed tree/);
const calls=[]; const headers=[]; let now=0; const api = new ApiQueue({token:'x', now:()=>now, sleep:async(ms)=>{calls.push(ms); now += ms;}, fetch:async(_url, request)=>{headers.push(request.headers); return new Response('{}',{status:200,headers:{etag:'"fleet"'}});}});
await api.request('one',{method:'POST'}); now=10; await api.request('two',{method:'PATCH'}); assert.deepEqual(calls,[990]);
await api.request('read'); await api.request('read'); assert.equal(headers.at(-1)['if-none-match'], '"fleet"');
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
const admission = await reconcileContent({api:fleetApi, owner:'f5', sourceSha:sha, mode:'full', inventory:['one','two','three'], selection:'', sourceRoot:process.cwd(), manifest:{files:{README:{src:'README.md',sha,mode:'100644'}}}, config:{managed_files:{files:[{src:'README.md',dest:'README'}],absent_files:[],skip_files:{}}}});
assert.equal(admission.repositories.filter((entry) => entry.status === 'created').length, 2);
assert.equal(admission.repositories.find((entry) => entry.repo === 'three').status, 'deferred-capacity');
assert.equal(writes.filter((route) => route.endsWith('/pulls')).length, 2);
assert.equal(writes.filter((route) => route.includes('/statuses/')).length, 4);
console.log('[OK] fleet reconciler contracts');
})().catch((error) => { console.error(error); process.exit(1); });
NODE
