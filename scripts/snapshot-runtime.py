#!/usr/bin/env python3
"""Record the macOS baseline for reproducible Windows package restoration.
Legacy packages without provenance use reviewed source overrides, never HEAD.
Run after intentionally updating the macOS runtime; review the lockfile diff.
"""
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def dcf(file):
    data, key = {}, None
    for line in file.read_text(encoding='utf-8').splitlines():
        if line[:1].isspace() and key:
            data[key] += ' ' + line.strip()
        elif ':' in line:
            key, value = line.split(':', 1)
            data[key] = value.strip()
    return data

def snapshot():
    overrides = json.loads((ROOT/'packaging/r-source-overrides.json').read_text())
    lock = {'R': {'Version': dcf(ROOT/'runtime/R/library/base/DESCRIPTION')['Version'], 'Repositories': [{'Name':'CRAN','URL':'https://cloud.r-project.org'}]},
            'Bioconductor': {'Version':'3.21'}, 'Packages': {}}
    baseline = []
    for file in sorted((ROOT/'runtime/R/library').glob('*/DESCRIPTION')):
        d = dcf(file)
        name, version = d['Package'], d['Version']
        # MetMiner is a separate TidyMass Shiny application, not used by LipidFlow.
        if name == 'MetMiner':
            continue
        baseline.append({'Package':name, 'Version':version, 'License':d.get('License','')})
        if d.get('Priority') in ('base','standard'):
            continue
        record = {k:d[k] for k in ('Package','Version','Depends','Imports','LinkingTo') if k in d}
        if name in overrides:
            override = overrides[name]
            if override['Version'] != version:
                raise ValueError(f'{name} changed: review its pinned source override first')
            record.update({k:v for k,v in override.items() if k != 'Note'})
        elif d.get('RemoteType') in ('github','gitlab'):
            record['Source'] = {'github':'GitHub','gitlab':'GitLab'}[d['RemoteType']]
            record.update({k:v for k,v in d.items() if k.startswith('Remote') and k != 'Remotes'})
            if not d.get('RemoteSha'):
                raise ValueError(f'Missing commit for {name}')
            record['RemoteRef'] = d['RemoteSha']
        elif d.get('RemoteUrl','').startswith('https://github.com/') and d.get('RemoteSha'):
            owner, repo = d['RemoteUrl'].removeprefix('https://github.com/').rstrip('/').split('/')
            record.update(Source='GitHub', RemoteType='github', RemoteHost='api.github.com',
                          RemoteUsername=owner, RemoteRepo=repo.removesuffix('.git'),
                          RemoteSha=d['RemoteSha'], RemoteRef=d['RemoteSha'])
        elif d.get('Repository','').startswith('Bioconductor'):
            record.update(Source='Bioconductor', Repository='Bioconductor')
        elif d.get('Repository') == 'CRAN':
            record.update(Source='Repository', Repository='CRAN')
        else:
            raise ValueError(f'Unknown source: {name}. Add a reviewed source override.')
        lock['Packages'][name] = record
    if not baseline:
        raise ValueError('No bundled macOS runtime found')
    for name,data in [('r-packages.lock.json',lock),('r-baseline.json',baseline)]:
        (ROOT/'packaging'/name).write_text(json.dumps(data,indent=2)+'\n')
    print(f'Recorded {len(baseline)} baseline packages; {len(lock["Packages"])} source records')

if __name__ == '__main__':
    snapshot()
