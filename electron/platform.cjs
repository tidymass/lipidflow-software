const path = require('node:path');
const fs = require('node:fs/promises');
const {execFile} = require('node:child_process');

function runtimeCandidates(root, platform = process.platform) {
  return (platform === 'win32' ? ['bin/x64/Rscript.exe', 'bin/Rscript.exe'] : ['bin/Rscript'])
    .map(file => path.join(root, 'runtime', 'R', file));
}
async function findRscript(root, packaged, env = process.env, platform = process.platform) {
  for (const file of runtimeCandidates(root, platform)) {
    try { await fs.access(file); return file; } catch {}
  }
  if (packaged) throw Error('The bundled R runtime is missing. Please reinstall LipidFlow.');
  const candidates = [env.LIPIDFLOW_RSCRIPT, ...(platform === 'win32'
    ? (env.R_HOME ? [path.join(env.R_HOME, 'bin/x64/Rscript.exe'), path.join(env.R_HOME, 'bin/Rscript.exe')] : [])
    : ['/usr/local/bin/Rscript', '/opt/homebrew/bin/Rscript', '/Library/Frameworks/R.framework/Resources/bin/Rscript'])];
  for (const file of candidates.filter(Boolean)) { try { await fs.access(file); return file; } catch {} }
  return platform === 'win32' ? 'Rscript.exe' : 'Rscript';
}
function rEnvironment(executable, env = process.env, platform = process.platform) {
  const result = {...env, RGL_USE_NULL: 'TRUE'};
  // Only isolate our own bundle. Development overrides retain their environment.
  const normalized = executable.replaceAll('\\', '/');
  const match = normalized.match(/^(.*\/runtime\/R)\/bin\/(?:x64\/)?Rscript(?:\.exe)?$/i);
  if (!match) return result;
  const home = match[1];
  for (const key of Object.keys(result)) {
    if (/^R_(HOME|ARCH|LIBS.*|ENVIRON.*|PROFILE.*|SHARE_DIR|INCLUDE_DIR|DOC_DIR)$|^RHOME$/i.test(key)) delete result[key];
  }
  Object.assign(result, {R_HOME: home, RHOME: home, R_LIBS: `${home}/library`, R_LIBS_USER: `${home}/library`, R_LIBS_SITE: `${home}/library`,
    R_ENVIRON_USER: platform === 'win32' ? 'NUL' : '/dev/null', R_PROFILE_USER: platform === 'win32' ? 'NUL' : '/dev/null'});
  if (platform === 'win32') {
    const key = Object.keys(result).find(k => k.toUpperCase() === 'PATH');
    const original = key ? result[key] : '';
    if (key) delete result[key];
    result.PATH = `${home}/bin/x64;${home}/bin;${original}`;
  } else if (platform === 'darwin') result.DYLD_LIBRARY_PATH = `${home}/lib`;
  return result;
}
function stopProcessTree(child, platform = process.platform) {
  if (!child?.pid || child.exitCode !== null || child.signalCode) return;
  if (platform === 'win32') {
    // Terminate PSOCK workers and package installers as well as the parent R process.
    execFile('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], {windowsHide: true}, error => {
      if (error && child.exitCode === null) child.kill();
    });
    return;
  }
  try { process.kill(-child.pid, 'SIGTERM'); } catch { child.kill(); }
  const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 2000);
  timer.unref();
}
module.exports = {runtimeCandidates, findRscript, rEnvironment, stopProcessTree};
