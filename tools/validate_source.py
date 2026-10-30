"""Structural checks only. This does not pretend to compile Swift or test CoreBluetooth."""
import hashlib,json,plistlib,re,sys,xml.etree.ElementTree as ET
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def balanced(text,path):
    pairs={'(':')','[':']','{':'}'}
    def string(i):
        i+=1
        while i<len(text):
            if text[i]=='"':return i+1
            if text[i]=='\\':
                if i+1<len(text) and text[i+1]=='(':i=code(i+2,')')
                else:i+=2
            else:i+=1
        raise AssertionError('Unclosed Swift string: '+path)
    def code(i,closing=None):
        opened=text[:i].count('\n')+1
        while i<len(text):
            if text.startswith('//',i):
                end=text.find('\n',i);i=len(text) if end<0 else end+1;continue
            if text.startswith('/*',i):
                end=text.find('*/',i+2);assert end>=0,path;i=end+2;continue
            c=text[i]
            if c=='"':i=string(i);continue
            if c in pairs:i=code(i+1,pairs[c]);continue
            if c in ')]}':
                assert c==closing,'%s: unexpected %s at line %d'%(path,c,text[:i].count('\n')+1)
                return i+1
            i+=1
        assert closing is None,'Unclosed delimiter '+str(closing)+' opened at line '+str(opened)+' in '+path
        return i
    code(0)
swift=list((ROOT/'Sources').rglob('*.swift'))+list((ROOT/'Tests').glob('*.swift'))+[ROOT/'Package.swift']
for file in swift:balanced(file.read_text(encoding='utf8'),file.relative_to(ROOT).as_posix())
with (ROOT/'Info.plist').open('rb') as f:info=plistlib.load(f)
assert info['NSBluetoothAlwaysUsageDescription'] and info['UIFileSharingEnabled']
assert 'UIBackgroundModes' not in info
project=(ROOT/'Baduanjin.xcodeproj/project.pbxproj').read_text(encoding='utf8')
assert 'dev.imulink.baduanjin.ios' in project
for p in (ROOT/'Sources/iOS').glob('*.swift'):assert p.relative_to(ROOT).as_posix() in project
ET.parse(str(ROOT/'Baduanjin.xcodeproj/xcshareddata/xcschemes/Baduanjin.xcscheme'))
fixture=json.loads((ROOT/'Tests/Fixtures/protocol-vectors.json').read_text(encoding='utf8'))
assert len(fixture['cases'])>=100
for case in fixture['cases']:
    for f in case['expected']['frames']:assert len(bytes.fromhex(f['hex']))==20 and len(f['words']) in (8,9)
ble=(ROOT/'Sources/iOS/BluetoothEngine.swift').read_text(encoding='utf8')
assert 'canSendWriteWithoutResponse' in ble and 'WitProtocol.read(reg)' in ble
assert '0xb588' not in ble.lower() and 'placement_confirmed' not in ble
workflow=(ROOT/'.github/workflows/ios-build.yml').read_text(encoding='utf8')
assert 'workflow_dispatch:' in workflow and 'secrets.' not in workflow
result={'status':'passed','checks':'Swift delimiter structure, plist, project references, fixtures, read-only initial BLE boundary; NOT Swift compilation or test execution','swift_files_checked':len(swift),'java_oracle_cases':len(fixture['cases']),'expected_frames':sum(len(c['expected']['frames']) for c in fixture['cases']),'swift_tests_executed':False,'xcode_build_executed':False,'iphone_app_installed':False}
out=ROOT/'build';out.mkdir(exist_ok=True);(out/'source-validation.json').write_text(json.dumps(result,indent=2),encoding='utf8');print(json.dumps(result))
