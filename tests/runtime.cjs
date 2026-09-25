const fs=require('node:fs'),path=require('node:path');
const resources=process.env.LIPIDFLOW_TEST_RESOURCES||path.resolve(__dirname,'..');
const exe=require('../electron/platform.cjs').runtimeCandidates(resources).find(p=>fs.existsSync(p));
if(!exe)throw Error('Missing test runtime in '+resources);
module.exports={resources,exe};
