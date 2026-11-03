#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
stage="${1:-all}"
if [ "$stage" = all ] || [ "$stage" = core ]; then
xcodebuild -version | tee build/xcode-version.txt
xcodebuild -showsdks > build/xcode-sdks.txt
python3 tools/generate_project.py
python3 tools/validate_source.py
export IMU_TEST_ARTIFACT_DIR="$PWD/build/test-artifacts"
swift test --parallel --xunit-output build/swift-tests.xml 2>&1 | tee build/swift-tests.log
python3 tools/check_test_exports.py "$IMU_TEST_ARTIFACT_DIR"
fi
if [ "$stage" = all ] || [ "$stage" = simulator ]; then
xcodebuild -project Baduanjin.xcodeproj -scheme Baduanjin -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build/simulator CODE_SIGNING_ALLOWED=NO build > build/simulator-build.log 2>&1 || { tail -n 100 build/simulator-build.log; exit 1; }
fi
if [ "$stage" = all ] || [ "$stage" = ui ]; then
simulator_id=$(xcrun simctl list devices available --json | python3 -c 'import sys,json; d=json.load(sys.stdin)["devices"]; keys=sorted((k for k in d if "iOS" in k),key=lambda k:(not k.endswith("iOS-26-0"),k)); print(next(x["udid"] for k in keys for x in d[k] if "iPhone" in x["name"]))')
ui_status=0
xcodebuild -project Baduanjin.xcodeproj -scheme Baduanjin -configuration Debug -destination "platform=iOS Simulator,id=$simulator_id" -parallel-testing-enabled NO -derivedDataPath build/ui -resultBundlePath build/ui-tests.xcresult CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" test > build/ui-tests.log 2>&1 || ui_status=$?
xcrun xcresulttool get test-results summary --path build/ui-tests.xcresult > build/ui-test-summary.json || true
xcrun xcresulttool export attachments --path build/ui-tests.xcresult --output-path build/ui-screenshots || true
if [ "$ui_status" -ne 0 ]; then tail -n 100 build/ui-tests.log; exit "$ui_status"; fi
fi
if [ "$stage" = all ] || [ "$stage" = device ]; then
xcodebuild -project Baduanjin.xcodeproj -scheme Baduanjin -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build/device CODE_SIGNING_ALLOWED=NO build > build/device-build.log 2>&1 || { tail -n 100 build/device-build.log; exit 1; }
python3 tools/package_unsigned.py
fi
echo "Completed stage: $stage. Unsigned IPA requires personal signing before installation."
