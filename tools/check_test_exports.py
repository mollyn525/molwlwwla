"""Independent ZIP implementation verifies actual output of the Swift exporter tests."""
import hashlib,json,sys,zipfile
from pathlib import Path
root=Path(sys.argv[1]);paths=list(root.glob('*.zip'));assert paths,'Swift tests produced no ZIP; cannot claim export verified'
results=[]
for path in paths:
    with zipfile.ZipFile(str(path)) as z:
        assert z.testzip() is None
        names=z.namelist();assert len(names)==len(set(names))
        manifest=json.loads(z.read('archive-files.json'));assert manifest['algorithm']=='SHA-256'
        assert {e['path'] for e in manifest['files']}==set(names)-{'archive-files.json'}
        for e in manifest['files']:
            raw=z.read(e['path']);assert len(raw)==e['bytes'] and hashlib.sha256(raw).hexdigest()==e['sha256']
        checklist=json.loads(z.read('export-checklist.json'));assert checklist['complete']
        rows=json.loads(z.read('collection-index.json'))['records'];assert rows
        if path.name=='diagnostic-export.zip':assert not any(r['counted_for_slot'] for r in rows)
        if path.name=='formal-retry-export.zip':
            assert len(rows)==3 and sum(r['counted_for_slot'] for r in rows)==1
            assert {r['assignment']['slot_attempt'] for r in rows}=={1,2,3}
            assert {r['assignment']['record_number'] for r in rows}=={1}
            assert next(r for r in rows if r['counted_for_slot'])['assignment']['slot_attempt']==3
            assert all('/action_01/slot_001/attempt_' in r['archive_path'] for r in rows)
            assert {'operations.jsonl','roster-at-export.json','studies-at-export.json'} <= set(names)
        for row in rows:
            required=json.loads(z.read(row['archive_path']+'/file-integrity-at-export.json'))['required_files']
            assert all(row['archive_path']+'/'+n in names for n in required)
        results.append({'zip':path.name,'status':'passed','files':len(names),'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
(root/'zip-audit.json').write_text(json.dumps(results,indent=2),encoding='utf8');print(json.dumps(results))
