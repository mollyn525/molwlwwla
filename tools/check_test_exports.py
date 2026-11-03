"""Independent ZIP implementation verifies actual output of the Swift exporter tests."""
import hashlib,json,sys,zipfile,csv,io
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
                expected = 'four_streams_gte30_v1' if row['assignment']['slot_attempt']==1 else 'inertial_gt40_v2'
                for name in ['metadata.json','summary.json']:
                    policy=json.loads(z.read(row['archive_path']+'/'+name))['quality_policy']
                    assert policy['id']==expected
                    assert policy['average_hz_comparison']==('>=' if row['assignment']['slot_attempt']==1 else '>')
        for row in rows:
            required=json.loads(z.read(row['archive_path']+'/file-integrity-at-export.json'))['required_files']
            assert all(row['archive_path']+'/'+n in names for n in required)
            txt=[n for n in names if n.startswith(row['archive_path']+'/TXT/') and n.endswith('.txt')]
            assert len(txt)==1
            header=z.read(txt[0]).decode('utf8').splitlines()[0].split('\t')
            assert len(header)==27 and header[:2]==['时间','设备名称'] and header[-1]=='电量(%)'
            assert json.loads(z.read(row['archive_path']+'/TXT/format.json'))['used_for_quality_hz'] is False
        results.append({'zip':path.name,'status':'passed','files':len(names),'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
(root/'zip-audit.json').write_text(json.dumps(results,indent=2),encoding='utf8');print(json.dumps(results))
raw=(root/'compatibility.txt').read_bytes()
assert not raw.startswith(b'\xef\xbb\xbf') and raw.count(b'\r\n')==4 and raw.count(b'\n')==4
table=list(csv.reader(io.StringIO(raw.decode('utf8')),delimiter='\t'))
assert all(len(row)==27 for row in table) and table[1][0]=='1970-01-01T08:00:01.200'
assert table[1][11:14]==['-1.000','2.000','3.000'] and table[1][20]==table[2][20]=='0.99997'
assert table[3][20]=='null' and all(row[26]=='null' for row in table[1:])
sources=list(csv.DictReader(io.StringIO((root/'compatibility-source-times.csv').read_text(encoding='utf8'))))
assert len(sources)==3 and sources[1]['quaternion_ns']=='200000000' and sources[1]['quaternion_stale']=='true'
(root/'txt-audit.json').write_text(json.dumps({'status':'passed','columns':27,'data_rows':3,'cached_values_have_source_times':True,'not_used_for_hz':True},indent=2),encoding='utf8')
