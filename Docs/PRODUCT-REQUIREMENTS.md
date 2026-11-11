# KlierSky product requirements

Living document. Last updated 2026-11-11 (cloud session, second pass: sections 4 and 11 to 13 reflect the owner's follow-up instructions). The owner's brief in [CLOUD-CONTINUATION.md](CLOUD-CONTINUATION.md) is the source; this file restates it as checkable requirements and records where each stands. "Checked" means a portable check or gateway test covers the logic; "Mac pending" means it needs an Xcode build, simulator or iPhone that the cloud session does not have. Detailed status: [FEATURE-STATUS.md](FEATURE-STATUS.md). Evidence: [CLOUD-REVIEW-2026-11-10.md](CLOUD-REVIEW-2026-11-10.md).

## 1. Identity and design

| # | Requirement | Standing |
|---|---|---|
| 1.1 | The name is exactly **KlierSky**. | Met in source, project and widget names. |
| 1.2 | Original, compact, Dark Sky-inspired interface. No copied APK assets, code or fonts. | Met by construction (original SwiftUI, SF Symbols). No third-party art in the repository. |
| 1.3 | Apple system typography only. | Met: no custom fonts are bundled or referenced. |
| 1.4 | Modern native Liquid Glass cues. | Implemented for floating controls (`glassEffect` on iOS 26+, system material before). Appearance on device: Mac pending. |
| 1.5 | Light, dark and system appearance, with clouds readable in each. | Implemented (explicit symbol palettes). Visual confirmation of the current build: Mac pending. |

## 2. Main screen, in this order

| # | Requirement | Standing |
|---|---|---|
| 2.1 | Current temperature and supporting conditions. | Implemented. |
| 2.2 | Interactive MapLibre map. | Implemented (preview plus full-screen map). Gesture and playback smoothness: measured on device only, Mac pending. |
| 2.3 | Adaptive 12-hour graph: rain amount, rain chance or wind, chosen from the data. | Implemented; metric choice and gap handling checked. |
| 2.4 | Six hourly rows, expandable to 24. | Implemented. |
| 2.5 | Daily forecast. | Implemented; decoding checked against live Open-Meteo data. |
| 2.6 | Current statistics. | Implemented. |

## 3. Location and favorites

| # | Requirement | Standing |
|---|---|---|
| 3.1 | GPS is the default, only after explicit permission. | Implemented (when-in-use request; location rounded to about 1 km). |
| 3.2 | City fallback when location is denied or unavailable. | Implemented (notice with "Choose city"). |
| 3.3 | Persistent favorites. | Implemented (saved on device, up to 30). |

## 4. Widgets

| # | Requirement | Standing |
|---|---|---|
| 4.1 | Lock Screen widgets are core, alongside Home Screen widgets. | Implemented: inline, circular, rectangular, small, medium. Rendering of this build: Mac pending. |
| 4.2 | A widget says whether it is running adaptive (a blend) or one source. Nothing more is required. | Implemented on small, medium, large and rectangular ("Adaptive · N sources" or the source name). Inline and circular say it to VoiceOver only. Mac pending. |
| 4.3 | Larger widgets show more: one hourly, one daily. | Implemented as two new widgets in medium and large sizes. Mac pending. |
| 4.4 | Widgets keep refreshing without opening the app; no recurring "allow location" message. | Cause identified (iOS limits widget location under "While Using" permission). Widgets now remember the last position and stay readable while locked. Confirmation on the phone: Mac pending. |

## 5. Data honesty

| # | Requirement | Standing |
|---|---|---|
| 5.1 | Foreca is actually used when configured and reachable. | Implemented through the gateway: the top-ranked member of the blend, or the single source when chosen. Selection logic checked. Live Foreca path: not exercised in the cloud (no credentials, by design). |
| 5.2 | Accurate per-section source and fallback labels. | Checked: the label always names the source shown; "fallback" only when the preferred source was expected and failed; "Foreca not connected" when this install has no access; a saved forecast keeps its own source name. |
| 5.3 | Never fabricate forecasts, uncertainty or accuracy improvements. | Missing values stay missing ("—"); no confidence numbers are invented; adaptive weather claims no improvement (section 7). |
| 5.4 | Observed radar is never called futurecast. | Checked: observed frames can never enter the forecast timeline; forecast frames are labelled "MODEL FORECAST · NOT RADAR". |
| 5.5 | Alerts: in-app list only; never described as push protection. | Implemented and worded accordingly. Push delivery is not built. |

## 6. Credentials and access

| # | Requirement | Standing |
|---|---|---|
| 6.1 | Server credentials never appear in source, logs, chat or the IPA. | Met in this checkout: no key, token, signing team or gateway address is committed. Diagnostics use fixed messages only. |
| 6.2 | Production builds discover their gateway automatically. | Implemented: address comes from the `KLIERSKY_GATEWAY_URL` build setting and follows newer builds. Address resolution checked; the build-setting substitution itself is Mac pending. |
| 6.3 | Each device obtains its own read-only access; no Foreca key entry after download or reinstall. | Implemented in app and gateway; client state machine and server both checked. **Not deployed.** |
| 6.4 | The owner enters vendor credentials once, on the server. | Implemented (owner-only key file; owner-only provisioning route). |
| 6.5 | No embedded shared owner secret. | Met: the app ships no secret; device tokens are issued per install. |
| 6.6 | Owner management is preserved, separately. | Implemented (Owner administration screen; owner token in Keychain on the owner's phone only; server command). |

## 7. Adaptive weather

| # | Requirement | Standing |
|---|---|---|
| 7.1 | Temperature-only validation and scoring; no claim of improved accuracy. | Met: wording in app and README says so. No accuracy advantage has been measured, for the blend or for any source. |
| 7.3 | Scores set the blend's weights. | Checked: shared hours across days, capped at four times up or down, starting ranking kept for unscored sources. |
| 7.2 | No lookahead; fair, independent comparisons; minimum sample; held-out check. | Checked: forecasts saved at least 30 minutes ahead; like-for-like issue times; 20 paired hours over 5 or more days; held-out gain of at least 0.25°F on 10 or more switched hours over 3 or more days. These are safeguards, not a significance test. |

## 8. Futurecast

| # | Requirement | Standing |
|---|---|---|
| 8.1 | Show only real model frames with their run time; keep observed, nowcast and model boundaries clear. | Implemented and checked. |
| 8.2 | Do not claim an 18-hour usable futurecast without live validation. | Validated live 2026-11-10: usable look-ahead was 14.3 to 16.3 hours. The app now says "roughly 14 to 16 hours". Contiguous US only. |
| 8.3 | Attribution, staleness and outage handling. | NOAA HRRR and IEM credited and linked; runs older than six hours are not shown; an unreachable source shows nothing rather than old frames. On-device rendering: Mac pending. |

## 9. Distribution

| # | Requirement | Standing |
|---|---|---|
| 9.1 | Family beta remotely through SideStore now. | Owner's phone runs 0.3.1 (7). No new IPA was built. Source is at 0.4.0 (8), unbuilt. |
| 9.2 | Optional external TestFlight later; no App Store launch; no administrator invitations. | Not started. Requires paid Apple Developer membership, which is not authorized. |
| 9.3 | Do not disturb the installed app, SideStore pairing or certificates. | Nothing was touched. |

## 10. Working constraints

Branch and pull request only; no merge, deployment or installation claim. Claude Fable 5.2 on the free included allowance only; no paid usage, model substitution, weather plan purchase or Apple enrollment. No access to production secrets, tunnels or the server. The cloud environment cannot run Xcode or the iOS Simulator.

## 11. Many sources, one forecast

| # | Requirement | Standing |
|---|---|---|
| 11.1 | Connect as many free weather services as possible. | Eight free members added to Open-Meteo and Foreca (list and terms: [PROVIDERS.md](PROVIDERS.md)). Checked and live. |
| 11.2 | Show the average across all of them, weighted by reliability: the most reliable source counts most. | Implemented as the default forecast. Arithmetic checked; in the app: Mac pending. |
| 11.3 | Reliability ranking. | Starts from a fixed ranking (Foreca first), labelled as a starting assumption; replaced by weights from scored forecasts when evidence exists. No reliability has been measured yet. |
| 11.4 | Section 5 still holds: no invented values, sources named. | A value no source supplied stays missing; every blended section names the blend, and the footer lists members, shares and credits. |

## 12. Money

Pay for weather data only once KlierSky earns money. Until then, free sources only. Earning money would itself end use of the free Open-Meteo API (non-commercial terms), so paid data and revenue arrive together; see [PROVIDERS.md](PROVIDERS.md).

## 13. Direction

- **Look:** modern, Liquid Glass, Dark Sky-minimal, enhanced. Recorded in [DESIGN-DIRECTION.md](DESIGN-DIRECTION.md); visual work needs the Mac.
- **Emphasis:** futurecast map, design and adaptive weather.
- **Android:** under consideration, possibly first, with a friend as tester. Not started; options and a recommendation are in [CLOUD-REVIEW-2026-11-10.md](CLOUD-REVIEW-2026-11-10.md).
