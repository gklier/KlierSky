# Android / iPhone parity acceptance

Reference: working iOS 0.5.0 source, November 25, 2026. Android 0.1.3 was a preview, not feature parity. The owner now explicitly requests parity. Do not mark a row complete merely because a screen or adapter exists.

| Capability | Android 0.1.3 | Port acceptance |
| --- | --- | --- |
| Current / hourly / daily / units / themes / GPS / favorites | Core present | Detailed daily and metric exploration, all current statistics, display preferences |
| Foreca / per-device access | Read-only enrollment present | Owner pairing, approvals, revocation and server-only credential management |
| Multi-source forecast | Open-Meteo or Foreca only | Same independent free adapters, weighted blend, per-section provenance, single-source mode and comparisons |
| Adaptive evidence | Missing | Opt-in captures, independent station history, fair paired gates, measured weights and held-out temperature selection |
| Map futurecast | Observed radar only | Real run-pinned HRRR frames, coverage/staleness validation, observed/model boundary, model uncertainty, bounded warming/cache |
| Severe alerts | Missing | NWS active alerts with dates, issuer, area, severity and instructions; no unsupported non-US claim |
| History | Missing | ERA5 date browser, same-date last year and 1991–2020 same-calendar-day reference, minimum 20 complete years |
| Personal stations | Missing | Per-device server connector for Tempest / Weather Underground, separate timestamped observations, no credential logging |
| Rain notifications | Missing | Opt-in permission, hourly onset rules, lead/chance controls, cancellation/deduplication, test and best-effort background work |
| Widgets | Missing | Current, hourly and daily, source/age/location and preferences; host-dependent Android Lock Screen support |
| Reliability / diagnostics | Limited | Offline cache with age, bounded sanitized logs/export, background settings and explicit missing values |

Identical OS APIs are impossible: WidgetKit vs Android app widgets, platform notification scheduling and system fonts differ. Implement equivalent user capabilities where the OS supports them, and document platform-specific limitations. In particular, Android Lock Screen hosting depends on the system/launcher.

Validation must include release build/lint/signature, pure algorithm safeguards, live provider decoding, Android UI interactions, background/notification/widget checks and a clear remaining physical-device checklist. Do not claim measured accuracy gains or guaranteed rain notification delivery.

Pixel icon requirement: Pixel 8 Pro / Android 17 must use a full-bleed adaptive launcher icon, separate original sun foreground and themed monochrome layer; no square inset inside the launcher mask. Validate through Android AdaptiveIconDrawable and launcher rendering.

## Android 0.2.0 beta

The app implements the user-facing capabilities in the table. The Android 17 emulator decoded nine public sources and rendered actual model tiles from a validated HRRR run extending about 16 hours into the future. UI checks opened daily and hourly statistics, loaded an ERA5 past day and 30 matching calendar dates for the baseline, exercised the administration and station forms, and delivered a test notification. Widget checks bound all three native providers and pinned a current conditions widget on the Home Screen. The adaptive icon has a full background and independent monochrome layer.

The signed APK uses the same package and signing certificate as 0.1.3. A release update installed over 0.1.3 on the Android 16 emulator. Release lint, APK alignment and AAB validation passed.

Physical Pixel validation remains open for launcher appearance, radar performance and Lock Screen placement. All six gateway device slots were occupied during testing, so this build’s live Android Foreca and personal station requests remain unverified. No family access records were changed. Live rain delivery timing and adaptive accuracy gains also remain unverified.
