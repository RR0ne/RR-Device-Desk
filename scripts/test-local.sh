#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test
swift build -c release --product rrdevice
# Optional developer smoke suite requires Python 3; not a runtime dependency.
if command -v python3 >/dev/null 2>&1; then
  python3 scripts/cli-smoke.py "$(swift build -c release --show-bin-path)/rrdevice"
fi
