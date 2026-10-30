"""Build deidentified protocol vectors using the unchanged Java production parser."""
import hashlib,json,subprocess,tarfile,struct,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];PARENT=ROOT.parent
android=PARENT/'baduanjin_wit/app/src/main/java/dev/imulink/baduanjin/wit'
build=ROOT/'build/oracle';build.mkdir(parents=True,exist_ok=True)
tar=PARENT/'baduanjin_wit/evidence/phone/seven-120s.tar'
chunks=[]
with tarfile.open(str(tar)) as ar:
    item=next(m for m in ar.getmembers() if m.name.endswith('/notifications.jsonl'))
    for line in ar.extractfile(item):
        chunks.append(json.loads(line)['hex'])
        if len(chunks)==160:break
cases=[[chunk] for chunk in chunks]
frame=bytes.fromhex('5561')+struct.pack('<9h',-32768,32767,-1,0,1,-2,1234,-1234,0)
for split in range(21):cases.append([frame[:split].hex(),frame[split:].hex()])
cases.extend([['00995500'+frame.hex()+'55'],[frame.hex()+frame.hex()],['55','71','510000400000000000000000000000000000'],['001122','55']])
source=build/'inputs.txt';source.write_text('\n'.join('|'.join(c) for c in cases)+'\n',encoding='ascii')
jdk=PARENT/'tools/jdk/bin'
subprocess.run([str(jdk/'javac.exe'),'-encoding','UTF-8','-d',str(build),str(android/'Protocol.java'),str(android/'WitProtocol.java'),str(ROOT/'tools/ProtocolOracle.java')],check=True)
raw=subprocess.check_output([str(jdk/'java.exe'),'-cp',str(build),'dev.imulink.baduanjin.wit.ProtocolOracle',str(source)]).decode()
expected=[json.loads(line) for line in raw.splitlines()];assert len(expected)==len(cases)
fixture={'origin':'unchanged Android production Protocol.Parser; only notification bytes, no MAC addresses, subjects, or timestamps','source_hashes':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [android/'Protocol.java',android/'WitProtocol.java']},'cases':[{'chunks':c,'expected':e} for c,e in zip(cases,expected)]}
java_protocol=(android/'Protocol.java').read_text(encoding='utf8')
fixture['gatt']={key.lower():re.search(r'public static final String '+key+r'="([0-9a-f-]+)"',java_protocol).group(1) for key in ['SERVICE','NOTIFY','WRITE']}
out=ROOT/'Tests/Fixtures';out.mkdir(parents=True,exist_ok=True)
(out/'protocol-vectors.json').write_text(json.dumps(fixture,ensure_ascii=False,indent=2),encoding='utf8')
print('Java oracle generated',len(cases),'cases and',sum(len(e['frames']) for e in expected),'frames; included GATT constants from Android production source; Swift comparison awaits Mac')
