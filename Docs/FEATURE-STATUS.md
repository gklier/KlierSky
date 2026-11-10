# KlierSky feature status — November 10, 2026

Source is at 0.4.0 (8), **not built**: the cloud session that produced this revision cannot run Xcode. The owner's phone still runs SideStore release 0.3.1 (7). Nothing here is deployed or installed. Requirements: [PRODUCT-REQUIREMENTS.md](PRODUCT-REQUIREMENTS.md). Evidence and limits: [CLOUD-REVIEW-2026-11-10.md](CLOUD-REVIEW-2026-11-10.md).

How to read the labels: **checked** = covered by `Tests/run.sh` (passing on Linux, Swift 6.2.1, 2026-11-10); **live** = exercised against the real public service by `Tests/live.sh` on that date; **Mac pending** = needs an Xcode build, simulator or iPhone.

## Forecast and sources

- Foreca through the owner's gateway when this install has access; Open-Meteo otherwise. Selection and labels: checked. Live Foreca path: not exercised (no credentials in the cloud, by design).
- Labels: the source shown is always named. "· fallback" appears only when the preferred source was expected and failed; "· Foreca not connected" when the install has no service access; "· saved" for a forecast kept from an earlier refresh, under its own source name (it was previously relabelled "Offline").
- A Foreca failure notice is shown only to someone who prefers Foreca.
- Widgets fetch Open-Meteo by themselves. Small, medium and rectangular say so on the widget; inline and circular say so only in the gallery description and VoiceOver label.

## Automatic device access (not deployed)

App and gateway both implement per-device read-only access, quotas, approval and revocation. Client state machine: checked. Gateway: 40 tests passing. The live gateway is unchanged and still accepts only the owner token; the migration in `Gateway/MIGRATION.md` has not been run.

- The app finds its gateway from the `KLIERSKY_GATEWAY_URL` build setting; no address, key or token is committed. A build without it says "No weather service address is set" and uses Open-Meteo. Substitution of the build setting into Info.plist: Mac pending.
- Review fix: unapproved requests no longer consume approved device slots, and expire after seven days.
- Remaining tradeoffs (enrollment pacing, shared request ceiling, no App Attest) are listed in `Gateway/MIGRATION.md`.

## Map

- Observed radar: RainViewer, live. Past frames only.
- Futurecast: NOAA HRRR simulated reflectivity via Iowa Environmental Mesonet tiles, contiguous US only. Live: one model run, 15-minute steps, run 1.7 to 3.6 hours old when checked, so **14.3 to 16.3 hours of usable look-ahead, not 18**. The app text now says "roughly 14 to 16 hours". IEM states its materials are public domain; it is a free university service with occasional dropped connections (one retry added).
- Blank areas outside the model domain look the same as dry areas; the map now says so.
- Foreca forecast maps: adapter and signed tile proxy exist; the account has no map licence, so nothing is shown from it.
- Buffering and playback gating logic: checked. Actual smoothness, tile load times and frame pacing on a phone: Mac pending. No smoothness claim is made.

## Alerts

US National Weather Service active alerts, listed in the app with issuer, area, severity, times and instructions; stale and failed checks are marked. Decoding: checked and live. **Not push notifications**: alerts are fetched only while the app refreshes.

## Adaptive weather

Temperature only. Saves forecasts, scores them against a nearby US station's quality-controlled history, and may switch the hourly temperature source per lead-time group. **No accuracy improvement has been demonstrated**; there is no real collected evidence yet, only synthetic check inputs.

Gates, all checked: forecast saved at least 30 minutes before its hour; station within 15 km and reading within 15 minutes; both sources' forecasts saved within an hour of each other; 20 paired hours over at least 5 different days; 0.5°F in-sample advantage; held-out check that switched on at least 10 hours across 3 days and gained at least 0.25°F using only earlier evidence.

Known limits: hourly errors are correlated, so these gates are not a significance test; an airport station is not the temperature at an address; "Current location" evidence splits as the rounded location moves; scores recorded by older builds without an issue time are no longer used for comparison; collection depends on app use and best-effort background refresh; no rain calibration, bias correction or coverage outside the US.

## Not built

Push alert delivery; rain-start notifications; shared Foreca data for widgets (needs an App Group under the signing team); server-side evidence collection; pollen, lightning, snow accumulation; TestFlight distribution.

## Mac validation pending

1. Build app and widget targets (0.4.0 (8)) in Xcode; fix anything the cloud could not compile (SwiftUI view files were only syntax-parsed).
2. Confirm `KLIERSKY_GATEWAY_URL` reaches Info.plist (`Config/Local.example.xcconfig`).
3. Run `sh Tests/run.sh` and `sh Tests/live.sh` on the Mac.
4. Simulator pass: light/dark, Dynamic Type, each widget family, map playback in both modes, provider switch in Settings.
5. Sign, export IPA, update through SideStore over the existing install; confirm data survives and widgets refresh.
6. Only then consider the gateway migration.
