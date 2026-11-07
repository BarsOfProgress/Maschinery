# Sign and authorize the helper

## Maschinery 1.0.0 rename

The app, core, helper and Xcode targets are now Maschinery, MaschineryCore and MaschineryHelper. The app identifier is `local.maschinery.app`; the helper identifier/Mach service is `local.maschinery.helper`. Maschinery stores its logs and recovery journals under its own Application Support directory and uses its own preferences domain.

Before switching from an earlier app build, finish or recover its interrupted operations in that build. Retain the earlier app and its recovery data until that is complete. Disable the earlier helper in System Settings after quitting the earlier app, then enable Maschinery’s helper from the new app. The rename does not move or unregister installed NI libraries, and Maschinery discovers their existing NI registrations normally. Existing signing credentials are reused unchanged.

Apple's current macOS 13+ API is `SMAppService.daemon(plistName:)`. Incoming NSXPC messages are constrained with `setCodeSigningRequirement`, on both sides, to an Apple-signed executable with the expected identifier and the same team as the running executable. Team IDs are obtained from the actual code signature, never from request data or a user-editable setting.

References:
- https://developer.apple.com/documentation/servicemanagement/smappservice
- https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)

## Existing development identity

The existing login Keychain identity is `Apple Development: mefflecakes@gmail.com (2R45ZYNBM6)`, SHA-1 `0BDE0EBF64FBA341DB98AB72EB98CD5AF40C20DB`, in `/Users/mef/Library/Keychains/login.keychain-db`. Its certificate OU / signing Team ID is **F75CB2ST8Q**. The display-name suffix **2R45ZYNBM6** is not the Team ID.

On 2026-11-01, identical `/usr/bin/security find-identity -v -p codesigning` commands returned zero identities inside the agent sandbox and one outside it, including when explicitly specifying the login Keychain. Both contexts used UID 501 (`mef`), HOME `/Users/mef`, and the same default/search-list Keychain. Zero results in this restricted context do not mean this Mac lacks a certificate. Retry discovery/signing outside the sandbox with permission; do not create or replace credentials to resolve this visibility issue.

The runtime does not enumerate Keychains or parse certificate display names: `HelperIdentity.team()` reads `kSecCodeInfoTeamIdentifier` from the running executable's signature. An ad-hoc app has no Team ID and deliberately fails Full Install preflight. The build script formerly defaulted to ad-hoc signing whenever `SIGNING_IDENTITY` was unset, even if a certificate existed. It now selects a sole visible identity by SHA-1, or fails with instructions to select one explicitly. Ad-hoc signing requires an explicit `SIGNING_IDENTITY=-`.

1. Use the existing Apple Development identity in the login Keychain. No certificate or provisioning credential changes are needed for this build.
2. Open `Maschinery.xcodeproj`. Select **both Maschinery and MaschineryHelper targets** → Signing & Capabilities → select the **same team** and enable automatic signing. Keep these identifiers consistent with `HelperIdentity` and the daemon plist:
   - app: `local.maschinery.app`
   - helper/Mach service: `local.maschinery.helper`
3. Build the Maschinery Release scheme for **Any Mac** (`arm64 x86_64`, Only Active Architecture = No). The app target depends on the helper, embeds it with Code Sign on Copy, and copies the launch-daemon plist. The helper target embeds an Info.plist in its Mach-O binary.
4. Copy the signed app to `/Applications/Maschinery.app` and launch it there. Keep it at that location while its service is registered.
5. Open the app's Settings → **Enable Helper…**, then approve the administrator authorization in System Settings → General → Login Items & Extensions. Refresh Helper Status; it must be `enabled` before Full Install.
6. Drop a synthetic library and matching XML, select Full Install, and confirm plist/XML/artwork, repair, relocation, cancellation and recovery on a disposable destination before using real libraries.

The GUI must never be run as root. No Terminal sudo step is part of installation.

## Reproducible signed Universal 2 bundle

Once a valid identity is in your Keychain:

```sh
cd /path/to/Maschinery
SIGNING_IDENTITY='0BDE0EBF64FBA341DB98AB72EB98CD5AF40C20DB' \
SIGNING_KEYCHAIN='/Users/mef/Library/Keychains/login.keychain-db' scripts/build-app.sh
codesign --verify --deep --strict 'dist/Maschinery.app'
codesign -dv --verbose=4 'dist/Maschinery.app'
codesign -dv --verbose=4 'dist/Maschinery.app/Contents/Library/LaunchServices/MaschineryHelper'
lipo -archs 'dist/Maschinery.app/Contents/MacOS/Maschinery'
lipo -archs 'dist/Maschinery.app/Contents/Library/LaunchServices/MaschineryHelper'
```

The script signs the helper first with identifier `local.maschinery.helper`, then the app, using hardened runtime and secure timestamps. Use the SHA-1 or full identity name printed by `security find-identity -v -p codesigning`. Apple Development identities can be used for local testing; Developer ID is needed for outside distribution. Changing bundle IDs requires updating HelperIdentity, the launchd plist label/MachServices/filename and both Xcode target identifiers together.

Equivalent Xcode CLI using the existing team:

```sh
xcodebuild -project Maschinery.xcodeproj -scheme Maschinery \
  -configuration Release -destination 'generic/platform=macOS' \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  DEVELOPMENT_TEAM=F75CB2ST8Q CODE_SIGN_STYLE=Automatic \
  build
```

## Notarization

Store credentials in Keychain using `xcrun notarytool store-credentials MaschineryNotary` (Apple ID/app-specific password/team, or App Store Connect key). Do not put credentials in the repository.

```sh
ditto -c -k --keepParent 'dist/Maschinery.app' dist/Maschinery.zip
xcrun notarytool submit dist/Maschinery.zip --keychain-profile MaschineryNotary --wait
xcrun stapler staple 'dist/Maschinery.app'
spctl --assess --type execute --verbose=4 'dist/Maschinery.app'
```

To move/remove a previously authorized app, first disable its background item in System Settings. Re-register after installing a newly signed version at its final path. No launchd files are manually installed with sudo.
