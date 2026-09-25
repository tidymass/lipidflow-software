const fs=require('node:fs/promises');const path=require('node:path');const os=require('node:os');const {randomUUID}=require('node:crypto');
function createProjectStore(){
 let held=null,queue=Promise.resolve();
 async function acquire(folder){
  folder=await fs.realpath(folder);if(held?.folder===folder)return;
  const file=path.join(folder,'.lipidflow-lock.json'),token=randomUUID();
  const record={pid:process.pid,host:os.hostname(),token};
  for(let attempt=0;attempt<2;attempt++){
   try{const f=await fs.open(file,'wx');try{await f.writeFile(JSON.stringify(record))}finally{await f.close()}break}
   catch(e){if(e.code!=='EEXIST')throw e;let old;try{old=JSON.parse(await fs.readFile(file,'utf8'))}catch{throw Error('Project lock could not be read. Close other LipidFlow instances before opening this project.');}
    if(old.host!==os.hostname())throw Error('This project is locked on another computer. Close it there first.');
    let alive=true;try{process.kill(old.pid,0)}catch(e){if(e.code==='ESRCH')alive=false}
    if(alive||attempt)throw Error('This project is already open in another LipidFlow instance.');
    await fs.unlink(file);
   }
  }
  await release();held={folder,file,token};
 }
 async function release(){await queue.catch(()=>{});if(!held)return;const lock=held;held=null;try{const current=JSON.parse(await fs.readFile(lock.file,'utf8'));if(current.token===lock.token)await fs.unlink(lock.file)}catch(e){if(e.code!=='ENOENT')throw e}}
 function save(project){const file=path.join(project.path,'project.json'),data=JSON.stringify(project,null,2);queue=queue.catch(()=>{}).then(async()=>{if(!held||await fs.realpath(project.path)!==held.folder)throw Error('Project write lock is not held.');try{const previous=await fs.readFile(file,'utf8');JSON.parse(previous);await fs.writeFile(file+'.backup',previous)}catch(e){if(e.code!=='ENOENT')throw e}const tmp=file+'.'+randomUUID()+'.tmp';await fs.writeFile(tmp,data);await fs.rename(tmp,file)});return queue}
 return {acquire,release,save};
}
module.exports={createProjectStore};
