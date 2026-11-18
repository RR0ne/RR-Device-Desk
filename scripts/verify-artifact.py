#!/usr/bin/env python3
"""Record actual local checks; not a replacement for macOS/hardware acceptance."""
import datetime
import json
from pathlib import Path
import platform
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
evidence = root / 'evidence'
evidence.mkdir(exist_ok=True)
checks = []
steps = [
    ('core-tests', ['swift', 'test'], 0, 'tests-final.log'),
    ('release-CLI-build', ['swift', 'build', '-c', 'release', '--product', 'rrdevice'], 0, 'release-build-final.log'),
    ('SwiftUI-syntax-only', ['swiftc', '-frontend', '-parse', *[str(p.relative_to(root)) for p in sorted((root/'Sources/RRDeviceDesk').glob('*.swift'))]], 0, 'macos-ui-syntax.log'),
    ('shell-syntax', ['bash', '-n', 'scripts/build-macos.sh', 'scripts/test-local.sh'], 0, 'shell-syntax.log'),
    ('CLI-synthetic-smoke', [sys.executable, 'scripts/cli-smoke.py', '.build/release/rrdevice'], 0, 'cli-smoke.json'),
    ('doctor-observation', ['.build/release/rrdevice', 'doctor'], 0, 'doctor-linux.json'),
]
if platform.system() == 'Linux':
    steps.append(('macOS-build-rejects-wrong-host', ['bash', 'scripts/build-macos.sh'], 2, 'macos-build-host-guard.log'))
for name, cmd, expected, log in steps:
    started = datetime.datetime.now(datetime.timezone.utc)
    proc = subprocess.run(cmd, cwd=root, capture_output=True, text=True, timeout=180, check=False)
    output = proc.stdout + proc.stderr
    (evidence/log).write_text(output)
    item = {'name': name, 'command': cmd, 'startedAt': started.isoformat(),
            'exitCode': proc.returncode, 'expectedExitCode': expected,
            'status': 'PASS' if proc.returncode == expected else 'FAIL', 'evidence': log}
    if name == 'core-tests':
        counts = re.findall(r'Executed (\d+) tests, with (\d+) failures', output)
        if counts: item['xctestCount'], item['failures'] = map(int, counts[-1])
    if name == 'SwiftUI-syntax-only':
        item['limitation'] = 'No macOS SDK/type checking/linking/rendering; syntax parse ONLY'
    if name == 'doctor-observation':
        item['limitation'] = 'Tool reported missing dependencies on this Linux host; not a successful device operation'
    checks.append(item)
    print(name, item['status'], proc.returncode)
    if proc.returncode != expected:
        print(output[-4000:])
        raise SystemExit(1)
manifest = {'generatedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'environment': {'system': platform.system(), 'architecture': platform.machine()},
            'checks': checks,
            'notRun': ['macOS SDK build', 'SwiftUI GUI launch/render/interaction', 'macOS CryptoKit path',
                       'Keychain write/read permissions', 'USB and Wi-Fi physical device', 'Actual encrypted backup',
                       'Actual iOS/iPadOS 27 content verification', 'Any restore to a device', 'Power-loss durability',
                       'Large real-world corpus and performance', 'Mac packaging/codesign execution']}
(evidence/'checks.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
