#!/usr/bin/env python3
"""Build a Windows x64 R bundle in a staging folder; keep an existing bundle on failure."""
import hashlib, json, os, shutil, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'scripts'))
import importlib.util
spec = importlib.util.spec_from_file_location('snapshot', ROOT/'scripts/snapshot-runtime.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
dcf = module.dcf

def main():
    if sys.platform != 'win32':
        raise SystemExit('Build this runtime on Windows x64 with R 4.5.2 and Rtools45; macOS binaries cannot be reused.')
    rscript = os.environ.get('LIPIDFLOW_BUILD_RSCRIPT') or shutil.which('Rscript.exe')
    if not rscript:
        raise SystemExit('Install R 4.5.2 and add Rscript.exe to PATH.')
    info = subprocess.check_output([rscript,'--vanilla','-e',
        'cat(normalizePath(R.home(),winslash="/"),as.character(getRversion()),R.version$arch,sep="\\n")'],text=True).strip().splitlines()
    home, version, arch = Path(info[-3]), info[-2], info[-1]
    lock = json.loads((ROOT/'packaging/r-packages.lock.json').read_text())
    if version != lock['R']['Version'] or arch != 'x86_64':
        raise SystemExit(f'Expected R {lock["R"]["Version"]} x86_64, found {version} {arch}')
    stage, dest = ROOT/'runtime/R-windows-staging', ROOT/'runtime/R'
    if stage.exists():
        shutil.rmtree(stage)
    shutil.copytree(home,stage,ignore=shutil.ignore_patterns('library','unins*'))
    library = ROOT/'runtime/windows-library'
    library.mkdir(parents=True, exist_ok=True)
    for package in (home/'library').iterdir():
        if (package/'DESCRIPTION').exists() and dcf(package/'DESCRIPTION').get('Priority') in ('base','standard','recommended') and not (library/package.name).exists():
            shutil.copytree(package,library/package.name)
    subprocess.run([rscript,'--vanilla',str(ROOT/'scripts/windows/restore-packages.R'),
                    str(ROOT/'packaging/r-packages.lock.json'),str(library)],cwd=ROOT,check=True)
    shutil.copytree(library,stage/'library')
    packages = [dcf(p) for p in sorted((stage/'library').glob('*/DESCRIPTION'))]
    baseline = json.loads((ROOT/'packaging/r-baseline.json').read_text())
    versions = {p['Package']:p['Version'] for p in packages}
    for package in baseline:
        if versions.get(package['Package']) != package['Version']:
            raise RuntimeError('Baseline mismatch: '+package['Package'])
    (stage/'package-manifest.json').write_text(json.dumps([
        {k:p.get(k,'') for k in ('Package','Version','License')} for p in packages],indent=2))
    binaries = []
    for file in stage.rglob('*'):
        if file.is_file() and file.suffix.lower() in ('.dll','.exe'):
            with file.open('rb') as stream:
                if stream.read(2) != b'MZ': raise RuntimeError('Not a Windows binary: '+str(file))
            binaries.append({'path':file.relative_to(stage).as_posix(),'sha256':hashlib.sha256(file.read_bytes()).hexdigest()})
    (stage/'native-manifest.json').write_text(json.dumps({'platform':'win32','arch':'x64','binaries':binaries},indent=2))
    (stage/'runtime-manifest.json').write_text(json.dumps({'platform':'win32','arch':'x64','rVersion':version,
        'packageLockSHA256':hashlib.sha256((ROOT/'packaging/r-packages.lock.json').read_bytes()).hexdigest()},indent=2))
    shutil.copy2(ROOT/'packaging/r-packages.lock.json',stage/'source-manifest.json')
    (stage/'THIRD-PARTY-NOTICES.txt').write_text(
        f'LipidFlow Windows analysis runtime\n\nR {version}: GPL-2 or GPL-3. '
        f'Source: https://cran.r-project.org/src/base/R-4/R-{version}.tar.gz\n'
        'R COPYING, COPYRIGHTS and share/licenses are preserved. Package DESCRIPTION and license files '
        'are in library/<package>. source-manifest.json records source versions and commits. '
        'native-manifest.json records bundled PE binaries and checksums. Each component retains its own license.\n')
    # Promote only after restoration and version checks succeed.
    previous = ROOT/'runtime/R-previous'
    if previous.exists(): raise RuntimeError('Remove or archive runtime/R-previous before replacing the runtime.')
    if dest.exists(): dest.rename(previous)
    try: stage.rename(dest)
    except Exception:
        if previous.exists(): previous.rename(dest)
        raise
    if previous.exists(): shutil.rmtree(previous)
    print(f'Bundled Windows R {version}, {len(packages)} packages, {len(binaries)} PE binaries')

if __name__ == '__main__': main()
