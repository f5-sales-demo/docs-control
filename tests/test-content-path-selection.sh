#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
node - "$root/scripts/fleet-reconciler.cjs" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const {parseManagedPaths, selectManagedEntries, reconcileContent, manifestStateDigest} = require(process.argv[2]);
const blob = (text) => crypto.createHash('sha1').update(`blob ${Buffer.byteLength(text)}\0`).update(text).digest('hex');
const sha = 'a'.repeat(40);
const files = ['auditor.py','unrelated.md'].map(name => ({path:name,src:name,sha:blob(name),size:Buffer.byteLength(name),mode:'100644'}));
const config = {managed_files:{source_repo:'f5/docs-control',files:files.map(x=>({src:x.src,dest:x.path})),absent_files:['retired.md'],skip_files:{}}};
const manifest = {schema_version:2,source_commit:sha,files,absent_paths:['retired.md'],state_digest:manifestStateDigest(files,['retired.md'])};
(async () => {
assert.equal(parseManagedPaths(undefined,config,manifest),null);
assert.deepEqual(parseManagedPaths('["auditor.py"]',config,manifest),['auditor.py']);
for (const bad of ['not-json','[]','{}','null','["auditor.py","auditor.py"]','["../auditor.py"]','["missing.py"]','[1]']) assert.throws(()=>parseManagedPaths(bad,config,manifest));
assert.deepEqual(selectManagedEntries({files,deletes:['retired.md']},['auditor.py']),{files:[files[0]],deletes:[]});
assert.deepEqual(selectManagedEntries({files,deletes:['retired.md']},['retired.md']),{files:[],deletes:['retired.md']});
assert.deepEqual(selectManagedEntries({files:[],deletes:[]},['auditor.py']),{files:[],deletes:[]});
const sourceRoot=fs.mkdtempSync(path.join(os.tmpdir(),'content-paths-'));
try {
 for(const item of files) fs.writeFileSync(path.join(sourceRoot,item.src),item.src);
 const calls=[];
 const api={request:async(route,options={})=>{
  calls.push({route,method:options.method||'GET'});
  if(options.method && options.method!=='GET') throw Error('unexpected GitHub write');
  if(route==='repos/f5/one') return {archived:false};
  if(route.includes('/pulls?')) return [];
  if(route==='repos/f5/one/commits/main') return {sha:'b'.repeat(40)};
  if(route.includes('/git/trees/')) return {truncated:false,tree:files.map(x=>({...x,type:'blob',sha:route.includes('/docs-control/')?x.sha:'c'.repeat(40)}))};
  throw Error(`unexpected ${route}`);
 }};
 const options={api,owner:'f5',sourceSha:sha,mode:'dry-run',inventory:['one'],selection:'one',config,manifest,sourceRoot,managedPaths:'["auditor.py"]'};
 const result=await reconcileContent(options);
 assert.equal(result.repositories[0].changes,1);
 assert.deepEqual(result.managedPaths,['auditor.py']);
 assert.equal(calls.some(x=>x.route.includes('/issues')),false);
 assert.equal(calls.some(x=>x.method!=='GET'),false);
 assert.deepEqual(result.retiredOwners,[]);
 const skipped=structuredClone(config); skipped.managed_files.skip_files.one=['auditor.py'];
 const noop=await reconcileContent({...options,config:skipped,mode:'full'});
 assert.equal(noop.repositories[0].status,'noop');
 assert.deepEqual(noop.repositories[0].reconciledIssues,[]);
 const archivedApi={request:async(route,request)=>route==='repos/f5/one'?{archived:true}:api.request(route,request)};
 const archived=await reconcileContent({...options,api:archivedApi});
 assert.equal(archived.repositories[0].status,'skipped-archived');
 const writes=[];
 const fullApi={request:async(route,request={})=>{
  if (!request.method || request.method==='GET') {
   if(route.includes('/docs-control/git/trees/')) fs.writeFileSync(path.join(sourceRoot,'auditor.py'),'changed after verification');
   if(route.endsWith('/git/commits/'+ 'b'.repeat(40))) return {tree:{sha:'d'.repeat(40)}};
   if(route.includes('/issues?')) return [];
   return api.request(route,request);
  }
  writes.push({route,...request});
  if(route.endsWith('/git/trees')) return {sha:'e'.repeat(40)};
  if(route.endsWith('/git/commits')) return {sha:'f'.repeat(40)};
  if(route.endsWith('/issues')) return {number:17};
  if(route.endsWith('/pulls')) return {number:18,node_id:'pr-node'};
  return {};
 }};
 const delivered=await reconcileContent({...options,api:fullApi,mode:'full'});
 assert.equal(delivered.repositories[0].status,'created');
 const treeWrite=writes.find(x=>x.route.endsWith('/git/trees'));
 assert.deepEqual(treeWrite.body.tree.map(x=>x.path),['auditor.py']);
 assert.equal(treeWrite.body.tree[0].content,'auditor.py');
 fs.writeFileSync(path.join(sourceRoot,'auditor.py'),'auditor.py');
 assert.match(writes.find(x=>x.route.endsWith('/pulls')).body.body,/^Closes #17$/m);
 assert.equal(writes.some(x=>x.method==='PATCH'||x.method==='DELETE'),false);
 assert.equal(writes.some(x=>x.route.includes('/repos/f5/one')),false);
 calls.length=0;
 await assert.rejects(reconcileContent({...options,manifest:{...manifest,source_commit:'b'.repeat(40)}}),/manifest source/);
 assert.equal(calls.length,0);
 calls.length=0;
 await assert.rejects(reconcileContent({...options,managedPaths:'[]'}));
 assert.equal(calls.length,0);
 fs.writeFileSync(path.join(sourceRoot,'unrelated.md'),'corrupt');
 await assert.rejects(reconcileContent(options),/source.*(blob|digest|custody)/i);
 assert.equal(calls.some(x=>x.method!=='GET'),false);
 console.log('Exact content-path selection regressions passed');
} finally {fs.rmSync(sourceRoot,{recursive:true,force:true});}
})().catch(error=>{console.error(error);process.exitCode=1;});
NODE
