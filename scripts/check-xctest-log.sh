#!/bin/zsh
set -euo pipefail
log_path="${1:?Supply the XCTest output file}"
started=$(awk '/^Test Case .* started\./ { n++ } END { print n+0 }' "$log_path")
passed=$(awk '/^Test Case .* passed / { n++ } END { print n+0 }' "$log_path")
skipped=$(awk '/^Test Case .* skipped / { n++ } END { print n+0 }' "$log_path")
started=${started:-0}
passed=${passed:-0}
skipped=${skipped:-0}
if (( started == 0 || passed == 0 || started != passed + skipped )); then
  print -u2 "XCTest validation failed: $started started, $passed passed, $skipped skipped. Zero-test runs are not accepted."
  exit 1
fi
print "VALIDATED XCTest: $started started, $passed passed, $skipped skipped."
