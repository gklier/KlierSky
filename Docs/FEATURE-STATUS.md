# KlierSky feature status — November 10, 2026

Source is at 0.4.0 (8), **not built**: the cloud session that produced this revision cannot run Xcode. The owner's phone still runs SideStore release 0.3.1 (7). Nothing here is deployed or installed. Requirements: [PRODUCT-REQUIREMENTS.md](PRODUCT-REQUIREMENTS.md). Evidence and limits: [CLOUD-REVIEW-2026-11-10.md](CLOUD-REVIEW-2026-11-10.md).

How to read the labels: **checked** = covered by `Tests/run.sh` (passing on Linux, Swift 6.2.1, 2026-11-10); **live** = exercised against the real public service by `Tests/live.sh` on that date; **Mac pending** = needs an Xcode build, simulator or iPhone.

## Blend of all sources (new, default)

The forecast shown is a weighted average of every source that answers: Foreca when connected, Open-Meteo, six global models, MET Norway and, in the US, the National Weather Service. Blend arithmetic, adapters and labels: checked. All free members: live. In the running app: Mac pending.

- Each hourly value averages only the sources that supplied it for that hour; a value nobody supplied stays missing. Conditions (the symbol) come from the highest-ranked source, never an average. Daily values blend the sources that publish daily forecasts (Foreca and Open-Meteo).
- Weights start from a fixed ranking with Foreca first. That ranking is an assumption and is labelled "starting weights". With evidence collection on, a source's weight is scaled by how close its saved forecasts came to the station, once at least two sources share 20 scored hours over 5 days, limited to four times up or down; the label then reads "weights from scored forecasts".
- **No accuracy gain is claimed or measured.** Averaging several forecasts usually reduces large misses, but that has not been tested here.
- "One source" remains a setting; everything under "Forecast and sources" below still applies to it.

## Forecast and sources

- Foreca through the owner's gateway when this install has access; Open-Meteo otherwise. Selection and labels: checked. Live Foreca path: not exercised (no credentials in the cloud, by design).
- Labels: the source shown is always named. "· fallback" appears only when the preferred source was expected and failed; "· Foreca not connected" when the install has no service access; "· saved" for a forecast kept from an earlier refresh, under its own source name (it was previously relabelled "Offline").
- A Foreca failure notice is shown only to someone who prefers Foreca.
- Widgets fetch the free sources by themselves (never Foreca, which needs the app's access) and blend them with the starting weights. They show "Adaptive · N sources" for a blend or the source's name when only one answered; inline and circular have no room and say it to VoiceOver only.

## Widgets (reworked)

All Mac pending; none of this has been built or seen on a device.

- **"Allow location" until the app is opened:** with "While Using" permission, iOS gives a widget the position only for a short time after the app was used. Widgets now remember the last position they obtained and keep showing weather for it (outline location arrow), then fall back to a chosen city, and only then show a message. They also read the system's last known position before asking for a new one.
- Widget files are now readable while the iPhone is locked, which Lock Screen widgets need in order to refresh.
- New widgets: **KlierSky hourly** (medium: six hours; large: eight rows) and **KlierSky daily** (medium: five days; large: seven rows). The original widget keeps the small, medium and Lock Screen sizes.
- iOS still decides when widgets refresh; that cannot be forced.

## Automatic device access (not deployed)

App and gateway both implement per-device read-only access, quotas, approval and revocation. Client state machine: checked. Gateway: 40 tests passing. The live gateway is unchanged and still accepts only the owner token; the migration in `Gateway/MIGRATION.md` has not been run.

- The app finds its gateway from the `KLIERSKY_GATEWAY_URL` build setting; no address, key or token is committed. A build without it says "No weather service address is set" and uses Open-Meteo. Substitution of the build setting into Info.plist: Mac pending.
- Review fix: unapproved requests no longer consume approved device slots, and expire after seven days.
- Remaining tradeoffs (enrollment pacing, shared request ceiling, no App Attest) are listed in `Gateway/MIGRATION.md`.

## Map

- The map now opens on one timeline: past radar up to now, then the model forecast, with a mark where observation ends, a colour key for the layer on screen, and a notice when no model frames are available. Radar-only and model-only views remain. Mac pending.
- Observed radar: RainViewer, live. Past frames only.
- Futurecast: NOAA HRRR simulated reflectivity via Iowa Environmental Mesonet tiles, contiguous US only. Live: one model run, 15-minute steps, run 1.7 to 3.6 hours old when checked, so **14.3 to 16.3 hours of usable look-ahead, not 18**. The app text now says "roughly 14 to 16 hours". IEM states its materials are public domain; it is a free university service with occasional dropped connections (one retry added).
- Blank areas outside the model domain look the same as dry areas; the map now says so.
- Foreca forecast maps: adapter and signed tile proxy exist; the account has no map licence, so nothing is shown from it.
- Buffering and playback gating logic: checked. Actual smoothness, tile load times and frame pacing on a phone: Mac pending. No smoothness claim is made.

## Alerts

US National Weather Service active alerts, listed in the app with issuer, area, severity, times and instructions; stale and failed checks are marked. Decoding: checked and live. **Not push notifications**: alerts are fetched only while the app refreshes.

## Adaptive weather

Temperature only. With collection on, saves every blend member's forecast (previously forecasts were saved even with collection off; fixed), scores them against a nearby US station's quality-controlled history, and uses the scores to weight the blend. In one-source mode it may instead switch the hourly temperature source per lead-time group. **No accuracy improvement has been demonstrated**; there is no real collected evidence yet, only synthetic check inputs.

Gates, all checked: forecast saved at least 30 minutes before its hour; station within 15 km and reading within 15 minutes; both sources' forecasts saved within an hour of each other; 20 paired hours over at least 5 different days; 0.5°F in-sample advantage; held-out check that switched on at least 10 hours across 3 days and gained at least 0.25°F using only earlier evidence.

Known limits: hourly errors are correlated, so these gates are not a significance test; an airport station is not the temperature at an address; "Current location" evidence splits as the rounded location moves; scores recorded by older builds without an issue time are no longer used for comparison; collection depends on app use and best-effort background refresh; no rain calibration, bias correction or coverage outside the US.

## Not built

Push alert delivery; rain-start notifications; shared Foreca data for widgets (needs an App Group under the signing team); server-side evidence collection; pollen, lightning, snow accumulation; TestFlight distribution.

## Mac validation pending

0. Expect compile fixes: the second pass added a lot of SwiftUI and WidgetKit code that the cloud could only syntax-check.
1. Build app and widget targets (0.4.0 (8)) in Xcode; fix anything the cloud could not compile (SwiftUI view files were only syntax-parsed).
2. Confirm `KLIERSKY_GATEWAY_URL` reaches Info.plist (`Config/Local.example.xcconfig`).
3. Run `sh Tests/run.sh` and `sh Tests/live.sh` on the Mac.
4. Simulator pass: light/dark, Dynamic Type, each widget family including the new hourly and daily widgets, map playback on the combined timeline, blend versus one source in Settings.
4a. On the phone: leave the app closed for an hour and confirm current-location widgets keep updating.
5. Sign, export IPA, update through SideStore over the existing install; confirm data survives and widgets refresh.
6. Only then consider the gateway migration.
