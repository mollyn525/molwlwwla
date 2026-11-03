"""Boot one CI simulator compatible with this Xcode's SDK before UI tests."""
import json, subprocess, sys
from pathlib import Path

root = Path('build')
devices = json.loads((root/'simulator-devices.json').read_text())['devices']
runtimes = json.loads((root/'simulator-runtimes.json').read_text())['runtimes']
sdk = subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-version'], text=True).strip()
sdk_pair = tuple(sdk.split('.')[:2])
compatible = [r for r in runtimes if r.get('isAvailable') and '.iOS-' in r['identifier'] and tuple(r['version'].split('.')[:2]) == sdk_pair]
assert compatible, 'No simulator runtime matching selected Xcode SDK '+sdk
runtime = max(compatible, key=lambda r:tuple(map(int,r['version'].split('.'))))
device = next(d for d in devices[runtime['identifier']] if 'iPhone' in d['name'] and d.get('isAvailable'))
udid = device['udid']
(root/'simulator-selected.json').write_text(json.dumps({'sdk':sdk,'runtime':runtime,'device':device},indent=2))
with (root/'simulator-boot.log').open('w') as log:
    if device['state'] != 'Booted':
        subprocess.run(['xcrun','simctl','boot',udid],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=60)
    subprocess.run(['xcrun','simctl','bootstatus',udid,'-b'],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=180)
print('Booted '+device['name']+' iOS '+runtime['version'],file=sys.stderr)
print(udid)
