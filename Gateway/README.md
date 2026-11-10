# Foreca gateway

Run `server.py` on your own HTTPS server. Vendor credentials remain server-side; the iPhone stores only its gateway access token in Keychain. Bind to loopback behind an HTTPS reverse proxy.

Required environment: `KLIERSKY_ACCESS_TOKEN` (at least 32 random characters), `FORECA_KEY_FILE` (owner-only file), and `PUBLIC_ORIGIN` (your HTTPS origin). Optional: `KLIERSKY_SIGNING_SECRET`, `PAIR_STATE_FILE`, `FORECA_MAPS_ENABLED=1` only with the required entitlement. Never commit environment files or keys. See server.py for pairing and signed-tile handling.

`GET /health`, `/forecast`, `/nowcast`, `/maps` require a bearer token. `PUT /credentials` provisions the vendor key; keep that owner token private. This is currently an owner-testing service, not a family authorization system. Add per-device read-only access and revocation before distributing to other people.

The included systemd service is a template: adapt users, paths and hardening to your environment. Keep request logs disabled to avoid logging coordinates, credentials or signatures.

Run `python3 -m unittest discover -s Gateway -p "test_*.py"` from the repository root. Map integration requires separately licensed access; point access alone does not activate futurecast imagery.
