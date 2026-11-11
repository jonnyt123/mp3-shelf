# MP3 Shelf — Native iPhone App

**MP3 Shelf is a SwiftUI iOS app built in Xcode.** This repository's iOS-only candidate contains no Next.js application, Vercel deployment, browser frontend, Node package installation, or Supabase web configuration.

## Open the Xcode project

1. On a Mac, download this branch's ZIP or clone the repository.
2. Open **[ios/MP3Shelf.xcodeproj](ios/MP3Shelf.xcodeproj)** in Xcode.
3. Select the **MP3Shelf** scheme and an iPhone Simulator, then build/run.
4. For a real iPhone, configure Apple signing in Xcode. See **[ios/README.md](ios/README.md)** and **[ios/Install on iPhone.command](ios/Install%20on%20iPhone.command)**.

The app targets **iOS 17 or later** (as configured in the Xcode project). The existing macOS GitHub workflow selects **Xcode 16.4**. Native package dependencies are managed by Xcode/Swift Package Manager.

## What is included

- Offline local recording import, playback, playlists, search, shuffle and repeat.
- Spotify and Apple Music **playlist metadata** import, with independently resolved eligible recording sources and background transfers.
- Portable library archive import/export and native playback/data-integrity safeguards.
- SwiftUI player and library screens, bundled assets, focused Swift tests, and Mac verification scripts.

Spotify and Apple Music streams are not archived as third-party audio; the native app uses its own local recordings and permitted independent sources.

## Repository layout

```text
ios/
  MP3Shelf.xcodeproj/         Xcode project (open this)
  MP3Shelf/                   SwiftUI app, models, services, resources
  Tests/                      Native regression suites
  Packages/                   Local Swift packages
  scripts/                    Native QA and device utilities
  README.md                   Full native setup and verification
.github/workflows/
  ios-build.yml               Native Xcode / Swift verification only
```

## Verify locally

On a Mac with Xcode, use **`ios/Verify MP3 Shelf.command`** for the local release smoke check. The native project can also be built using:

```sh
xcodebuild -project ios/MP3Shelf.xcodeproj -scheme MP3Shelf \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Other focused native checks and fixture-proof commands are documented in [ios/README.md](ios/README.md).

## Release and branch status

**Native build and physical-iPhone acceptance are not confirmed by this repository migration.** [Issue #6](https://github.com/jonnyt123/mp3-shelf/issues/6) remains the hardware release gate. The consolidated iOS candidate [PR #29](https://github.com/jonnyt123/mp3-shelf/pull/29), the playback/archive work [PR #30](https://github.com/jonnyt123/mp3-shelf/pull/30), and other open native PRs retain their independent review and integration requirements.

This branch is an **Xcode-only source-layout candidate**, not a signed or production-approved iPhone build. No releases or deployments are implied.
