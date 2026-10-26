# PocketForge — iPhone app workshop

PocketForge is an experimental iPhone app for local AI-assisted development, IPA inspection, repair diagnostics and offline HTML/JavaScript app packaging. Native compilation is **not yet operational**.

## Requirements
- iPhone running iOS 26 or later.
- An iOS signing/sideloading method for installing unsigned IPA archives.
- Apple Intelligence / Foundation Models availability for local AI features. The model is not guaranteed to be available on every compatible iPhone.
- Internet connection only for optional GitHub repository discovery. Web-app creation and static IPA inspection work offline.

## Install
1. Open **Actions** in this repository, then select a successful PocketForge build.
2. Download its `PocketForge-unsigned-IPA` artifact; extract the ZIP to find `PocketForge-unsigned.ipa`.
3. Sign the unsigned IPA through your own supported signing solution and install it. An unsigned IPA cannot be installed directly on ordinary stock iOS.
4. Launch PocketForge. The new bundle identifier is `dev.pocketforge.studio`; this is a different installation from older LocalCoder builds (`com.localcoder.unified`).

## Build from GitHub Actions
Workflow: `.github/workflows/localcoder-build.yml`. Builds using macOS runner, Xcode 26, XcodeGen, ZIPFoundation and the public Nyxian 0.11.4 framework release. Packaging success proves an IPA ZIP was created, **not** that the compiler works at runtime.

## Use

### AI Chat
Type a prompt and tap Send for local model responses. The attachment (+) menu accepts local files up to the implementation's size limits. The hammer menu offers:
- **Generate runnable web app**: creates an HTML/JS draft that can be previewed in PocketForge.
- **Generate native SwiftUI source**: exports a Swift source project ZIP; it is *not a compiled executable*.
- **Check native compiler**: reports on Nyxian framework / SDK readiness.

### Create App
Write HTML/CSS/JavaScript, tap **Run temporarily** to use the ephemeral WebKit preview, and **Build unsigned IPA** to package the precompiled WebKit shell with your HTML. Tap **Save editable app** to preserve the project's editable data. **Remake saved app** reopens that saved project, which can be modified and rebuilt.

WebKit preview uses a nonpersistent website data store. Saved editable project records live in the app's Documents directory and survive preview closure; they are **not** temporary. They can be lost if the app is uninstalled without backup.

### Repair
Import an IPA and optionally a diagnostic log; select **Analyze and recommend fix**. Embedded source and public repository *candidates* may be discovered, but a filename or repository name is not proof it matches the executable. The supported automated patch changes an absent display-name field; it produces an unsigned IPA with invalidated signature files removed. Unsupported cases can produce a distinct starter WebKit replacement app, **not an equivalent copy** of the original native app.

### Binary evidence
The Repair tab exports a bounded resource inventory and string evidence from Mach-O binaries. It cannot recover the original application source or fully recreate missing gameplay logic.

### Native
Generate and export Swift/Objective-C source archives. There is no verified native compile/link-and-run path on iPhone yet; the included framework presence/SDK probes do not establish compiler functionality.

### Privacy and file handling
Offline operations remain on the device. Public GitHub search communicates search terms to GitHub. Imported IPA and log files may be copied into app temporary storage while being processed. Verify sensitive files before sharing generated diagnostics.

## Optional SDK bundling

PocketForge detects an SDK at `PocketForge.app/BundledSDK/iPhoneOS.sdk`, or an SDK imported through the SDK tab into its application-support directory. The CI workflow optionally packages `SDKBundle/iPhoneOS.sdk` if present when the workflow runs, after verifying `SDKSettings.plist` and `usr/include`.

**Licensing:** Do not commit, upload, or redistribute Apple's proprietary Xcode/iPhoneOS SDK through this public repository or release unless you have explicit rights to do so. By default the public PocketForge IPA does **not** contain the Apple iPhoneOS SDK. Nyxian's compiler frameworks and resources are a separate component and are not proof that its SDK is present. The SDK importer is still available.

SDK detection and initialization checks are not native compilation tests. A functional Swift or Objective-C build requires correctly configured compiler and linker jobs and device validation.

## Important limitations
- No general-purpose, validated native executable runner within PocketForge.
- No guaranteed on-device native Swift / Objective-C compilation or arbitrary native IPA rebuilding.
- No reliable decompilation of complete original iOS app source.
- No automatic recreation of all original gameplay or interfaces from an opaque IPA.
- Unsigned IPA exports require external signing before installation.
- The app's UI and workflows need physical-device validation; passing CI compilation is not runtime validation.

## Repository
Dedicated repository: `R347H4CK3R/PocketForge`.
