#!/usr/bin/env python3
"""Real CLI execution against synthetic fixtures. Never touches an Apple device."""
import hashlib
import json
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import sys
import tempfile


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit('Usage: cli-smoke.py /path/to/rrdevice')
    binary = str(Path(sys.argv[1]).resolve(strict=True))
    records = []
    with tempfile.TemporaryDirectory(prefix='rrdevice-CLI-SYNTHETIC-') as tmp:
        root = Path(tmp)
        backup = root / 'backup'
        backup.mkdir(mode=0o700)
        uid = '00008101-1234567890123456'
        fid = 'a' * 40
        payload = b'SYNTHETIC CLI TEST DATA, NOT AN IPHONE BACKUP\n'
        for filename, obj in {
            'Info.plist': {'Unique Identifier': uid, 'Device Name': 'SYNTHETIC CLI FIXTURE', 'Product Version': '27.0'},
            'Manifest.plist': {'IsEncrypted': False},
            'Status.plist': {'SnapshotState': 'finished'},
        }.items():
            (backup / filename).write_bytes(plistlib.dumps(obj))
        with sqlite3.connect(backup / 'Manifest.db') as db:
            db.execute('CREATE TABLE Files(fileID TEXT,domain TEXT,relativePath TEXT,flags INTEGER,file BLOB)')
            db.execute('INSERT INTO Files VALUES(?,?,?,?,?)', (fid, 'CameraRollDomain', 'Media/DCIM/test.txt', 1, None))
        (backup / 'aa').mkdir()
        (backup / 'aa' / fid).write_bytes(payload)

        def run(label: str, arguments: list[str], expected: int = 0) -> subprocess.CompletedProcess:
            p = subprocess.run([binary, *arguments], capture_output=True, text=True, timeout=30, check=False)
            records.append({'check': label, 'expectedExit': expected, 'actualExit': p.returncode,
                            'result': 'PASS' if p.returncode == expected else 'FAIL',
                            'stdout': p.stdout.strip(), 'stderr': p.stderr.strip()})
            if p.returncode != expected:
                raise AssertionError(json.dumps(records[-1], ensure_ascii=False))
            return p

        run('CLI help', [])
        meta = json.loads(run('inspect synthetic backup', ['inspect', str(backup)]).stdout)
        assert meta['deviceName'] == 'SYNTHETIC CLI FIXTURE' and meta['encrypted'] is False
        rows = json.loads(run('list real SQLite fixture', ['files', str(backup)]).stdout)
        assert len(rows) == 1 and rows[0]['fileID'] == fid
        empty = json.loads(run('search literal SQL text', ['files', str(backup), "' OR 1=1 --"]).stdout)
        assert empty == []
        destination = root / 'export.txt'
        run('export original bytes', ['export', str(backup), fid, str(destination)])
        assert destination.read_bytes() == payload
        run('prevent overwrite', ['export', str(backup), fid, str(destination)], expected=1)
        report = root / 'integrity.json'
        run('create baseline', ['baseline', str(backup), str(report)])
        run('prevent report overwrite', ['baseline', str(backup), str(report)], expected=1)
        run('verify unchanged files', ['verify', str(backup), str(report)])
        report_obj = json.loads(report.read_text())
        assert report_obj['restoreTested'] is False and report_obj['originalAuthenticityVerified'] is False
        assert any(x['digest']['sha256'] == hashlib.sha256(payload).hexdigest() for x in report_obj['files'])
        (backup / 'aa' / fid).write_bytes(payload + b'TAMPER')
        run('detect changed bytes', ['verify', str(backup), str(report)], expected=1)
        run('restore release gate', ['restore'], expected=1)
        run('reject unknown command', ['pretend-success'], expected=1)
    print(json.dumps({'fixture': 'SYNTHETIC, not an actual iOS 27 device',
                      'checks': records, 'total': len(records), 'result': 'PASS'}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
