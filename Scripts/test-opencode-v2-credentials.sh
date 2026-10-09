#!/bin/zsh
set -euo pipefail
repo_root=${0:A:h:h}
fixture_dir=$(/usr/bin/mktemp -d /private/tmp/codenotch-opencode-test.XXXXXX)
trap '/bin/rm -rf "$fixture_dir"' EXIT
python3 - "$fixture_dir" <<'PY'
import json, pathlib, sqlite3, sys
root = pathlib.Path(sys.argv[1])
cases = {
    'active': [('opencode', 0, {'type': 'key', 'key': 'inactive'}), ('deepseek', 1, {'type': 'key', 'key': 'other'}), ('opencode', 1, {'type': 'key', 'key': 'current-go'})],
    'go': [('opencode-go', 1, {'type': 'key', 'key': 'current-go'})],
    'mixed': [('opencode', 1, {'type': 'key', 'key': 'one'}), ('opencode-go', 1, {'type': 'key', 'key': 'two'})],
    'go-oauth': [('opencode-go', 1, {'type': 'oauth', 'access': 'not-a-go-key'})],
    'oauth': [('opencode', 1, {'type': 'oauth', 'access': 'not-a-go-key'})],
    'ambiguous': [('opencode', 1, {'type': 'key', 'key': 'one'}), ('opencode', 1, {'type': 'key', 'key': 'two'})],
    'legacy': [],
    'malformed': [('opencode', 1, {'type': 'key', 'key': ''})],
}
for name, rows in cases.items():
    path = root / name
    path.mkdir()
    auth = {'opencode-go': {'type': 'api', 'key': 'old-go'}} if name in ['active', 'legacy'] else {}
    (path / 'auth.json').write_text(json.dumps(auth))
    db = sqlite3.connect(path / 'opencode.db')
    db.execute('CREATE TABLE credential (integration_id TEXT, active INTEGER, value TEXT)')
    db.executemany('INSERT INTO credential VALUES (?,?,?)', [(i,a,json.dumps(v)) for i,a,v in rows])
    db.commit()
    db.close()
PY
cat > "$fixture_dir/main.swift" <<'SWIFT'
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
var failures = 0
for (name, expected) in [("active", "current-go"), ("go", "current-go"), ("mixed", nil), ("go-oauth", nil), ("oauth", nil), ("ambiguous", nil), ("legacy", "old-go"), ("malformed", nil)] as [(String, String?)] {
    let folder = root.appendingPathComponent(name)
    let dbURL = folder.appendingPathComponent("opencode.db")
    let before = try Data(contentsOf: dbURL)
    let actual = OpenCodeCredentials.load(from: folder.appendingPathComponent("auth.json"))?.token
    if actual != expected { print("FAIL: \(name) credential selection"); failures += 1 }
    if try Data(contentsOf: dbURL) != before { print("FAIL: \(name) database modified"); failures += 1 }
}
guard failures == 0 else { exit(1) }
print("PASS: eight OpenCode credential cases; databases unchanged")
SWIFT
/usr/bin/swiftc -module-cache-path "$fixture_dir/module-cache" "$repo_root/Sources/Providers/SQLiteStore.swift" \
    "$repo_root/Sources/Providers/OpenCodeCredentials.swift" \
    "$fixture_dir/main.swift" -lsqlite3 -o "$fixture_dir/test"
"$fixture_dir/test" "$fixture_dir"
