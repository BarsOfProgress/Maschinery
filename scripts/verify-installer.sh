#!/bin/zsh
# Expand, inspect and verify without executing Installer scripts or touching system paths.
set -euo pipefail
cd "${0:A:h}/.."
version=$(/usr/libexec/PlistBuddy -c 'Print :MaschineryReleaseVersion' dist/Maschinery.app/Contents/Info.plist 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Maschinery.app/Contents/Info.plist)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/Maschinery-PKG-Verify.XXXXXXXX")
trap 'rm -rf -- "$workspace"' EXIT
pkgutil --expand-full "dist/Maschinery-v$version-Full-Install.pkg" "$workspace/install"
pkgutil --expand-full "dist/Maschinery-v$version-Remove-Helper.pkg" "$workspace/remove"
python3 - "$workspace" <<'PY'
import hashlib, json, pathlib, plistlib, subprocess, sys, xml.etree.ElementTree as ET
root = pathlib.Path(sys.argv[1])
payload = root/'install/Payload/Library/Application Support/Maschinery/InstallerPayload'
info = ET.parse(root/'install/PackageInfo').getroot()
assert info.attrib['auth'] == 'root' and info.attrib['relocatable'] == 'false'
assert not list(info.find('relocate')), 'Bundle relocation must be disabled'
for row in subprocess.check_output(['/usr/bin/lsbom', '-p', 'fmug', str(root/'install/Bom')], text=True).splitlines():
    name, mode, uid, gid = row.split('\t')
    assert uid == '0' and gid == '0', f'Payload owner must be root:wheel: {name}'
    assert int(mode, 8) & 0o022 == 0, f'Writable payload: {name}'
remove_info = ET.parse(root/'remove/PackageInfo').getroot()
assert remove_info.attrib['auth'] == 'root'
with (payload/'Maschinery.app/Contents/Info.plist').open('rb') as f: app_info = plistlib.load(f)
release_version = app_info.get('MaschineryReleaseVersion', app_info['CFBundleShortVersionString'])
assert app_info['CFBundleShortVersionString'] == release_version.split('r')[0]
assert info.attrib['version'] == release_version.replace('r', '.')
trust = json.loads((payload/'InstalledHelper/trust.json').read_text())
assert trust['version'] == 1
peers = [(payload/'Maschinery.app', 'appHashes', 'local.maschinery.app'),
         (payload/'InstalledHelper/MaschineryHelper', 'helperHashes', 'local.maschinery.helper'),
         (payload/'InstalledHelper/MaschinerySetup', 'setupHashes', 'local.maschinery.setup')]
for path, key, identifier in peers:
    assert trust[key] and all(len(h) == 40 and set(h) <= set('0123456789abcdef') for h in trust[key])
    expression = f'identifier "{identifier}" and (' + ' or '.join(f'cdhash H"{h}"' for h in trust[key]) + ')'
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--all-architectures', '-R', '=' + expression, str(path)], check=True)
    executable = path/'Contents/MacOS/Maschinery' if path.suffix == '.app' else path
    assert set(subprocess.check_output(['/usr/bin/lipo', '-archs', str(executable)], text=True).split()) == {'arm64','x86_64'}
setup_hash = hashlib.sha256((payload/'InstalledHelper/MaschinerySetup').read_bytes()).digest()
for path in [root/'install/Scripts/MaschinerySetup', root/'remove/Scripts/MaschinerySetup']:
    assert hashlib.sha256(path.read_bytes()).digest() == setup_hash, 'Package scripts must run the matching setup build'
with (payload/'local.maschinery.helper.plist').open('rb') as f: daemon = plistlib.load(f)
assert daemon['ProgramArguments'] == ['/Library/Application Support/Maschinery/InstalledHelper/MaschineryHelper']
assert daemon['MachServices'] == {'local.maschinery.helper': True} and daemon['UserName'] == 'root'
assert 'BundleProgram' not in daemon
print('Verified package staging, peer hashes, Universal binaries, setup copies and root daemon definition.')
PY
(cd dist && shasum -a 256 -c "Maschinery-v$version-Full-Install.pkg.sha256" && shasum -a 256 -c "Maschinery-v$version-Remove-Helper.pkg.sha256")
