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
