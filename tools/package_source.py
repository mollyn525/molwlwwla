"""Allowlisted source-only handoff. Never package Android recordings or Apple credentials."""
import hashlib,json,zipfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
allowed=['README.md','Package.swift','Info.plist','.gitignore','Sources','Tests','tools','.github','Baduanjin.xcodeproj']
files=[]
for name in allowed:
    p=ROOT/name
    files += [p] if p.is_file() else [f for f in p.rglob('*') if f.is_file() and '__pycache__' not in f.parts]
assert not any(p.suffix in ('.p12','.p8','.mobileprovision','.ipa','.tar') for p in files)
out=ROOT/'build/output';out.mkdir(parents=True,exist_ok=True)
archive=out/'baduanjin-ios-0.1.0-dev-source.zip'
manifest=[]
with zipfile.ZipFile(str(archive),'w',zipfile.ZIP_DEFLATED) as z:
    for p in sorted(files):
        raw=p.read_bytes();name=p.relative_to(ROOT).as_posix();z.writestr(name,raw)
        manifest.append({'path':name,'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()})
    z.writestr('source-manifest.json',json.dumps({'algorithm':'SHA-256','files':manifest},indent=2))
with zipfile.ZipFile(str(archive)) as z:
    assert z.testzip() is None
    for e in manifest:assert hashlib.sha256(z.read(e['path'])).hexdigest()==e['sha256']
result={'artifact':archive.name,'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'files':len(manifest),'swift_compiled':False,'swift_tests_executed':False,'iphone_installed':False,'cloud_upload_performed':False,'formal_capture_enabled':False,'hardware_writes_enabled':False}
(out/'source-handoff.json').write_text(json.dumps(result,indent=2),encoding='utf8');print(json.dumps(result))
