# Certificate-free full installer

The Full Install package replaces the Apple-team requirement with administrator-approved identities for exact builds. The app remains a normal user process; launchd starts the helper as root on demand. Existing RegistrationEngine and permission-repair operations, fixed NI locations, path checks, journals and rollback remain in use.

## Trust and privilege boundary

`trust.json` in `/Library/Application Support/Maschinery/InstalledHelper` contains versioned lists of app, helper and setup CodeDirectory hashes. Universal binaries have a hash for each architecture. Every path component must be root-owned, lack group/world write bits and contain no ACL grants. Deny-only ACLs are allowed. The reader pins each component with `openat` and `O_NOFOLLOW`, requires a singly linked regular file and bounds its size. Invalid configuration fails closed.

Both XPC endpoints use NSXPCConnection code-signing requirements containing the expected executable identifier and an approved cdhash. The OS checks the peer process. No claimed pathname, PID, request field, shared secret or user-writable preference establishes trust. Hardened runtime is enabled on the app, daemon and setup tool. No debugging, library-validation or executable-memory exceptions are introduced.

Normal users running the approved app can invoke the existing typed library operations. Root connections are restricted to the approved setup executable and may only ping. This lets the installer verify a live, mutually authenticated daemon before committing; setup cannot invoke installation or repair through that connection. There is no remote shell, arbitrary root command, self-approval or privileged updater API.

An ad-hoc signature identifies bytes, not a publisher. The initial trust decision is the administrator approving the downloaded package. Every code update requires another approved package, which replaces all three identities together. Someone with root access can replace this policy, as they can replace the daemon itself.

## Files and lifecycle

- App: `/Applications/Maschinery.app`.
- Helper, setup executable and trust: `/Library/Application Support/Maschinery/InstalledHelper/`.
- Daemon definition: `/Library/LaunchDaemons/local.maschinery.helper.plist`.
- Temporary package payload: `/Library/Application Support/Maschinery/InstallerPayload/`.
- In-progress setup backups: `/Library/Application Support/Maschinery/HelperSetupBackup/`.
- Existing NI operation journals: `/Library/Application Support/Maschinery/Transactions/` (retained).

The package scripts run their own embedded Universal setup tool. Preparation validates the fixed payload destination before Installer writes there. Setup refuses non-startup target volumes, running app instances, unsafe paths, links, special files, multiply-linked payload files, invalid signatures and unfinished library journals. It stops the old helper and rechecks operations before swapping files. A previously enabled SMAppService helper must be unregistered first using Settings → Remove Helper in the earlier development build. The current UI shows only the elevated installation privileges status; component setup and updates belong to the full installer.

Staging and backups are protected from ordinary users. Replacement uses same-volume rename; cross-volume installs fail instead of falling back to a partial copy. Before each change, setup persists recovery markers. Startup/health-check failure restores the previous app, helper and daemon. Rerunning the installer recovers interrupted setup; a committed marker permits cleanup without rolling back a successful update. Recovery data is kept when restoration fails. Do not manually delete it. Setup does not alter NI libraries or registration records.

For development/support only, the Remove Helper package stops the service and removes its daemon and installed helper directory. It refuses running apps and pending library transactions. App, content, registrations and NI transaction journals remain available.

## Build and verification

```sh
scripts/test-native.sh
scripts/test-intel.sh
scripts/test-helper-trust.sh
SIGNING_IDENTITY=- scripts/build-app.sh
scripts/package-installer.sh
```

The package construction script requires developer Python, pkgbuild and Xcode tools. Recipient execution uses native executables and macOS shell/launchctl only. No Apple certificate, notarization, sudo password capture, root GUI or downloadable runtime is required.

The isolated installer tests use temporary roots and replace OS service management/signature verification with controlled fixtures. They exercise real copy/rename/marker/recovery code, not production launchd or administrator approval. The XPC probe compiles hardened, ad-hoc signed executables and checks acceptance and rejection on both ends on supported architectures. Neither test installs a system daemon.

## Required desktop acceptance

On a disposable clean macOS 14+ installation without developer credentials:

1. Download the unsigned package, approve opening if required and complete the administrator-authorized installation.
2. Open the app normally. Verify live helper status, then install a disposable synthetic library and exercise registration, repair, relocation, removal and recovery.
3. Install an updated package. Verify both app and helper change together and the old app cannot connect. Verify an unapproved executable with the same identifier cannot connect.
4. Exercise failed daemon startup and interrupted setup, then rerun the installer. Verify restoration and journal retention.
5. Remove the helper using its package; confirm content and registrations remain and Full Install becomes unavailable. Reinstall successfully.
6. Repeat on physical Intel hardware and check Gatekeeper/background-item behavior on the supported macOS versions.

No system daemon or real NI content has been modified by the automated validation recorded for this change.

Apple references: [code requirements](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html), [NSXPC peer requirements](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)), [launch daemons](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html).

Public releases expose only the Full Install package and checksum. Component maintenance packages are not offered as a separate user setup step. The app has no helper toggle, enable/remove controls or startup enable prompt.
