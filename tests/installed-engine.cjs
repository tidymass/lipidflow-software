const {spawnSync}=require('node:child_process');
const {exe}=require('./runtime.cjs');
const {rEnvironment}=require('../electron/platform.cjs');
function run(program,args,env=process.env){
  const result=spawnSync(program,args,{stdio:'inherit',env,windowsHide:true});
  if(result.error)throw result.error;
  if(result.status!==0)throw Error(program+' '+args.join(' ')+' failed: '+result.status);
}
run(process.execPath,['tests/engine.cjs','--raw']);
run(process.execPath,['tests/exploration-raw.cjs']);
run(process.execPath,['tests/raw-workflow.cjs']);
run(exe,['--vanilla','tests/annotation-fixtures.R'],rEnvironment(exe));
run(process.execPath,['tests/annotation.cjs']);
