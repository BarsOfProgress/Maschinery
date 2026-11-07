#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
swift build --disable-sandbox --build-system native --build-tests --arch x86_64 --scratch-path .build/intel-tests
binary_path=$(swift build --disable-sandbox --build-system native --arch x86_64 --scratch-path .build/intel-tests --show-bin-path)
# SwiftPM's new testing helper runs in the host architecture. Explicitly run XCTest under Rosetta.
test_log=$(mktemp -t Maschinery-Intel-XCTest)
trap 'unlink "$test_log"' EXIT
/usr/bin/arch -x86_64 "$(xcrun --find xctest)" "$binary_path/MaschineryPackageTests.xctest" 2>&1 | tee "$test_log"
scripts/check-xctest-log.sh "$test_log"
