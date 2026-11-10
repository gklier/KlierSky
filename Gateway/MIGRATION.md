# Automatic device access — prepared migration (not deployed)

Prepared overnight on 2026-11-09/10; reviewed and hardened in the cloud session of 2026-11-10 (see "Review findings" below). Nothing in this file has been run against the production gateway host. The live gateway is unchanged and still accepts only the owner token.

## What changes

Today every phone needs the owner's token (pairing code or pasted token). After this migration:

- A new install asks the gateway for its own credential (`POST /v1/devices`) with a random install ID. No secret ships in the app and nobody types anything.
- The gateway issues a random per-device token and stores only its SHA-256 hash. Device tokens can read `/forecast`, `/nowcast`, `/maps` and their own status. They cannot change the Foreca key, list devices, approve, revoke or change enrollment: those need the owner token (HTTP 403 `owner_required`).
- The Foreca key stays where it is, in the owner-only key file on the server. It is configured once per server, never per phone.
- Your existing owner token keeps working exactly as before. A phone that still has it saved needs no action.
- Each device has a per-minute and per-day request limit; there is a cap on approved devices and a separate, equal cap on waiting requests, a limit on enrollments per hour and day, an optional daily ceiling on real Foreca calls, and idle devices lose their slot after `DEVICE_IDLE_DAYS`.
- With `DEVICE_STATE_FILE` unset the server behaves exactly as the deployed version does (the tests check this), so installing the file alone changes nothing.

## Enrollment modes — your decision

| Mode | New phone | Risk | Use when |
|---|---|---|---|
| `open` | Works immediately, zero touch | Anyone who learns the hostname and the request format can take one of the `MAX_DEVICES` slots and read forecasts within the limits, until you revoke it and close enrollment. They can never reach the Foreca key or admin functions. | While you and family are installing. |
| `approval` | Enrolls itself, shows a 4-character code, uses Open-Meteo until you approve it | A stranger gets nothing without your approval. Strangers can fill the waiting list (`MAX_DEVICES` requests, dropped after `PENDING_DAYS`, default 7) but never an approved slot; clear it with Forget/`remove`. | Steady state, if one tap per new install is acceptable. |
| `closed` | Refused; existing devices keep working | None from new devices. | Once everyone is enrolled. |

Recommended: `open` with `MAX_DEVICES=6` while installing, then `closed` (or `approval`). You can switch at any time from the app (Settings → Owner administration, on a phone holding the owner token) or on the server with the command below. A reinstall that loses the Keychain needs enrollment to be `open` or `approval` again at that moment.

Honest limit: without Apple's App Attest the server cannot prove a request comes from a genuine KlierSky install, and a revoked person can enroll again as a "new" device while enrollment is open. App Attest needs a paid Developer Program App ID and does not work with free SideStore signing (each SideStore user re-signs under their own team). So `open` is an owner-beta convenience, not a production design. The production gate is paid membership + TestFlight/App Store distribution + App Attest (or Sign in with Apple) on enrollment. Do not treat open enrollment as production-ready.

## One-time server setup (about five minutes, run by you)

Run on the gateway host as root. Step 1 is the rollback point.

```sh
# 1. Back up the running version
cp -p /opt/kliersky/server.py /opt/kliersky/server.py.before-device-access

# 2. Install the new server (copy Gateway/server.py from this project to the container first)
install -o root -g root -m 0644 server.py /opt/kliersky/server.py

# 3. Add the settings (the state directory /var/lib/kliersky already exists and is owned by the service user)
cat >> /etc/kliersky/gateway.env <<'ENV'
DEVICE_STATE_FILE=/var/lib/kliersky/devices.json
ENROLLMENT_MODE=open
MAX_DEVICES=6
DEVICE_DAILY_REQUESTS=400
UPSTREAM_DAILY_BUDGET=4000
ENV

# 4. Restart and check
systemctl restart kliersky && systemctl is-active kliersky
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8787/health        # expect 401
```

Set `UPSTREAM_DAILY_BUDGET` to fit your Foreca plan's daily or monthly allowance: one uncached forecast costs up to four Foreca calls, and responses are cached for five minutes per ~1 km location. `0` means no ceiling (the current behavior).

The app finds the gateway from its build configuration: build 0.4 with `KLIERSKY_GATEWAY_URL` set to your HTTPS origin (see `Config/Local.example.xcconfig`). The address is not a credential; no key or token is ever built in. A build without it uses Open-Meteo and says "No weather service address is set".

Then open KlierSky 0.4 on a phone with no saved token: Settings → Forecast source should read "Connected" within one refresh, and the main screen should say Foreca.

