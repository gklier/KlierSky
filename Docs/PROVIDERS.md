# KlierSky provider decision — November 6, 2026

The earlier chat is a design reference, not verified provider documentation. No independent research attachment was available in this workspace.

## Recommended route

Personal prototype: Open-Meteo point forecast + RainViewer observed radar + MapLibre Native. Commercial product: licensed Foreca precipitation maps behind a controlled backend, plus a commercial point forecast contract and a production basemap reliability plan. OpenFreeMap's hosted dark style supplies the prototype basemap with source attribution. Do not assume a provider is most accurate for a particular day range without local verification.

| Source | Verified capability | Decision |
|---|---|---|
| Foreca | Global layer 22: precipitation forecast, 15-minute timesteps, 3 days, updated every 12 hours. North America layer 10: combined radar / radar forecast / simulated precipitation, 5-minute timesteps, 3 days, updated every 5 minutes. | Best documented candidate for 12+ hour map. Request trial and written commercial rights, caching allowances, attribution, costs, and coverage. Use capabilities endpoint for actual valid timesteps. A combined layer needs explicit provenance transitions supplied by the backend; do not call every future timestep a nowcast. |
| Azure Maps | Get Map Tile documents radar from 1.5 hours past to 2 hours future, 5-minute steps. Attribution endpoint must also be called and shown. | Potential near-term provider; does not satisfy 12-hour futurecast alone. No basis for treating this API as identical to Microsoft consumer weather accuracy claims. |
| RainViewer | Detailed API documentation and live response expose past radar frames. Public terms restrict personal/educational use and warn about availability. General landing page mentions nowcast, but detailed endpoint does not guarantee it. | Observations only in this build. Free API is not a commercial release plan. Zoom capped to 7; zooming closer adds no radar precision. Frame timestamp is composite generation time, not every radar sample's observation time. |
| NOAA/NWS | Public forecast, grid and alert APIs; operational weather models can supply future precipitation. Raw model files are not ready-made animation tiles. | Viable US pipeline, requiring ingestion, projection, tiling, run management, coverage masks, and operational hosting. Do not scrape radar viewer internals. Since 2026-11-10 the app uses two NOAA-derived products, both through documented public services: NWS active alerts (in-app list, not push) and HRRR simulated reflectivity tiles rendered by the Iowa Environmental Mesonet (see below). |
| Iowa Environmental Mesonet (IEM) | Documented TMS layer `hrrr::REFD-FXXXX-YYYYMMDDHHMI` ("archived HRRR reflectivity forecasts"), 15-minute steps to minute 1080, with per-step JSON metadata giving the model run and valid time. Website materials are stated to be public domain; attribution appreciated; no warranty. Verified live 2026-11-10. | US-only model futurecast. Latest complete run was 3.5 h old when checked, so usable look-ahead is roughly 14 to 16 hours, not 18. Occasional dropped connections observed. A free university service: keep request volume low, credit IEM, and expect outages. Not a commercial-grade dependency. |
| Open-Meteo | Model-based point forecasts, hourly precipitation and probabilities; geographic/model dependent high resolution products also exist. Public API is for noncommercial use. | Working key-free personal forecast. Current endpoint is a model estimate, not a station observation. Commercial access needs an appropriate plan. CC BY attribution does not waive hosted API terms. |
| Weather Underground | No verified redistribution entitlement in this project. | No scraping or reuse of private station credentials. Add only after explicit licensed station-data access. |

## Primary sources

- Foreca map layers, capabilities and authentication: https://developer.foreca.com/docs/weather-maps
- Foreca pricing and contracts: https://business.foreca.com/weather-api/pricing
- RainViewer detailed endpoint: https://www.rainviewer.com/api/weather-maps-api.html
- RainViewer terms: https://www.rainviewer.com/api.html
- Azure tiles and temporal limits: https://learn.microsoft.com/en-us/rest/api/maps/render/get-map-tile?view=rest-maps-2024-04-01
- NWS API: https://www.weather.gov/documentation/services-web-api
- Open-Meteo forecast: https://open-meteo.com/en/docs
- Open-Meteo hosted service terms: https://open-meteo.com/en/terms
- MapLibre installation: https://maplibre.org/maplibre-native/ios/latest/documentation/maplibre-native-for-ios/gettingstarted/

Provider documents change. Confirm entitlements in the actual account before enabling paid data. Pricing is intentionally not quoted without an account-specific map quote.

## Forecast semantics

Observed: measured precipitation composite, with latency and coverage gaps. Nowcast: provider-generated short-range prediction; not merely an image shifted across the map. Forecast: model or provider prediction with issue/run time. Five-minute tile intervals do not imply five-minute forecast skill. No numerical confidence is fabricated. Display qualitative increasing uncertainty until ensembles or calibrated probabilities are available.

Near-term finer timesteps should come from actual capabilities: select original valid frames densely near now, less densely later. Never interpolate new weather values or silently blend runs/providers into a seemingly continuous, equally reliable forecast. Keep source and issue time attached to every frame.

- OpenFreeMap hosting and attribution: https://openfreemap.org/
- Dark basemap style license: https://github.com/hyperknot/openfreemap-styles/blob/main/styles/dark/LICENSE.md
