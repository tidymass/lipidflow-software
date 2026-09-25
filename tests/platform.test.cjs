const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {runtimeCandidates,findRscript,rEnvironment} = require('../electron/platform.cjs');
const {checkRuntime} = require('../scripts/check-runtime.cjs');

test('Windows bundle isolation handles spaces, Unicode, and case-insensitive PATH',()=>{
  const env=rEnvironment('C:\\用户\\LipidFlow Desktop\\resources\\runtime\\R\\bin\\x64\\Rscript.exe',
    {Path:'C:\\Windows\\System32',R_HOME:'C:/wrong',R_LIBS_USER:'C:/wrong/library',R_ARCH:'/wrong',OTHER:'preserve'},'win32');
  assert.equal(env.R_HOME,'C:/用户/LipidFlow Desktop/resources/runtime/R');
  assert.equal(env.R_LIBS_USER,env.R_HOME+'/library');
  assert.equal(env.R_ENVIRON_USER,'NUL');
  assert.equal(env.R_ARCH,undefined); assert.equal(env.Path,undefined);
  assert(env.PATH.endsWith(';C:\\Windows\\System32'));
  assert.equal(env.OTHER,'preserve');
});
test('macOS bundle environment remains isolated; external development R is not rewritten',()=>{
  const env=rEnvironment('/Applications/LipidFlow.app/Contents/Resources/runtime/R/bin/Rscript',{},'darwin');
  assert.equal(env.DYLD_LIBRARY_PATH,env.R_HOME+'/lib');
  assert.equal(rEnvironment('/usr/local/bin/Rscript',{R_HOME:'dev'},'darwin').R_HOME,'dev');
});
test('packaged lookup requires correct platform runtime, never falls back to system R',async()=>{
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'lipidflow-platform-'));
  try {
    const [mac]=runtimeCandidates(root,'darwin');await fs.mkdir(path.dirname(mac),{recursive:true});await fs.writeFile(mac,'');
    await assert.rejects(findRscript(root,true,{},'win32'),/bundled R runtime is missing/);
    const [win]=runtimeCandidates(root,'win32');await fs.mkdir(path.dirname(win),{recursive:true});await fs.writeFile(win,'');
    assert.equal(await findRscript(root,true,{},'win32'),win);
    assert.throws(()=>checkRuntime(root,'win32'),/incomplete/);
  } finally {await fs.rm(root,{recursive:true,force:true});}
});
test('cancellation terminates worker descendants as well as the parent',async()=>{
  const {spawn}=require('node:child_process');
  const {stopProcessTree}=require('../electron/platform.cjs');
  const script=`const {spawn}=require('node:child_process');const worker=spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{stdio:'ignore'});console.log(worker.pid);setInterval(()=>{},1000);`;
  const child=spawn(process.execPath,['-e',script],{detached:process.platform!=='win32',windowsHide:true});
  let worker;
  try {
    worker=await new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>reject(Error('Worker did not start')),10000);
      child.on('error',reject);child.stdout.once('data',b=>{clearTimeout(timer);resolve(Number(b.toString().trim()));});
    });
    assert(Number.isInteger(worker)&&worker>0);
    stopProcessTree(child);
    const alive=pid=>{try{process.kill(pid,0);return true;}catch{return false;}};
    for(let i=0;i<100&&(alive(worker)||alive(child.pid));i++) await new Promise(resolve=>setTimeout(resolve,100));
    assert.equal(alive(worker),false,'Worker survived cancellation');
    assert.equal(alive(child.pid),false,'Parent survived cancellation');
  } finally {
    stopProcessTree(child);
    if(worker)try{process.kill(worker);}catch{}
  }
});
