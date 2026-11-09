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
xcrun simctl list devices available --json > build/simulator-devices.json
xcrun simctl list runtimes --json > build/simulator-runtimes.json
simulator_id=$(python3 tools/prepare_simulator.py)
ui_status=0
xcodebuild -project Baduanjin.xcodeproj -scheme Baduanjin -configuration Debug -destination "platform=iOS Simulator,id=$simulator_id" -destination-timeout 60 -derivedDataPath build/ui CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" build-for-testing > build/ui-build.log 2>&1 || { tail -n 100 build/ui-build.log; exit 1; }
test_bundle=$(python3 -c 'from pathlib import Path; p=list(Path("build/ui/Build/Products").glob("*.xctestrun")); assert len(p)==1,p; print(p[0])')
# A targeted confirmation is opt-in; ordinary pushes still run every UI test.
ui_filters=()
if [ "${UI_CONFIRMATION:-false}" = true ]; then
  ui_filters+=("-only-testing:WorkflowUITests/WorkflowUITests/testReadOnlyMonitorAndCalibrationPages")
  ui_filters+=("-only-testing:WorkflowUITests/WorkflowUITests/testFiveTabsTaskPersistenceAndFormalGate")
  ui_filters+=("-only-testing:WorkflowUITests/UILayoutUITests/testMainPagesInLightAndAccessibleDarkAppearance")
fi
# Run the already-built test bundle directly, avoiding a second local-package
# graph resolution while Xcode is starting the simulator test session.
xcodebuild -xctestrun "$test_bundle" -destination "platform=iOS Simulator,id=$simulator_id" -destination-timeout 60 -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 -resultBundlePath build/ui-tests.xcresult "${ui_filters[@]}" test-without-building > build/ui-tests.log 2>&1 || ui_status=$?
xcrun xcresulttool get test-results summary --path build/ui-tests.xcresult > build/ui-test-summary.json || true
xcrun xcresulttool export attachments --path build/ui-tests.xcresult --output-path build/ui-screenshots || true
if [ "$ui_status" -ne 0 ]; then tail -n 100 build/ui-tests.log; exit "$ui_status"; fi
fi
if [ "$stage" = all ] || [ "$stage" = device ]; then
xcodebuild -project Baduanjin.xcodeproj -scheme Baduanjin -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build/device CODE_SIGNING_ALLOWED=NO build > build/device-build.log 2>&1 || { tail -n 100 build/device-build.log; exit 1; }
python3 tools/package_unsigned.py
fi
echo "Completed stage: $stage. Unsigned IPA requires personal signing before installation."
