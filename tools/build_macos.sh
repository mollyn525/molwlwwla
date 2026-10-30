#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcodebuild -version | tee build/xcode-version.txt
python3 tools/generate_project.py
python3 tools/validate_source.py
export IMU_TEST_ARTIFACT_DIR="$PWD/build/test-artifacts"
swift test --parallel 2>&1 | tee build/swift-tests.log
python3 tools/check_test_exports.py "$IMU_TEST_ARTIFACT_DIR"
xcodebuild -project Baduanjin.xcodeproj -scheme Baduanjin -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build/simulator CODE_SIGNING_ALLOWED=NO build > build/simulator-build.log 2>&1 || { tail -n 100 build/simulator-build.log; exit 1; }
xcodebuild -project Baduanjin.xcodeproj -scheme Baduanjin -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build/device CODE_SIGNING_ALLOWED=NO build > build/device-build.log 2>&1 || { tail -n 100 build/device-build.log; exit 1; }
python3 tools/package_unsigned.py
echo 'Build and tests passed. Unsigned IPA requires personal signing before installation.'
