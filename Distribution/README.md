# WS1 Butler 1.0 (build 1)

Workspace ONE UEM Butler — deploys internal iOS/iPadOS apps (.ipa) to multiple
Workspace ONE UEM servers at once. Bundle ID `mil.afrc.ws1butler`.
Signed with Developer ID Application: USAF ROBINS AFRC (283WG6CQV8) and notarized by Apple.

## Install (macOS 27 or later)
1. Unzip `WS1 Butler.zip`.
2. Drag **WS1 Butler.app** to `/Applications` and open it.
3. Optional integrity check: `shasum -a 256 -c "WS1 Butler.zip.sha256"`

## First-time setup
1. **Command › Servers › Quick Setup: DEV / TEST / PROD** (or **Add Server**).
2. For each server enter:
   - **REST API URL** — e.g. `https://as1234.awmdm.com`
   - **Organization Group ID** — numeric, or use **Lookup by Group ID**
   - **Authentication**
     - *OAuth 2.0*: token region (NA/EMEA/APAC/UAT or Custom URL), Client ID, Client Secret
     - *Basic*: username, password, `aw-tenant-code` (REST API key)
3. Press **Test Connection**, then **Save**. Servers that pass validation show **ARMED**.

The API account / OAuth client needs MAM permissions to search, upload, create,
assign, and retire internal applications.

## Deploying apps
1. **Applications › Native** — drop the .ipa files (or **Browse for IPAs…**).
2. Choose **Target Servers** and **Mission Parameters**:
   - *Retire previous version* — retires the old version after the new one is published.
   - *Review before publish* — stages the new version without copying assignments,
     then pauses on each server so you can verify assignments and edit app config values
     before anything is published or the prior version is retired.
   - *Auto-restore assignments* — re-applies the previous version's assignments if UEM
     didn't carry them over exactly.
   - *Create new apps* — off by default; upload apps that don't exist on a server yet.
3. Press **ENGAGE DEPLOYMENT** (⌘↩). Every server runs in parallel.
4. When a server shows **REVIEW**, open it, check the assignments and app config,
   then **APPROVE & PUBLISH**, **Don't Publish**, or **Abort**.
5. Failed or skipped servers can be retried individually. **Command › Activity Log**
   keeps a timestamped record and can be exported.

Pipeline per app and server: authenticate → locate existing app → snapshot assignments and
app config → upload → create version → verify → review → publish → retire. When review is
enabled, assignments are staged locally and applied only after approval.

## Security
- Credentials live only in this Mac's Keychain (device-only, never synced or backed up).
- HTTPS with TLS 1.2+ only; no cookies or caching; redirects to other hosts are blocked.
- Sandboxed: network client access and read-only access to files you choose — nothing else.
- Log entries never include credentials or tokens.

## Known considerations
- Validated against the Omnissa UEM 2604 API specification using a simulated server. Run a
  first deployment against your Dev server before production use.
- On-premises or DoD-PKI servers require the issuing root certificates to be trusted by macOS
  (normally via a configuration profile). The app has no option to bypass certificate checks.
- iPad: the same source builds for iPadOS. Distribute it through TestFlight, Apple Business
  Manager / custom app, or WS1 itself; notarization applies only to macOS.
