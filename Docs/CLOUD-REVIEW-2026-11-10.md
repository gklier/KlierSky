# Cloud review report — November 10, 2026

Branch `development/cloud-continuation`. Nothing was merged, deployed, packaged or installed. No production secret, server, tunnel, certificate or phone was touched. Model: Claude Fable 5.2 on the included allowance (session reported no overage use).

## What could and could not be validated here

| Validated in the cloud | How |
|---|---|
| Portable Swift checks, four groups | `sh Tests/run.sh` on Linux x86_64, Swift 6.2.1: all pass |
| Gateway | 40 Python tests (36 before this session), Python 3.13: all pass |
| Public data sources through the app's own request and decoding code | `sh Tests/live.sh`: Open-Meteo forecast and air quality, RainViewer, IEM/HRRR, NWS alerts all answered and decoded on the final run |
| Daily forecast checks | `Tests/DailyChecks.swift` against a freshly fetched Open-Meteo response: pass |
| Swift syntax of every app and widget file | `swiftc -frontend -parse`: no errors |
| Types in `WeatherModel.swift` (the refresh and provider logic) | Type-checked on Linux in Swift 5 mode against temporary stand-ins for the Apple-only types it calls; the stand-ins are not in the repository |

| Not validated: Mac pending | Why |
|---|---|
| Compiling the app and widget targets | No Xcode, SwiftUI, MapLibre or WidgetKit on Linux. **The SwiftUI view files changed in this session (`SettingsView`, `AdaptiveView`, `RadarView`, `KlierSkyApp`, the widget) were syntax-parsed only, not type-checked.** The edits are small, but a compile error on the Mac is possible. |
| Anything visual: layout, Liquid Glass, light/dark, Dynamic Type, widget rendering | No simulator |
| Map gesture smoothness, tile load time, playback frame pacing | Needs a device; the app records these itself (Weather Lab → Radar measurements) |
| `KLIERSKY_GATEWAY_URL` reaching Info.plist | Xcode build step |
| Foreca through the gateway, device enrollment against a real server | No credentials or endpoint in the cloud, by design; migration not deployed |
| Signing, IPA, SideStore update | Mac and phone |

Caveats on the live run: Open-Meteo returned HTTP 429 twice from the shared cloud address before succeeding, which says nothing either way about a phone. NWS returned no active alerts for the test cities, so live alert decoding exercised an empty list; non-empty decoding is covered by the recorded fixture only. IEM dropped 3 of about 25 connections.

## Findings and changes

### Fixed

1. **Checks could not run off the Mac.** `Weather.swift` lacked the Linux networking import. Added behind `canImport`; no effect on Apple platforms.
2. **A saved forecast was relabelled "Offline".** When a refresh failed, every section's source line lost the real source name. It now reads "Foreca · saved" or "Open-Meteo · saved".
3. **No label when Foreca was preferred but this install had no access.** The screen showed plain "Open-Meteo". It now reads "Open-Meteo · Foreca not connected". "Fallback" is still reserved for an expected source that failed.
4. **Foreca error shown to people who chose Open-Meteo.** Now only shown when Foreca is the preferred source.
5. Provider selection moved into a pure function (`ProviderChoice`) with eight checked cases, so switching is tested rather than assumed.
6. **A build with no gateway address reported "does not offer automatic device access" and waited six hours.** The dedicated "No weather service address is set" state existed but could never occur. Now it does, without a wait.
7. **Gateway address could go stale.** The built-in address was copied once and never updated by later builds. It now follows the build unless the owner typed a different one. The address comes from the `KLIERSKY_GATEWAY_URL` build setting; an address with embedded credentials, a query or plain HTTP is rejected. No address is committed.
8. **Adaptive comparison could pair unlike forecasts.** If one source failed at a refresh, its next forecast for the same hour could be hours fresher than the other's and still be ranked against it. Pairs must now be saved within an hour of each other.
9. **Twenty consecutive hours counted as twenty pieces of evidence.** One evening of weather could qualify a switch. Evidence must now span 5 different days, and the held-out switch must span 3 days and gain at least 0.25°F (previously any gain above zero).
10. **Futurecast look-ahead was overstated in code comments and loosely stated in Settings.** Live check: 14.3 to 16.3 hours, not 18. Text corrected; a look-ahead helper and check added.
11. **Blank map outside the HRRR domain looked like a dry forecast.** The frame description now says coverage is the contiguous US only.
12. One retry for dropped IEM connections.
13. **Rectangular Lock Screen widget did not name its source.** It now shows "Open-Meteo" with the fetch time.
14. **Gateway: unapproved requests consumed family device slots** (details in `Gateway/MIGRATION.md`). Separate caps, expiry after seven days, approval refused at the limit, four new tests. The owner screen explains the new refusal.
15. Version mismatch: the code and migration notes said 0.4 while the project said 0.3.1 (7), identical to the installed build. Project set to 0.4.0 (8).
16. The migration note contained the production hostname; replaced with a placeholder, in line with the sanitized checkout. **The repository is public on GitHub, not private as the brief assumed.** At the owner's direction the overnight commit and this review were combined into one commit before the first push, so the hostname does not appear in the pushed history. A hostname is not a credential, but the gateway design, migration notes and enrollment protocol on this branch are publicly readable.
17. `Tests/DailyChecks.swift` was not run by anything and cannot pass against the committed fixture (it needs a current 14-day response). It now runs in `Tests/live.sh` against a fresh response.
18. A check message said "live" for recorded fixtures; corrected.

### Reviewed, no defect found

Lookahead protection in scoring and in the held-out check; station selection and quality-control filtering; observed frames excluded from forecast timelines; HRRR run pinning (a not-yet-published run returns HTTP 503 rather than another run's image; the layer template is IEM's documented one); alert expiry, staleness and "not push" wording; diagnostics contain fixed strings only; Keychain accessibility classes; device token never able to reach owner routes; no secret, team identifier or endpoint in the tree.

### Open, not changed

- **Inline and circular Lock Screen widgets show no source on the widget face.** There is no room without dropping the temperature or rain line. They say Open-Meteo in the gallery and to VoiceOver. Owner decision.
- **Interface polish and map smoothness.** No visual redesign was attempted blind. The buffering logic is checked; real smoothness needs the phone's own measurements.
- **README screenshots** predate the overnight interface changes.
- **Adaptive weather** has no real evidence yet and the gates are not a significance test. "Current location" evidence fragments as the rounded position changes.
- **IEM** is a free university service: fine for a family beta with attribution, not a production dependency.
- **Gateway tradeoffs** (enrollment pacing, shared request ceiling, no App Attest): see `Gateway/MIGRATION.md`.
- No CI workflow was added: GitHub Actions minutes on a private repository can cost money, which is not authorized.

## Suggested order on the Mac

See "Mac validation pending" in [FEATURE-STATUS.md](FEATURE-STATUS.md).
