const fs = require('node:fs');
const path = require('node:path');
const {runtimeCandidates} = require('../electron/platform.cjs');
const roots = ['lipidflow','sxtTools','massdataset','massprocesser','metid','xcms','MSnbase','Rdisop','jsonlite','readxl','openxlsx','plotly','patchwork'];
function checkRuntime(base, platform = process.platform) {
  const root = path.join(base, 'runtime', 'R');
  const files = ['package-manifest.json', 'native-manifest.json', 'THIRD-PARTY-NOTICES.txt',
    ...(platform === 'win32' ? ['bin/x64/R.dll'] : ['bin/exec/R', 'lib/libR.dylib'])];
  if (!['darwin','win32'].includes(platform)) throw Error('Runtime packaging is not yet configured for '+platform);
  for (const file of files) if (!fs.existsSync(path.join(root, file))) throw Error('Bundled R is incomplete for '+platform+': '+file);
  if (!runtimeCandidates(base, platform).some(file=>fs.existsSync(file))) throw Error('Bundled Rscript is missing for '+platform);
  const packages = JSON.parse(fs.readFileSync(path.join(root, 'package-manifest.json')));
  for (const name of roots) {
    if (!packages.some(p => p.Package === name) || !fs.existsSync(path.join(root,'library',name,'DESCRIPTION')))
      throw Error('Missing bundled package: ' + name);
  }
  if (platform === 'win32') {
    const manifest = JSON.parse(fs.readFileSync(path.join(root, 'runtime-manifest.json')));
    if (manifest.platform !== 'win32' || manifest.arch !== 'x64') throw Error('Expected Windows x64 runtime.');
  }
  return packages.length;
}
if (require.main === module) console.log('Bundled runtime checked: ' + checkRuntime(path.join(__dirname,'..'),process.argv[2]||process.platform) + ' packages');
module.exports={checkRuntime};
