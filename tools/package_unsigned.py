import hashlib,json,plistlib,zipfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];app=ROOT/'build/device/Build/Products/Release-iphoneos/Baduanjin.app'
assert (app/'Baduanjin').is_file(),'No compiled iPhone app; refusing placeholder IPA'
with (app/'Info.plist').open('rb') as f:info=plistlib.load(f)
assert info['CFBundleIdentifier']=='dev.imulink.baduanjin.ios'
out=ROOT/'build/output';out.mkdir(parents=True,exist_ok=True)
ipa=out/('baduanjin-ios-'+info['CFBundleShortVersionString']+'-unsigned.ipa')
with zipfile.ZipFile(str(ipa),'w',zipfile.ZIP_DEFLATED) as z:
    for file in sorted(app.rglob('*')):
        if file.is_file():z.write(str(file),'Payload/Baduanjin.app/'+file.relative_to(app).as_posix())
result={'ipa':ipa.name,'sha256':hashlib.sha256(ipa.read_bytes()).hexdigest(),'bundle_id':info['CFBundleIdentifier'],'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'signed':False,'installable_without_resigning':False,'real_iphone_validated':False,'calibration_enabled':False,'formal_capture_enabled':False}
(out/'build-info.json').write_text(json.dumps(result,indent=2),encoding='utf8');print(json.dumps(result))
