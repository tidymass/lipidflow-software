const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
function verify(resources) {
  for (const side of ['POS', 'NEG']) {
    assert(!fs.existsSync(path.join(resources, 'runtime/R/library/lipidflow', side)),
      'Demo data must not be shipped: lipidflow/' + side);
  }
  for (const file of ['runtime/R/library/lipidflow/DESCRIPTION', 'backend/worker.R',
    'backend/databases/msdial_lipid_pos_db.rda', 'backend/databases/msdial_lipid_neg_db.rda']) {
    assert(fs.existsSync(path.join(resources, file)), 'Required analysis resource missing: ' + file);
  }
  console.log('Packaged resources verified: no lipidflow demo data; analysis package and POS/NEG databases retained.');
}
module.exports = async context => verify(path.join(context.appOutDir,
  context.electronPlatformName === 'darwin' ? 'LipidFlow.app/Contents/Resources' : 'resources'));
module.exports.verify = verify;
if (require.main === module) verify(process.argv[2]);
