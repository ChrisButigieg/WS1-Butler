# WS1 Butler

**Workspace ONE UEM Butler** — deploy internal iOS/iPadOS apps (`.ipa`) to multiple
Workspace ONE UEM servers (Dev, Test, Prod, …) at the same time, without clicking through
Resources › Apps › Native in every console.

## Download

**[WS1-Butler-1.0.pkg](https://github.com/ChrisButigieg/WS1-Butler/releases/latest/download/WS1-Butler-1.0.pkg)**
— signed with Developer ID (USAF ROBINS AFRC, 283WG6CQV8) and notarized by Apple.
Requires macOS 27 or later. The same build is also in [`Distribution/`](Distribution/), with
SHA-256 checksums and Apple's notarization logs.

Verify before installing:

```sh
shasum -a 256 -c WS1-Butler-1.0.pkg.sha256
spctl --assess --type install -vv WS1-Butler-1.0.pkg   # expect: accepted, Notarized Developer ID
```

## What it does

Queue any number of IPAs, pick your servers, press **Engage**. For each app on each server,
in parallel across servers:

1. Authenticate (OAuth 2.0 client credentials, or Basic + `aw-tenant-code`)
2. Find the currently active version by bundle ID
3. Snapshot its assignments, smart groups, delivery method, and managed app config
4. Upload the IPA
5. Create a staged new version; assignments are carried over only for an explicit auto-publish deployment
6. Verify the carried-over assignments/app config against the snapshot (optionally auto-restore)
7. *Optional:* pause for operator review and app config edits
8. Publish the assignments
9. Retire the previous version

Built against the Omnissa Workspace ONE UEM REST API, release 2604 (MAM v1/v2, System v1, MDM v1).

See [`Distribution/README.md`](Distribution/README.md) for the full operator guide.

## Security

- Credentials stored only in the device Keychain (this-device-only, never synced or backed up)
- HTTPS / TLS 1.2+ only, ephemeral sessions, cross-host redirects blocked
- App Sandbox with only outgoing network and user-selected read-only file access
- Hardened runtime; no credentials or tokens in logs

## Building from source

Open `WS1 Butler.xcodeproj` in Xcode 27, select the **MyApp** scheme, and run.
Targets macOS and iPadOS 27. Launch with the `-demo` argument (Debug builds) to try the
full workflow against simulated UEM servers.

Tests: 107 unit tests (Swift Testing) and 6 UI tests (XCUIAutomation) — **Product › Test**.

To produce a signed, notarized release, see `Distribution/notarize.sh` and
`Distribution/notarize-pkg.sh`. Store notary credentials in your Keychain with
`xcrun notarytool store-credentials`; never commit them.

## Status

Version 1.0. Validated against the UEM 2604 API specification using a simulated server —
run a first deployment against a non-production server before relying on it in production.