## Day-to-day administration

In the app, on a phone that holds the owner token: Settings → Owner administration → Devices. Or on the server:

```sh
sudo -u kliersky env DEVICE_STATE_FILE=/var/lib/kliersky/devices.json python3 /opt/kliersky/server.py devices list
sudo -u kliersky env DEVICE_STATE_FILE=/var/lib/kliersky/devices.json python3 /opt/kliersky/server.py devices approve <deviceID>
sudo -u kliersky env DEVICE_STATE_FILE=/var/lib/kliersky/devices.json python3 /opt/kliersky/server.py devices revoke <deviceID>
sudo -u kliersky env DEVICE_STATE_FILE=/var/lib/kliersky/devices.json python3 /opt/kliersky/server.py devices mode closed
```

Changes made by the command are picked up by the running service on the next request; no restart. `revoke` blocks a device and the app will not re-enroll by itself. `remove` only forgets it (the app may enroll again while enrollment is open).

## Rollback

```sh
cp -p /opt/kliersky/server.py.before-device-access /opt/kliersky/server.py
sed -i '/^DEVICE_STATE_FILE=/d;/^ENROLLMENT_MODE=/d;/^MAX_DEVICES=/d;/^DEVICE_DAILY_REQUESTS=/d;/^UPSTREAM_DAILY_BUDGET=/d' /etc/kliersky/gateway.env
systemctl restart kliersky
```

Phones on 0.4 then fall back to Open-Meteo by themselves and say so; a phone with the owner token keeps Foreca. `/var/lib/kliersky/devices.json*` can be left or deleted.

## Optional hardening at Cloudflare

A WAF rate-limiting rule on `POST <your-gateway-host>/v1/devices` (for example 5 per hour per IP) adds a per-address limit the origin cannot apply itself, because it only sees the tunnel. The origin already limits enrollments globally.

## What was tested locally

`python3 -m unittest discover -s Gateway -p 'test_*.py'` runs 40 tests (rerun in the cloud session on Linux, Python 3.13, 2026-11-10: all pass); `test_devices.py` drives a real gateway instance over HTTP on loopback with a temporary state directory and synthetic Foreca schema fixtures. Covered: fresh install, device token refused for every admin and credential route, no token/install ID/vendor key in the state file or any reply, owner token unchanged, unmigrated behavior unchanged, reinstall with and without a saved credential, retry rotation, device cap, idle expiry, self-removal, revocation (including via the server command against a running gateway), approval mode, closed mode, enrollment/quota/per-minute/vendor-budget limits, location coarsening before the vendor call, waiting requests not consuming approved slots, approval refused at the device limit, and expiry of unapproved requests. Not tested: the real service unit, the Cloudflare tunnel path, or real Foreca responses with a device token.

## Review findings (cloud session, 2026-11-10)

Fixed in `server.py`, with tests:

- **Waiting requests could exhaust the device slots.** In `approval` mode every unapproved request counted against `MAX_DEVICES` for up to 60 days, so six requests from anyone who knew the hostname would lock real family phones out. Approved devices and waiting requests now have separate caps, an approval that would exceed the approved cap is refused (HTTP 409 `device_limit_reached`), and unapproved requests are dropped after `PENDING_DAYS` (default 7; polling does not extend them). The app re-requests by itself.

Tradeoffs that remain, by design or because they need infrastructure this project does not have:

- **Enrollment pacing.** `ENROLL_PER_HOUR` defaults to 4 and `ENROLL_PER_DAY` to 12, counted across all phones including retries. Installing a fifth phone within the same hour is refused (`enrollment_rate_limited`) and that phone waits an hour before trying again, unless you tap "Check now" in Settings after the hour. Raise `ENROLL_PER_HOUR` for install day if needed.
- **Shared request ceiling.** All requests share one 240-per-minute limit because the origin only sees the tunnel address. A stranger flooding the hostname can make the service refuse family requests for that minute (the app then shows Open-Meteo, labelled as a fallback). Per-address limiting has to happen at Cloudflare, as described above.
- **No proof of a genuine app.** Unchanged from the note above: without App Attest, `open` mode admits anything that speaks the protocol, within the caps. Reading forecasts is all it gains.
- **Revocation list is bounded.** Revoked entries are kept 180 days (at most 200). After that the same install could enroll again while enrollment is `open` or `approval`.
- **Quota counters are advisory across restarts.** Usage is written at most once a minute; a crash can forget up to a minute of counts. Identity, approval and revocation state is always written immediately.
- **Not exercised:** the real service unit, the tunnel path, real Foreca replies with a device token, and the iOS client against a live migrated gateway.
