# Licensed precipitation map contract

In the app's information sheet, configure an HTTPS endpoint operated by you. The client adds `latitude` and `longitude`. The endpoint must enforce entitlements and return a JSON array of frames, sorted or sortable by validTime. All dates use ISO-8601 UTC, without fractional seconds. Provider API keys and bearer tokens remain in server environment/secret storage. Never put them in Swift source, Info.plist, the manifest URL, or a committed configuration file.

Example shape only, not usable weather data:

```json
[
  {
    "id": "provider-run-validtime",
    "validTime": "2026-11-07T06:00:00Z",
    "issuedTime": "2026-11-07T04:00:00Z",
    "kind": "forecast",
    "tileURL": "https://your-backend.example/tiles/run/frame/{z}/{x}/{y}.png",
    "attribution": "Contract-required provider attribution",
    "maxZoom": 12
  }
]
```

`kind` must be `observed`, `nowcast`, or `forecast`. Use provider provenance to decide; do not classify all frames within two hours as nowcast. An issue timestamp represents the actual run, never the time your server answered a request. `tileURL` is a Web Mercator XYZ 256-pixel raster template, HTTPS, without vendor secrets. Proxy tiles on the server or issue short-lived scoped client tokens. This prototype has no user authentication; keep any test endpoint low volume and restricted. Production needs authenticated sessions, rate limits, abuse prevention, vendor-approved caching and legal attribution links.

The app validates HTTPS, zoom bounds, maximum 300 manifest entries, and rejects observed frames dated in the future. It separately selects future predictions; it does not silently relabel observations. The map currently holds all selected sources resident, so send a bounded operational timeline (recommend <=72), not every five-minute frame for three days. A 12-hour timeline can retain five-minute frames for the first hour, 15-minute frames to six hours, and hourly frames thereafter. Select actual provider timesteps; do not invent intermediate images. Match coverage to requested coordinates on the server. Return an empty array outside licensed coverage, never transparent tiles disguised as dry conditions.

Before production, extend the contract to include geographic coverage, tile no-data masks, precipitation type/palette and legend, ensemble confidence, update cadence, authentication expiration, and source attribution URLs. Hard-coded prototype legend does not assert a calibrated reflectivity scale. A provider swap must include its correct legend.

## Foreca server implementation outline

1. Obtain licensed map access and confirm permission for tile proxying/caching.
2. Authenticate on the server according to Foreca's current documentation.
3. Fetch capabilities and select layer 22 for model precipitation, or a regional combined layer only with explicit provenance boundaries.
4. Use advertised timestamps and available zooms, preserving run issue times. Thin actual frames by lead time.
5. Proxy tiles using the documented endpoint and token header; apply cache limits from the contract.
6. Return the normalized manifest above, with appropriate source credit. Renew credentials server-side.

This repository intentionally includes no guessed vendor request parameters, fake credentials, or fake forecast imagery. The normalized adapter is implemented; the vendor backend is now implemented in `Gateway/server.py` but is not deployed. Hosting was deferred by the user.
