#!/bin/zsh
# Build an unsigned macOS Installer package; no Apple account is required.
set -euo pipefail
cd "${0:A:h}/.."
app="$PWD/dist/Maschinery.app"
setup="$PWD/dist/MaschinerySetup"
[[ -d "$app" && -f "$setup" ]] || { print -u2 'Run scripts/build-app.sh first.'; exit 1; }
codesign --verify --deep --strict --all-architectures "$app"
codesign --verify --strict --all-architectures "$setup"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || exit 1
workspace=$(mktemp -d "${TMPDIR:-/tmp}/Maschinery-PKG.XXXXXXXX")
trap 'rm -rf -- "$workspace"' EXIT
payload="$workspace/root/Library/Application Support/Maschinery/InstallerPayload"
mkdir -p "$payload/InstalledHelper" "$workspace/scripts" "$workspace/uninstall-scripts"
ditto "$app" "$payload/Maschinery.app"
cp "$app/Contents/Library/LaunchServices/MaschineryHelper" "$payload/InstalledHelper/MaschineryHelper"
cp "$setup" "$payload/InstalledHelper/MaschinerySetup"
# Package scripts execute their own copy, not a pathname supplied by the GUI.
cp "$setup" "$workspace/scripts/MaschinerySetup"
cp "$setup" "$workspace/uninstall-scripts/MaschinerySetup"
python3 - "$app" "$payload" <<'PY'
import json, pathlib, plistlib, re, subprocess, sys
app, payload = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
def hashes(path):
    values = set()
    entitlements = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(path)], capture_output=True, check=True).stdout
    if entitlements.strip():
        parsed = plistlib.loads(entitlements)
        forbidden = ['com.apple.security.get-task-allow', 'com.apple.security.cs.disable-library-validation',
                     'com.apple.security.cs.allow-dyld-environment-variables', 'com.apple.security.cs.allow-unsigned-executable-memory',
                     'com.apple.security.cs.allow-jit', 'com.apple.security.cs.debugger']
        if any(parsed.get(key) for key in forbidden):
            raise SystemExit('Unsafe runtime entitlement in installed peer')
    for arch in ('arm64', 'x86_64'):
        result = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', '--arch', arch, str(path)], capture_output=True, text=True, check=True)
        match = re.search(r'^CDHash=([a-f0-9]{40})$', result.stderr, re.M)
        if not match: raise SystemExit('Missing code signature hash')
        if not re.search(r'^CodeDirectory .*flags=.*\bruntime\b', result.stderr, re.M):
            raise SystemExit('Hardened runtime is required for installed peers')
        values.add(match[1])
    return sorted(values)
trust = {'version': 1, 'appHashes': hashes(app), 'helperHashes': hashes(app/'Contents/Library/LaunchServices/MaschineryHelper'), 'setupHashes': hashes(payload/'InstalledHelper/MaschinerySetup')}
(payload/'InstalledHelper/trust.json').write_text(json.dumps(trust, indent=2)+'\n')
plist = {'Label':'local.maschinery.helper', 'ProgramArguments':['/Library/Application Support/Maschinery/InstalledHelper/MaschineryHelper'],
         'MachServices':{'local.maschinery.helper':True}, 'ProcessType':'Interactive', 'RunAtLoad':False, 'UserName':'root', 'Umask':0o077}
with (payload/'local.maschinery.helper.plist').open('wb') as f: plistlib.dump(plist, f)
PY
cat > "$workspace/scripts/preinstall" <<'SCRIPT'
#!/bin/sh
set -eu
[ "$3" = / ] || { echo 'Install on the current startup volume only.' >&2; exit 1; }
exec "$(dirname "$0")/MaschinerySetup" prepare
SCRIPT
cat > "$workspace/scripts/postinstall" <<'SCRIPT'
#!/bin/sh
set -eu
[ "$3" = / ] || exit 1
exec "$(dirname "$0")/MaschinerySetup" install
SCRIPT
cat > "$workspace/uninstall-scripts/postinstall" <<'SCRIPT'
#!/bin/sh
set -eu
[ "$3" = / ] || exit 1
exec "$(dirname "$0")/MaschinerySetup" uninstall
SCRIPT
chmod 755 "$workspace/scripts/"* "$workspace/uninstall-scripts/"*
# Payloads contain no user-writable files. Installer assigns root:wheel ownership.
chmod -R go-w "$workspace/root"
# Prevent Installer's bundle relocation from bypassing the protected staging path.
/usr/bin/pkgbuild --analyze --root "$workspace/root" "$workspace/components.plist"
python3 - "$workspace/components.plist" <<'PYCOMPONENTS'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f: components = plistlib.load(f)
def pin(items):
    for item in items:
        item['BundleIsRelocatable'] = False
        item['BundleIsVersionChecked'] = False
        item['BundleHasStrictIdentifier'] = True
        pin(item.get('ChildBundles', []))
pin(components)
with open(path, 'wb') as f: plistlib.dump(components, f)
PYCOMPONENTS
/usr/bin/pkgbuild --root "$workspace/root" --component-plist "$workspace/components.plist" --scripts "$workspace/scripts" \
  --identifier local.maschinery.full-install --version "$version" --ownership recommended \
  --install-location / "dist/Maschinery-v$version-Full-Install.pkg"
/usr/bin/pkgbuild --nopayload --scripts "$workspace/uninstall-scripts" \
  --identifier local.maschinery.remove-helper --version "$version" \
  "dist/Maschinery-v$version-Remove-Helper.pkg"
for artifact in "dist/Maschinery-v$version-Full-Install.pkg" "dist/Maschinery-v$version-Remove-Helper.pkg"; do
  (cd dist && shasum -a 256 "${artifact:t}" > "${artifact:t}.sha256")
done
print -r -- 'Built Full Install and Remove Helper packages. Test on a disposable Mac before distribution.'
