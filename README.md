# PSSO Monitor

A macOS app that watches Platform SSO activity in the unified log, flags sign-in failures
(including which browser triggered them), and exports reports.

## Build and run

Needs only the Xcode Command Line Tools (macOS 13+).

```bash
./build.sh
```

```bash
open "build/PSSO Monitor.app"
```

Reading the unified log requires an administrator account.

To build a distributable disk image (`build/PSSO-Monitor-<version>.dmg`, universal for Apple
silicon and Intel):

```bash
./package-dmg.sh
```

By default the build is ad-hoc signed, which other Macs will block on first launch. For a
release that opens without warnings, sign with a Developer ID and notarize:

```bash
SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=<profile> ./package-dmg.sh
```

Create the notarization profile once with `xcrun notarytool store-credentials <profile>`.

## What it does

- **Start Live** streams Platform SSO log entries as they happen (`log stream`).
- **Load History** pulls the last 15 minutes to 7 days (`log show`).
- Each entry is marked Failure, Success or Info. Error/Fault-level entries and messages with
  failure wording (failed, denied, invalid, expired, timed out, `Error Domain=` …) are failures.
- **Browser** column: Safari, Chrome, Edge, Firefox, Arc, Brave, Opera, Vivaldi, DuckDuckGo, Orion.
  A plain name means the browser process logged the entry or the message names its bundle ID.
  A `~` prefix means inferred: the failure came from the SSO agent or IdP extension within
  10 seconds of that browser's SSO request.
- **Export** writes the currently shown events as an HTML report, CSV or JSON. HTML and JSON
  include a summary, failures by browser, and the `app-sso platform -s` registration state.
- **SSO State** shows the device's Platform SSO registration.

## Sign-in Capture

The **Sign-in Capture** tab records one test run from Start to Stop and labels it for you.

1. Press **Start Capture**. The app records the conditions: PIV / smart card inserted, Cisco
   Secure Client (AnyConnect) VPN state, any other VPN, the network's DNS domains, and Platform
   SSO registration. These become the scenario label, e.g. `PIV inserted · Office network` or
   `No PIV · Remote on Cisco VPN`.
2. Reproduce the sign-ins in any browser. The app records which browsers were opened or switched
   to, and listens to Platform SSO, smart card / PIV, Authentication Services and local
   authentication logs.
3. Press **Stop Capture**. The app re-checks the conditions, reads the pages each browser
   visited during the capture from its history, and groups the log activity into sign-in
   attempts marked Pass, Fail or No result, each with a plain-language reason (Wrong PIN,
   Certificate error, Credential rejected, Timed out, …) and the site it happened on.
4. **Export Capture** as an Excel workbook or a visual HTML report.

The Excel workbook has six sheets: Summary (scenario and conditions at start and stop),
Attempts, Sites, Timeline, Common responses (every distinct pass/fail message with a count, for
refining the reason rules in `Attempts.swift`), and Events.

Things to know:

- "Office" means the network's DNS domain ends with one of the **Office domains** (default
  `nasa.gov`, editable on the tab) while the Cisco VPN is not connected.
- Sites come from browser history: Chrome, Edge, Brave, Arc, Vivaldi and Firefox work as is;
  Safari needs Full Disk Access for PSSO Monitor; private windows are never included. Query
  strings are stripped from URLs.
- Attempts are matched to sites by browser and timing, so treat the pairing as a strong hint,
  not proof.

## Log sources

Subsystems `com.apple.AppSSO` and `com.apple.PlatformSSO`, `AppSSODaemon`, and IdP SSO
extensions (Microsoft Company Portal "Mac SSO Extension", Okta, Jamf Connect). The predicate is
in `Sources/PSSOMonitor/LogEngine.swift`.

macOS redacts much of this log as `<private>`. For full detail, install a logging profile that
enables private data for `com.apple.AppSSO`.

## Self-check

```bash
"build/PSSO Monitor.app/Contents/MacOS/PSSOMonitor" --export-test 3h /tmp
```

Writes `report.csv`, `report.json` and `report.html` without opening a window. A saved ndjson
file can be given in place of the time range.
