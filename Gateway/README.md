# Foreca gateway

Run `server.py` on your own HTTPS server. Vendor credentials remain server-side; the iPhone stores only its gateway access token in Keychain. Bind to loopback behind an HTTPS reverse proxy.

Required environment: `KLIERSKY_ACCESS_TOKEN` (at least 32 random characters), `FORECA_KEY_FILE` (owner-only file), and `PUBLIC_ORIGIN` (your HTTPS origin). Optional: `KLIERSKY_SIGNING_SECRET`, `PAIR_STATE_FILE`, `FORECA_MAPS_ENABLED=1` only with the required entitlement; device access: `DEVICE_STATE_FILE`, `ENROLLMENT_MODE`, `MAX_DEVICES`, `ENROLL_PER_HOUR`, `ENROLL_PER_DAY`, `DEVICE_DAILY_REQUESTS`, `DEVICE_PER_MINUTE`, `DEVICE_IDLE_DAYS`, `PENDING_DAYS`, `UPSTREAM_DAILY_BUDGET`. Never commit environment files or keys. See server.py for pairing and signed-tile handling.

`GET /health`, `/forecast`, `/nowcast`, `/maps` require a bearer token. `PUT /credentials` provisions the vendor key; keep that owner token private. Per-device read-only access, quotas, approval and revocation are implemented behind `DEVICE_STATE_FILE` and covered by tests, but are **not deployed**: see [MIGRATION.md](MIGRATION.md) for the one-time setup, the enrollment-mode tradeoffs and the review findings. Until that migration is run, the live service accepts only the owner token.

The included systemd service is a template: adapt users, paths and hardening to your environment. Keep request logs disabled to avoid logging coordinates, credentials or signatures.

Run `python3 -m unittest discover -s Gateway -p "test_*.py"` from the repository root. Map integration requires separately licensed access; point access alone does not activate futurecast imagery.
