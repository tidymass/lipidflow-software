const {_electron:electron}=require('@playwright/test');
const fs=require('node:fs/promises'),path=require('node:path'),os=require('node:os');
(async()=>{
 const base=await fs.mkdtemp(path.join(os.tmpdir(),'lipidflow-shortcuts-'));
 for(const key of ['w','q']){
  const app=await electron.launch({args:[path.resolve(__dirname,'..')],env:{...process.env,LIPIDFLOW_TEST_USER_DATA:path.join(base,key)}});
  try{
   const page=await app.firstWindow();
   await page.waitForSelector('.lf-workflow-card:not(:disabled)',{timeout:120000});
   const project=await page.evaluate(parent=>window.desktop.invoke('createProject',{name:'Shortcut project',mode:'extraction',parent}),base);
   const closed=app.waitForEvent('close',{timeout:15000});
   await app.evaluate(({BrowserWindow},key)=>{const window=BrowserWindow.getAllWindows()[0];window.focus();window.webContents.focus();window.webContents.sendInputEvent({type:'keyDown',keyCode:key.toUpperCase(),modifiers:[process.platform==='darwin'?'meta':'control']})},key);
   await closed;
   try{await fs.access(path.join(project.path,'.lipidflow-lock.json'));throw Error('Project lock retained after shortcut')}catch(e){if(e.code!=='ENOENT')throw e}
   console.log('PASS shortcut '+key+': application closed and project lock released');
   await fs.rename(project.path,path.join(base,'completed-'+key));
  }finally{await app.close().catch(()=>{})}
 }
 await fs.rm(base,{recursive:true,force:true});
})().catch(e=>{console.error(e);process.exitCode=1});
