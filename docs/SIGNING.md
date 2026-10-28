# Sign and authorize the helper

Apple's current macOS 13+ API is `SMAppService.daemon(plistName:)`. Incoming NSXPC messages are constrained with `setCodeSigningRequirement`, on both sides, to an Apple-signed executable with the expected identifier and the same team as the running executable. Team IDs are obtained from the actual code signature, never from request data or a user-editable setting.

References:
- https://developer.apple.com/documentation/servicemanagement/smappservice
- https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)

## Developer identity supplied by you

This environment reports `0 valid identities found` for `security find-identity -v -p codesigning`. An ad-hoc signature deliberately fails authorization. There is no bypass switch.

1. In Xcode → Settings → Accounts, add your Apple account and select your development team. Create an Apple Development certificate, or import your Developer ID Application certificate **with its private key** into your login Keychain.
2. Open `MaschineMachine.xcodeproj`. Select **both MaschineMachine and MaschineHelper targets** → Signing & Capabilities → select the **same team** and enable automatic signing. Keep these identifiers consistent with `HelperIdentity` and the daemon plist:
   - app: `local.maschinemachine.app`
   - helper/Mach service: `local.maschinemachine.helper`
3. Build the MaschineMachine Release scheme for **Any Mac** (`arm64 x86_64`, Only Active Architecture = No). The app target depends on the helper, embeds it with Code Sign on Copy, and copies the launch-daemon plist. The helper target embeds an Info.plist in its Mach-O binary.
4. Copy the signed app to `/Applications/Maschine Machine.app` and launch it there. Keep it at that location while its service is registered.
5. Open the app's Settings → **Enable Helper…**, then approve the administrator authorization in System Settings → General → Login Items & Extensions. Refresh Helper Status; it must be `enabled` before Full Install.
6. Drop a synthetic library and matching XML, select Full Install, and confirm plist/XML/artwork, repair, relocation, cancellation and recovery on a disposable destination before using real libraries.

The GUI must never be run as root. No Terminal sudo step is part of installation.

## Reproducible signed Universal 2 bundle

Once a valid identity is in your Keychain:

```sh
cd /Users/mef/MaschineMachine
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' scripts/build-app.sh
codesign --verify --deep --strict 'dist/Maschine Machine.app'
codesign -dv --verbose=4 'dist/Maschine Machine.app'
codesign -dv --verbose=4 'dist/Maschine Machine.app/Contents/Library/LaunchServices/MaschineHelper'
lipo -archs 'dist/Maschine Machine.app/Contents/MacOS/MaschineMachine'
lipo -archs 'dist/Maschine Machine.app/Contents/Library/LaunchServices/MaschineHelper'
```

The script signs the helper first with identifier `local.maschinemachine.helper`, then the app, using hardened runtime and secure timestamps. Use the full identity name printed by `security find-identity -v -p codesigning`. Apple Development identities can be used for local testing; Developer ID is needed for outside distribution. Changing bundle IDs requires updating HelperIdentity, the launchd plist label/MachServices/filename and both Xcode target identifiers together.

Equivalent Xcode CLI (replace team ID with yours):

```sh
xcodebuild -project MaschineMachine.xcodeproj -scheme MaschineMachine \
  -configuration Release -destination 'generic/platform=macOS' \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  DEVELOPMENT_TEAM=YOURTEAMID CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates build
```

## Notarization

Store credentials in Keychain using `xcrun notarytool store-credentials MaschineMachineNotary` (Apple ID/app-specific password/team, or App Store Connect key). Do not put credentials in the repository.

```sh
ditto -c -k --keepParent 'dist/Maschine Machine.app' dist/MaschineMachine.zip
xcrun notarytool submit dist/MaschineMachine.zip --keychain-profile MaschineMachineNotary --wait
xcrun stapler staple 'dist/Maschine Machine.app'
spctl --assess --type execute --verbose=4 'dist/Maschine Machine.app'
```

To move/remove a previously authorized app, first disable its background item in System Settings. Re-register after installing a newly signed version at its final path. No launchd files are manually installed with sudo.
