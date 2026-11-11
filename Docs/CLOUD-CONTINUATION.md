# KlierSky cloud continuation — November 10, 2026

The owner requests continuing development in Claude Code cloud so the same cloud chat is accessible from mobile and another laptop. This is a continuation brief, not a verbatim import of the local chat.

## Non-negotiable requirements
Exact name KlierSky. Original Dark Sky-inspired compact UI with Apple system typography, modern native Liquid Glass cues, no copied APK assets/code/fonts. Layout: current temperature/supporting conditions; interactive MapLibre map; adaptive 12-hour rain/chance/wind graph; six hourly rows expandable to 24; daily forecast; current statistics. Light/dark/system with readable clouds. GPS default with explicit permission and city fallback; persistent favorites; Lock Screen widgets core. Family beta remotely through SideStore now, optional external TestFlight later without App Store launch or administrator invitations.

Foreca must actually be used when configured/reachable; accurate per-section provenance and fallback labels. Widgets independently use Open-Meteo and must say so. Never fabricate forecast, uncertainty, accuracy improvements or call observed radar futurecast. Keep server credentials out of source, logs, chat and IPA. Production should automatically discover its configured gateway and obtain per-device read-only access: no repeated Foreca-key entry after downloading/reinstalling. Owner enters vendor credentials once on server. No embedded shared owner secret. Preserve owner management separately.

## Current implementation and evidence
Overnight local Fable 5.2 run added UI/detail/alert views, HRRRFuturecast (US model reflectivity via IEM, targeting 18 hours at 15-minute steps), radar buffering/playback gates, observation-history adaptive scoring and held-out gate, device enrollment/access abstractions and tests. These are new code needing review, not all verified deployed behavior. Last saved simulator build succeeded. November 10 rerun Tests/run.sh passed all four Swift executable check groups and all 36 Python gateway tests with local socket permission. Initial restricted test run had permission errors; unrestricted rerun passed. No new IPA or server deployment from overnight. Installed owner phone remains previous SideStore release 0.3.1(7). Do not remove it or disturb SideStore pairing/certificates.

Adaptive weather is temperature-only validation/scoring infrastructure, not demonstrated improved accuracy. Audit lookahead, independence, minimum sample size and held-out behavior. Validate live HRRR timestamps, supported frames, full tile path, coverage, licensing/attribution, staleness and outages before claiming 18-hour usable futurecast. Keep observed/nowcast/model boundaries clear. Alerts are in-app, not verified push notifications.

## Next work
Review current source, fix defects, verify accessible tests, improve native dense polished UX and smooth map gestures/playback, verify provider switching. Review Gateway/MIGRATION.md device enrollment, quotas, revocation and closed/approval/open enrollment tradeoffs; implementation is not deployed. Keep PRODUCT-REQUIREMENTS.md and FEATURE-STATUS.md current and write an honest report. Use a development branch and PR; do not merge/deploy or claim installation. Cloud cannot run Xcode/iOS Simulator: record that limit and leave Mac build/signing/SideStore verification pending.

## Access and cost boundaries
Use claude-fable-5-2 only under the owner's free included/promotional allowance. Paid extra usage is disabled per owner; ZERO paid credits/API/overage authorized. Do not enable billing, switch providers/models, purchase weather plans or enroll in Apple Developer. If free Fable unavailable stop and explain. Routine source edits/checks and branch pushes authorized; preserve private repo. Do not access production secrets, change production/tunnels, invite family, revoke certificates or delete apps. This sanitized checkout intentionally omits personal signing team, default gateway endpoint and deployment details. Production endpoint can be supplied via build configuration later; never resolve missing config by embedding credentials.

## Cloud session status — November 10, 2026

Work is on branch `development/cloud-continuation`; nothing merged, deployed, built into an IPA or installed. Report: [CLOUD-REVIEW-2026-11-10.md](CLOUD-REVIEW-2026-11-10.md). Requirements: [PRODUCT-REQUIREMENTS.md](PRODUCT-REQUIREMENTS.md). Status: [FEATURE-STATUS.md](FEATURE-STATUS.md).

Done in the cloud: full source review; portable checks made to run on Linux and passing (four Swift groups, 40 gateway tests); live validation of HRRR/IEM, RainViewer, NWS alerts and Open-Meteo through the app's own code; fixes to provider labels, gateway address discovery, adaptive evidence gates, futurecast look-ahead wording, widget source label and gateway enrollment slots. Source version set to 0.4.0 (8).

Note: GitHub reports this repository as **public**, not private as assumed above. The branch was pushed as a single commit without the gateway hostname, at the owner's direction; decide whether the repository should be made private.

Standing owner instruction (2026-11-11): after every finished change, update the README, docs, screenshots and GitHub, and keep the page beautiful. It is recorded in `CLAUDE.md`. Screenshots cannot be retaken in the cloud; they are queued for the Mac.

The owner switched the session model to Sonnet 5.5 on 2026-11-11 (the session record shows `user_switched_model`). `CLAUDE.md` still says Fable 5.2 only; the owner should confirm which it wants.

Pending on a Mac: Xcode build of app and widgets (SwiftUI view files were syntax-parsed only, not type-checked), simulator and device checks, signing, IPA, SideStore update. Pending owner decisions: enrollment mode and gateway migration; whether inline and circular Lock Screen widgets need a visible source line.
