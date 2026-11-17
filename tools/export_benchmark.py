"""Measure old/new Swift exporters and independently stream-verify >1.5GB ZIP."""
import hashlib,json,subprocess,zipfile,shutil
from pathlib import Path
root=Path(__file__).resolve().parents[1]; out=root/'build/export-benchmark'; out.mkdir(parents=True,exist_ok=True)
baseline='8e61cd4da98bf68b06aa5d37a217263e63994031'
subprocess.run(['git','fetch','--depth=1','origin',baseline],check=True)
old=out/'baseline'; old.mkdir(exist_ok=True)
paths=subprocess.check_output(['git','ls-tree','-r','--name-only',baseline,'Sources/Core']).decode().splitlines()
for name in paths:
    (old/Path(name).name).write_bytes(subprocess.check_output(['git','show',baseline+':'+name]))
for name,folder in [('baseline',old),('fixed',root/'Sources/Core')]:
    print('Compiling '+name,flush=True)
    subprocess.run(['xcrun','swiftc','-O','-whole-module-optimization','-module-name','BaduanjinCore',*map(str,folder.glob('*.swift')),str(root/'tools/ExportBenchmark/main.swift'),'-o',str(out/(name+'-run'))],check=True,timeout=180)
results={}
for case,binary,records,rows,padding in [('baseline-small','baseline',2,25000,0),('fixed-small','fixed',2,25000,0),('fixed-large','fixed',40,1000,40)]:
    print('Running '+case,flush=True)
    folder=out/case
    with (out/(case+'.log')).open('w') as stdout,(out/(case+'-memory.txt')).open('w') as stderr:
        subprocess.run(['/usr/bin/time','-l',str(out/(binary+'-run')),str(folder),str(records),str(rows),str(padding)],stdout=stdout,stderr=stderr,check=True,timeout=360)
    report=json.loads((folder/'result.json').read_text())
    usage=(out/(case+'-memory.txt')).read_text()
    report['peak_rss_bytes']=int(next(line.split()[0] for line in usage.splitlines() if 'maximum resident set size' in line))
    zpath=folder/'synthetic-export.zip'
    with zipfile.ZipFile(zpath) as z:
        manifest=json.loads(z.read('archive-files.json'))
        for item in manifest['files']:
            sha=hashlib.sha256(); size=0
            with z.open(item['path']) as f:
                while True:
                    chunk=f.read(256*1024)
                    if not chunk:break
                    sha.update(chunk); size+=len(chunk)
            assert sha.hexdigest()==item['sha256'] and size==item['bytes']
        report['independent_zip_crc_sha_verified']=True
        report['manifest']={i['path']:(i['bytes'],i['sha256']) for i in manifest['files']}
    results[case]=report
    if case=='fixed-small':
        assert results['baseline-small']['manifest']==report['manifest'],'Export bytes changed'
    checkpoint={name:{k:v for k,v in row.items() if k!='manifest'} for name,row in results.items()}
    (root/'build/export-memory-progress.json').write_text(json.dumps(checkpoint,indent=2))
    print(json.dumps(checkpoint[case]),flush=True)
    # Only synthetic benchmark intermediates under this newly created directory.
    shutil.rmtree(folder)
assert results['baseline-small']['manifest']==results['fixed-small']['manifest'],'Export bytes changed'
assert results['fixed-large']['zip_bytes']>1_500_000_000
assert results['fixed-large']['peak_rss_bytes']<350*1024*1024,'Large export memory is not bounded'
for report in results.values():report.pop('manifest')
(root/'build/export-memory-results.json').write_text(json.dumps(results,indent=2))
print(json.dumps(results,indent=2))
