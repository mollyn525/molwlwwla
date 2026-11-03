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
# Hosted images contain pre-created device data that can stall before bootstatus
# emits its first line. Create an isolated profile for each job, matching the
# target phone, rather than reusing that inherited simulator state.
types = runtime['supportedDeviceTypes']
device_type = next(t for t in types if t['identifier'] == 'com.apple.CoreSimulator.SimDeviceType.iPhone-16')
udid = subprocess.check_output(['xcrun','simctl','create','Baduanjin CI iPhone 16',device_type['identifier'],runtime['identifier']],text=True,timeout=60).strip()
device = {'udid':udid,'name':'Baduanjin CI iPhone 16','deviceTypeIdentifier':device_type['identifier'],'state':'Shutdown','created_for_job':True}
(root/'simulator-selected.json').write_text(json.dumps({'sdk':sdk,'runtime':runtime,'device':device},indent=2))
with (root/'simulator-boot.log').open('w') as log:
    try:
        subprocess.run(['xcrun','simctl','boot',udid],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=60)
        subprocess.run(['xcrun','simctl','bootstatus',udid,'-b'],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=300)
    except (subprocess.TimeoutExpired,subprocess.CalledProcessError):
        with (root/'simulator-boot-diagnostics.log').open('w') as diagnostics:
            for command in [
                ['xcrun','simctl','list','devices','--json'],
                ['log','show','--last','5m','--style','compact','--predicate','process CONTAINS "Simulator"']
            ]:
                try: subprocess.run(command,stdout=diagnostics,stderr=subprocess.STDOUT,timeout=20)
                except subprocess.TimeoutExpired: diagnostics.write('Diagnostic command timed out\n')
        raise
print('Booted '+device['name']+' iOS '+runtime['version'],file=sys.stderr)
print(udid)
