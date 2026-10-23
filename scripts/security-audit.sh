#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/security-audit
# Install explicitly: cargo install cargo-audit --version 0.22.2 --locked
# Advisory databases are fetched at run time. Keep results with the reviewed commit.
{
  date -u '+%Y-%m-%dT%H:%M:%SZ'
  git rev-parse HEAD
  git status --short
  rustc --version
  cargo --version
  cargo audit --version
  xcrun swift --version
  xcrun clang --version
  sw_vers
  if command -v node >/dev/null; then node --version; fi
  (cd services && go version)
} > build/security-audit/inventory.txt
cargo metadata --locked --format-version 1 > build/security-audit/cargo-metadata.json
cargo tree --locked > build/security-audit/cargo-tree.txt
cargo audit --json > build/security-audit/rustsec.json
(cd services && GOTOOLCHAIN="$(go env GOVERSION)" go run golang.org/x/vuln/cmd/govulncheck@v1.9.0 -json ./...) > build/security-audit/govulncheck.json
python3 - <<'PY'
import json, pathlib, urllib.request
root = pathlib.Path('build/security-audit')
metadata = json.loads((root / 'cargo-metadata.json').read_text())
queries = [{'package': {'name': p['name'], 'ecosystem': 'crates.io'}, 'version': p['version']} for p in metadata['packages'] if (p.get('source') or '').startswith('registry+')]
for p in metadata['packages']:
    if p['name'] == 'secp256k1-sys':
        revision = (pathlib.Path(p['manifest_path']).parent / 'depend/secp256k1-HEAD-revision.txt').read_text().strip().splitlines()[-1]
        if len(revision) != 40 or any(c not in '0123456789abcdef' for c in revision):
            raise SystemExit('Invalid vendored C revision')
        queries.append({'commit': revision})
request = {'queries': queries}
(root / 'osv-query.json').write_text(json.dumps(request, indent=2) + '\n')
req = urllib.request.Request('https://api.osv.dev/v1/querybatch', data=json.dumps(request).encode(), headers={'Content-Type': 'application/json', 'User-Agent': 'Proximus-source-audit'})
with urllib.request.urlopen(req, timeout=60) as response:
    result = json.load(response)
(root / 'osv-results.json').write_text(json.dumps(result, indent=2) + '\n')
findings = [{'query': query, 'vulns': entry['vulns']} for query, entry in zip(queries, result['results'], strict=True) if entry.get('vulns')]
print(json.dumps({'queries': len(queries), 'matches_requiring_review': findings}, indent=2))
# Do not automatically ignore inferred C commit matches. Review package identity
# and upstream patches, including the CVE-2021-38195 mapping described in README.
if findings:
    raise SystemExit('OSV matches require manual applicability review. See README security review.')
PY
printf '%s\n' 'Dependency reports written to build/security-audit. Run scripts/verify.sh --apple for tests and builds.'
