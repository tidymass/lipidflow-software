const stages=['import','picking','annotation','quantification','export'];
function state(project){
 const current={};
 for(const run of project.runs){
  if(run.status!=='completed'||!stages.includes(run.operation))continue;
  if(run.operation==='import'){for(const k of stages)delete current[k];current.import=run;continue;}
  const index=stages.indexOf(run.operation);
  if(!Object.values(current).some(x=>x.id===run.inputId))continue;
  for(const k of stages.slice(index))delete current[k];current[run.operation]=run;
 }
 return current;
}
function validate(project,operation,inputId){
 if(![...stages,'extraction','selection'].includes(operation))throw Error('Unsupported analysis.');
 if(project.mode==='extraction'&&!['extraction','selection'].includes(operation))throw Error('This project is for Peak Extraction.');
 if(['import','extraction'].includes(operation))return null;
 const input=project.runs.find(x=>x.id===inputId&&x.status==='completed');
 if(!input)throw Error('Choose a completed input run.');
 if(operation==='selection'){
  if(!['extraction','selection'].includes(input.operation))throw Error('Choose a peak extraction result.');return input;
 }
 if(!Object.values(state(project)).some(x=>x.id===inputId))throw Error('This input belongs to an older workflow. Use the current results.');
 if(stages.indexOf(input.operation)>=stages.indexOf(operation))throw Error('Choose an input from an earlier workflow stage.');
 const capabilities=input.result?.capabilities||[];
 const needs={picking:'raw',annotation:'objects',quantification:'annotations',export:'tables'};
 if(!capabilities.includes(needs[operation]))throw Error('The selected input is not ready for this stage.');
 return input;
}
module.exports={stages,state,validate};
