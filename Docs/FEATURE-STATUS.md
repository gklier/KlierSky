# KlierSky feature status — November 7, 2026

## Adaptive weather

Implemented: local rolling forecast capture for Foreca and Open-Meteo; independent nearby US station temperature verification; comparison by location and lead time (0–6h, 6–24h, 1–3d, 3+d). Requires at least 20 common target hours and >=0.5°F mean absolute error difference before selecting a temperature provider. Pre-target capture, station distance, timestamp, deduplication and paired-target checks prevent obvious lookahead/comparison errors. It does not alter rain probability, amounts, symbols or current conditions.

Not established: actual accuracy advantage. Automatic verification is an opt-in foreground refresh action, not an always-on learning service. The station endpoint checks the latest observation, so sparse app use misses eligible hours. No bias correction, rain calibration, independent holdout evaluation or worldwide verification yet. Nearby airport temperature is not ground truth for every street.

Next engineering work: server-side scheduled capture and observation history ingestion; separate collection/verification from app usage; report paired coverage and source errors; evaluate out of sample before expanding adaptation. Retain a baseline and allow opt-out/reset. Collect only locations the user elects to monitor, with explicit retention controls.

## Map futurecast

Observed RainViewer radar is live. Foreca forecast map adapter, capability discovery, actual timestamps, coverage/zoom metadata and signed expiring tile proxy are implemented. Current point-only account has maps disabled: there is no live 12-hour futurecast imagery. A point precipitation curve cannot be painted onto a map as forecast radar.

Obtain Foreca map access and verify layer/region/horizon/resolution before activation. Present model precipitation as forecast, not radar observation. Preserve finer actual provider timestamps near term; never invent frames to suggest precision. Beyond the nowcast horizon, show model age and uncertainty. Tile readiness/prebuffering and physical-device frame-rate profiling remain required.

## Prioritized missing features

1. Severe-weather alerts for current/favorite locations, including issuer, area, severity, issue/expiry, instructions and stale-state handling. Background push delivery needs proper infrastructure/Apple capabilities; an in-app alert list alone is not push protection.
2. Genuine near-term precipitation timing and opt-in rain notifications when entitlement, resolution and coverage support them. Do not promise minute accuracy from hourly data.
3. Reliable background/widget refresh using shared forecast data; currently widgets independently use Open-Meteo. OS scheduling remains best effort.
4. Slow-network/offline tests, update/source visibility, permission recovery, accessibility/Dynamic Type, timezone travel, battery/memory and radar interaction profiling.
5. Optional air quality/pollen, snow/ice type and accumulation, lightning proximity, and richer wind/UV context using licensed sources. No placeholder readings.
6. Read-only per-device family access, revocation, budget limits and easy feedback export before family rollout.

## Already present

Current-location default and fallback; favorite cities; light/dark/system theme; current/feels-like conditions; observed map/playback; conditional 12-hour rain/probability/wind graph; six hourly rows expandable to 24; daily details and current statistics; configurable units; cached forecast/stale notices; local bounded diagnostics; Home/Lock Screen widget extension; authenticated public Foreca gateway.

## Owner installation

SideStore is the selected free owner-testing route. Package includes widgets and no Foreca key or gateway token. Import over the existing app; do not delete it to solve signing issues without first considering local data loss. Signing identity/bundle rewriting may require re-pairing. An actual SideStore installation and refresh must be confirmed on the phone before calling the handoff verified.
