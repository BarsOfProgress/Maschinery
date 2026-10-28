#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
test_log=$(mktemp -t MaschineMachine-XCTest)
trap 'unlink "$test_log"' EXIT
swift test --disable-sandbox --enable-xctest --disable-swift-testing 2>&1 | tee "$test_log"
scripts/check-xctest-log.sh "$test_log"
