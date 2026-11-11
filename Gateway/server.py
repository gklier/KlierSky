#!/usr/bin/env python3
"""Personal Foreca gateway. Vendor credentials never leave this process.
Run behind an HTTPS reverse proxy, or set TLS_CERT and TLS_KEY. Loopback by default.
"""
import base64
import contextlib
import fcntl
import hashlib
import hmac
import json
import math
import os
import re
import secrets
import ssl
import sys
import threading
import time
from collections import OrderedDict, defaultdict, deque
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.parse import parse_qs, quote, urlencode, urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler

class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise GatewayError(502, "upstream_redirect_rejected")

UPSTREAM_CLIENT = build_opener(NoRedirects())

UPSTREAM = 'https://weatherapi.foreca.net'
KEY_FILE = os.environ.get('FORECA_KEY_FILE', '')
FORECA_KEY = os.environ.get('FORECA_API_KEY', '')
if not FORECA_KEY and KEY_FILE and os.path.isfile(KEY_FILE):
    if os.stat(KEY_FILE).st_mode & 0o077: raise SystemExit('Foreca key file must be owner-only.')
    with open(KEY_FILE, encoding='utf-8') as handle: FORECA_KEY = handle.read().strip()
PAIR_FILE = os.environ.get('PAIR_STATE_FILE', '')
ACCESS_TOKEN = os.environ.get('KLIERSKY_ACCESS_TOKEN', '')
PUBLIC_ORIGIN = os.environ.get('PUBLIC_ORIGIN', '').rstrip('/')
SIGNING_KEY = os.environ.get('KLIERSKY_SIGNING_SECRET', '').encode() or secrets.token_bytes(32)
LOCK = threading.Lock()
CACHE = OrderedDict()
MANIFESTS = {}
RATE = defaultdict(deque)

def env_int(name, default, low, high):
    try: value = int(os.environ.get(name, default))
    except ValueError: raise SystemExit(name + ' must be an integer.')
    if not low <= value <= high: raise SystemExit(f'{name} must be between {low} and {high}.')
    return value

# Per-device read-only access. Disabled unless DEVICE_STATE_FILE is set, so an
# existing owner-token deployment behaves exactly as before until migrated.
DEVICE_FILE = os.environ.get('DEVICE_STATE_FILE', '')
ENROLLMENT_MODES = ('closed', 'approval', 'open')
ENROLLMENT_DEFAULT = os.environ.get('ENROLLMENT_MODE', 'closed')
if ENROLLMENT_DEFAULT not in ENROLLMENT_MODES: raise SystemExit('ENROLLMENT_MODE must be closed, approval or open.')
MAX_DEVICES = env_int('MAX_DEVICES', 6, 1, 64)
ENROLL_PER_HOUR = env_int('ENROLL_PER_HOUR', 4, 1, 100)
ENROLL_PER_DAY = env_int('ENROLL_PER_DAY', 12, 1, 500)
DEVICE_DAILY_REQUESTS = env_int('DEVICE_DAILY_REQUESTS', 400, 1, 100000)
DEVICE_PER_MINUTE = env_int('DEVICE_PER_MINUTE', 30, 1, 600)
DEVICE_IDLE_DAYS = env_int('DEVICE_IDLE_DAYS', 60, 1, 3650)
PENDING_DAYS = env_int('PENDING_DAYS', 7, 1, 365)  # an unapproved request is dropped after this; the app simply asks again
UPSTREAM_DAILY_BUDGET = env_int('UPSTREAM_DAILY_BUDGET', 0, 0, 10000000)  # 0 keeps the legacy unlimited behavior
BUDGET = {'day': '', 'count': 0}

class GatewayError(Exception):
    def __init__(self, status, code): self.status, self.code = status, code

def iso(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00')).astimezone(timezone.utc)

def stamp(value):
    return value.astimezone(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')

def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise GatewayError(502, 'missing_or_invalid_weather_value')
    return value

def coordinates(query):
    try:
        lat, lon = float(query['latitude'][0]), float(query['longitude'][0])
        if not math.isfinite(lat) or not math.isfinite(lon) or not -90 <= lat <= 90 or not -180 <= lon <= 180: raise ValueError()
        return lat, lon
    except (KeyError, IndexError, ValueError): raise GatewayError(400, 'invalid_coordinates')

def request_foreca(path, query=None, binary=False, ttl=0):
    if not FORECA_KEY: raise GatewayError(503, 'foreca_key_not_configured')
    uri = UPSTREAM + path + ('?' + urlencode(query) if query else '')
    with LOCK:
        cached = CACHE.get(uri)
        if cached and cached[0] > time.time(): return cached[1]
    if UPSTREAM_DAILY_BUDGET:
        # Counts real vendor calls only; cache hits above are free.
        with LOCK:
            if BUDGET['day'] != today(): BUDGET['day'], BUDGET['count'] = today(), 0
            if BUDGET['count'] >= UPSTREAM_DAILY_BUDGET: raise GatewayError(429, 'upstream_budget_exhausted')
            BUDGET['count'] += 1
    req = Request(uri, headers={'Authorization': 'Bearer ' + FORECA_KEY, 'User-Agent': 'KlierSky-personal-gateway/0.2'})
    try:
        with UPSTREAM_CLIENT.open(req, timeout=20) as response:
            data = response.read(4 * 1024 * 1024 + 1)
            if len(data) > 4 * 1024 * 1024: raise GatewayError(502, 'upstream_response_too_large')
            if binary and not data.startswith(b'\x89PNG\r\n\x1a\n'): raise GatewayError(502, 'invalid_tile')
            value = data if binary else json.loads(data)
    except HTTPError as error:
        raise GatewayError(502 if error.code >= 500 else error.code, 'foreca_access_or_request_failed') from None
    except (OSError, ValueError): raise GatewayError(502, 'foreca_delivery_failed') from None
    if ttl > 0:
        with LOCK:
            CACHE[uri] = (time.time() + ttl, value)
            while len(CACHE) > 128: CACHE.popitem(last=False)
    return value

def weather_code(record):
    # Original phrase is preserved; WMO symbol conversion is presentation only.
    phrase = record.get('symbolPhrase', '').lower()
    for word, code in [('thunder', 95), ('snow', 71), ('sleet', 69), ('rain', 61), ('drizzle', 51), ('fog', 45), ('overcast', 3), ('cloud', 2)]:
        if word in phrase: return code
    if 'clear' in phrase or 'sunny' in phrase: return 0
    symbol = record.get('symbol', '').lower()
    if re.fullmatch('[dn][0-6][0-4][0-2]', symbol):
        cloud, rain, kind = map(int, symbol[1:])
        if rain == 4: return 95
        if rain:
            if kind == 2: return 73 if rain >= 3 else 71
            if kind == 1: return 69
            return 80 if rain == 2 else 63 if rain == 3 else 61
        return 45 if cloud == 6 else 0 if cloud == 0 else 1 if cloud in (1,5) else 2 if cloud == 2 else 3
    return None

def normalize_forecast(current, hourly, daily=None):
    c = current['current']
    rows = sorted(hourly['forecast'], key=lambda row: iso(row['time']))
    normalized = []
    for row in rows:
        t, amount, chance = number(row['temperature']), row.get('precipAccum'), row.get('precipProb')
        if amount is not None and number(amount) < 0: raise GatewayError(502, 'invalid_precipitation')
        if chance is not None and not 0 <= number(chance) <= 100: raise GatewayError(502, 'invalid_probability')
        normalized.append((iso(row['time']).timestamp(), t, amount, chance, weather_code(row), 0 if row.get('symbol', '').startswith('n') else 1))
    if not normalized: raise GatewayError(502, 'empty_forecast')
    code = weather_code(c)
    # Missing condition is an unknown symbol, never assumed to be clear.
    result = {'source': 'Foreca', 'current': {'temperature_2m': number(c['temperature']), 'apparent_temperature': number(c['feelsLikeTemp']), 'wind_speed_10m': number(c['windSpeed']), 'weather_code': code if code is not None else -1, 'is_day': 0 if c.get('symbol', '').startswith('n') else 1, 'summary': c.get('symbolPhrase')},
            'hourly': {'time': [r[0] for r in normalized], 'temperature_2m': [r[1] for r in normalized], 'precipitation': [r[2] for r in normalized], 'precipitation_probability': [r[3] for r in normalized], 'weather_code': [r[4] for r in normalized], 'is_day': [r[5] for r in normalized]}}

    field_map = {'relative_humidity_2m':'relHumidity', 'dew_point_2m':'dewPoint', 'wind_gusts_10m':'windGust', 'wind_direction_10m':'windDir', 'pressure_msl':'pressure', 'cloud_cover':'cloudiness', 'visibility':'visibility'}
    for output, original in field_map.items():
        result['current'][output] = c.get(original)
        result['hourly'][output] = [r.get(original) for r in rows]
    result['hourly']['wind_speed_10m'] = [r.get('windSpeed') for r in rows]
    result['hourly']['uv_index'] = [r.get('uvIndex') for r in rows]
    result['hourly']['apparent_temperature'] = [r.get('feelsLikeTemp') for r in rows]
    if c.get('time'): result['utc_offset_seconds'] = int(iso_offset(c['time']))
    result['dailyRows'] = []
    if daily:
        for row in daily.get('forecast', []):
            date = row.get('date', '')
            if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', date): continue
            high = row.get('maxTempEnsemble') or {}
            result['dailyRows'].append({'dateKey':date, 'low':row.get('minTemp'), 'high':row.get('maxTemp'), 'code':weather_code(row), 'rain':row.get('precipAccum'), 'chance':row.get('precipProb'), 'wind':row.get('maxWindSpeed'), 'gust':row.get('maxWindGust'), 'uv':row.get('uvIndex'), 'sunriseLocal':row.get('sunrise'), 'sunsetLocal':row.get('sunset'), 'feelsLow':row.get('minFeelsLikeTemp'), 'feelsHigh':row.get('maxFeelsLikeTemp'), 'source':'Foreca', 'probabilityLabel':'Provider daily probability', 'highP25':high.get('p025'), 'highP75':high.get('p075'), 'summary':row.get('symbolPhrase')})
    return result

def iso_offset(value):
    return datetime.fromisoformat(value.replace('Z','+00:00')).utcoffset().total_seconds()


def forecast(lat, lon):
    location = quote(f'{lon},{lat}', safe=',.-')
    query = {'tempunit': 'F', 'windunit': 'MPH', 'tz': 'UTC', 'dataset': 'full', 'rounding': '0'}
    with ThreadPoolExecutor(max_workers=4) as pool:
        current = pool.submit(request_foreca, '/api/v1/current/' + location, query, ttl=300)
        hourly = pool.submit(request_foreca, '/api/v1/forecast/hourly/' + location, dict(query, periods=169), ttl=300)
        metadata = pool.submit(request_foreca, '/api/v1/location/' + location, ttl=86400)
        daily = pool.submit(request_foreca, '/api/v1/forecast/daily/' + location, {'tempunit':'F', 'windunit':'MPH', 'dataset':'full', 'periods':14, 'ensemble':1, 'rounding':0}, ttl=900)
        try: days = daily.result()
        except GatewayError:
            try: days = request_foreca('/api/v1/forecast/daily/' + location, {'tempunit':'F','windunit':'MPH','dataset':'full','periods':14,'ensemble':0,'rounding':0}, ttl=900)
            except GatewayError: days = None
        result = normalize_forecast(current.result(), hourly.result(), days)
        try: result['timezone'] = metadata.result().get('timezone')
        except GatewayError: pass
        return result

def nowcast(lat, lon):
    data = request_foreca('/api/v1/forecast/minutely/' + quote(f'{lon},{lat}', safe=',.-'), {'tz': 'UTC'}, ttl=60)
    resolution = data.get('resolution')
    if not isinstance(resolution, int) or resolution < 1: raise GatewayError(502, 'missing_temporal_resolution')
    return {'resolution': resolution, 'points': [{'time': stamp(iso(row['time'])), 'rate': number(row['precipRate'])} for row in data['forecast'] if number(row['precipRate']) >= 0]}

def signature(key, expiry):
    return hmac.new(SIGNING_KEY, (key + '|' + str(expiry)).encode(), hashlib.sha256).hexdigest()

def maps(lat, lon):
    if os.environ.get('FORECA_MAPS_ENABLED') != '1': raise GatewayError(403, 'map_entitlement_not_enabled')
    origin = urlsplit(PUBLIC_ORIGIN)
    if origin.scheme != 'https' or not origin.netloc or origin.path or origin.query or origin.fragment or origin.username:
        raise GatewayError(503, 'https_public_origin_required')
    capabilities = request_foreca('/api/v1/capabilities', ttl=300)
    # Layer22 is explicitly model precipitation. Combined radar layers are not
    # used because their within-layer provenance transitions are not specified.
    layer = next((image for image in capabilities['images'] if image['id'] == 22), None)
    if not layer: raise GatewayError(403, 'forecast_layer_not_entitled')
    e = layer['extent']
    if not e['minLat'] <= lat <= e['maxLat'] or not e['minLon'] <= lon <= e['maxLon']: return []
    expiry = int(time.time()) + 3600
    updated = stamp(iso(layer['times']['updated']))
    analysis = layer.get('analysis')
    try:
        issued = datetime.strptime(analysis, '%Y%m%d%H%M%S').replace(tzinfo=timezone.utc)
        label = 'Model run'
    except (ValueError, TypeError): issued, label = iso(updated), 'Updated'
    frames = []
    last = None
    now = datetime.now(timezone.utc)
    for valid in sorted(set(layer['times']['available'])):
        date = iso(valid); lead = (date - now).total_seconds()
        if not 0 <= lead <= 24 * 3600: continue
        spacing = 300 if lead <= 3600 else 900 if lead <= 6 * 3600 else 3600
        if last and (date - last).total_seconds() < spacing: continue
        last = date
        key = hashlib.sha256((valid + '|' + updated + '|22|' + str(expiry)).encode()).hexdigest()[:32]
        with LOCK:
            MANIFESTS[key] = {'expiry': expiry, 'valid': valid, 'updated': updated, 'min': int(e['minZoom']), 'max': min(14, int(e['maxZoom']))}
            expired = [k for k, value in MANIFESTS.items() if value['expiry'] < time.time()]
            for k in expired: del MANIFESTS[k]
            if len(MANIFESTS) > 500: raise GatewayError(503, 'manifest_capacity')
        frames.append({'id': key, 'validTime': stamp(date), 'issuedTime': stamp(issued), 'kind': 'forecast', 'tileURL': PUBLIC_ORIGIN + '/tiles/' + key + '/{z}/{x}/{y}.png?' + urlencode({'expires': expiry, 'sig': signature(key, expiry)}), 'attribution': layer.get('attribution') or 'Foreca', 'maxZoom': min(14, int(e['maxZoom'])), 'minZoom': int(e['minZoom']), 'timeLabel': label, 'expiresAt': stamp(datetime.fromtimestamp(expiry, timezone.utc))})
    return frames[:72]

def tile(path, query):
    match = re.fullmatch(r'/tiles/([0-9a-f]{32})/(\d{1,2})/(\d{1,8})/(\d{1,8})\.png', path)
    if not match: raise GatewayError(404, 'unknown_tile')
    key, z, x, y = match.groups(); z, x, y = int(z), int(x), int(y)
    try: expiry = int(query['expires'][0]); sig = query['sig'][0]
    except (KeyError, ValueError, IndexError): raise GatewayError(403, 'invalid_tile_signature')
    if expiry < time.time() or expiry > time.time() + 3600 or not hmac.compare_digest(signature(key, expiry), sig): raise GatewayError(403, 'expired_or_invalid_tile')
    with LOCK: record = MANIFESTS.get(key)
    if not record or record['expiry'] != expiry or not record['min'] <= z <= record['max'] or not 0 <= x < 2 ** z or not 0 <= y < 2 ** z: raise GatewayError(403, 'tile_outside_manifest')
    return request_foreca('/api/v1/image/tile/' + f'{z}/{x}/{y}/' + quote(record['valid'], safe='') + '/22', {'updated': record['updated']}, binary=True, ttl=0)

def redeem_pair_code(code):
    if not PAIR_FILE or not isinstance(code, str) or not re.fullmatch(r'\d{8}',code): raise GatewayError(403,'invalid_pair_code')
    with LOCK:
        with open(PAIR_FILE, encoding='utf-8') as handle: state = json.load(handle)
        if state.get('used') or state.get('expires',0) < time.time() or state.get('attempts',0) >= 5: raise GatewayError(403,'pair_code_expired_or_used')
        state['attempts'] = state.get('attempts',0) + 1
        valid = hmac.compare_digest(hashlib.sha256(code.encode()).hexdigest(), state['hash'])
        state['used'] = valid
        fd = os.open(PAIR_FILE, os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW)
        with os.fdopen(fd,'w',encoding='utf-8') as handle: json.dump(state,handle)
        if not valid: raise GatewayError(403,'invalid_pair_code')
        return ACCESS_TOKEN

def today():
    return time.strftime('%Y-%m-%d', time.gmtime())

def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()

class Registry:
    """Revocable per-device read-only credentials.

    Only SHA-256 hashes of the random device tokens and install identifiers are
    stored. The file is owner-only, rewritten atomically, and shared with the
    `server.py devices ...` command through an advisory lock, so the owner can
    approve or revoke on the server without any phone holding an admin secret.
    """
    CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'

    def __init__(self, path):
        self.path = path
        self.guard = threading.RLock()
        self.mtime = None
        self.state = None
        self.tokens = {}
        self.usage = {}
        self.enrollments = deque()
        self.flushed = 0.0
        self.load_usage()

    @contextlib.contextmanager
    def locked(self):
        with self.guard:
            fd = os.open(self.path + '.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX)
                yield
            finally:
                fcntl.flock(fd, fcntl.LOCK_UN); os.close(fd)

    def read(self):
        """Return current state, reloading when another process changed the file."""
        try: info = os.stat(self.path)
        except FileNotFoundError:
            if self.state is None or self.mtime is not None:
                self.state = {'version': 1, 'enrollment': ENROLLMENT_DEFAULT, 'devices': {}}; self.tokens = {}; self.mtime = None
            return self.state
        if info.st_mode & 0o077: raise GatewayError(503, 'device_state_not_owner_only')
        if self.state is None or info.st_mtime_ns != self.mtime:
            with open(self.path, encoding='utf-8') as handle: state = json.load(handle)
            if not isinstance(state, dict) or not isinstance(state.get('devices'), dict) or state.get('enrollment') not in ENROLLMENT_MODES:
                raise GatewayError(503, 'device_state_invalid')
            self.state = state; self.mtime = info.st_mtime_ns
            self.tokens = {record['tokenHash']: device for device, record in state['devices'].items()}
        return self.state

    def write(self):
        temp = self.path + '.new'
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as handle: json.dump(self.state, handle, indent=1, sort_keys=True)
        os.chmod(temp, 0o600); os.replace(temp, self.path)
        self.mtime = os.stat(self.path).st_mtime_ns
        self.tokens = {record['tokenHash']: device for device, record in self.state['devices'].items()}

    # Usage counters are written only by the server process, at most once a minute.
    def load_usage(self):
        try:
            with open(self.path + '.usage', encoding='utf-8') as handle: saved = json.load(handle)
            for device, row in saved.get('devices', {}).items():
                self.usage[device] = {'day': str(row.get('day', '')), 'count': int(row.get('count', 0)), 'seen': float(row.get('seen', 0)), 'recent': deque()}
            if saved.get('budget', {}).get('day') == today(): BUDGET['day'], BUDGET['count'] = today(), int(saved['budget'].get('count', 0))
        except (OSError, ValueError, TypeError, AttributeError): pass

    def flush_usage(self, force=False):
        if not force and time.time() - self.flushed < 60: return
        self.flushed = time.time()
        data = {'devices': {device: {'day': row['day'], 'count': row['count'], 'seen': row['seen']} for device, row in self.usage.items()}, 'budget': dict(BUDGET)}
        try:
            temp = self.path + '.usage.new'
            fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'w', encoding='utf-8') as handle: json.dump(data, handle)
            os.replace(temp, self.path + '.usage')
        except OSError: pass  # Counters are advisory; identity state is never written here.

    def seen(self, device):
        row = self.usage.get(device)
        return row['seen'] if row else 0

    def expire(self, now):
        """Free slots held by devices that stopped connecting; keep a bounded revocation list."""
        devices = self.state['devices']; changed = False
        for device, record in list(devices.items()):
            last = max(self.seen(device), record.get('created', 0))
            if record['status'] == 'pending': last = record.get('created', 0)  # status polls do not keep a request alive
            limit = 180 if record['status'] == 'revoked' else PENDING_DAYS if record['status'] == 'pending' else DEVICE_IDLE_DAYS
            if now - last > limit * 86400: del devices[device]; self.usage.pop(device, None); changed = True
        revoked = sorted((d for d, r in devices.items() if r['status'] == 'revoked'), key=lambda d: devices[d].get('created', 0))
        for device in revoked[:-200]: del devices[device]; changed = True
        return changed

    def lookup(self, token):
        with self.guard:
            state = self.read()
            device = self.tokens.get(digest(token))
            if device is None: return None
            return dict(state['devices'][device], id=device)

    def charge(self, device):
        """Per-device request controls for weather endpoints."""
        now = time.time()
        with self.guard:
            row = self.usage.setdefault(device, {'day': today(), 'count': 0, 'seen': 0, 'recent': deque()})
            if row['day'] != today(): row['day'], row['count'] = today(), 0
            recent = row['recent']
            while recent and recent[0] < now - 60: recent.popleft()
            if len(recent) >= DEVICE_PER_MINUTE: raise GatewayError(429, 'device_rate_limited')
            if row['count'] >= DEVICE_DAILY_REQUESTS: raise GatewayError(429, 'device_quota_exceeded')
            recent.append(now); row['count'] += 1; row['seen'] = now
            self.flush_usage()

    def enroll(self, body):
        install, label = body.get('installID'), body.get('label', '')
        if not isinstance(install, str) or not re.fullmatch(r'[A-Za-z0-9_-]{22,64}', install): raise GatewayError(400, 'invalid_install_id')
        if not isinstance(label, str): raise GatewayError(400, 'invalid_label')
        label = re.sub(r'[^A-Za-z0-9 ._-]', '', label)[:40]
        marker = digest('install|' + install)
        now = time.time()
        with self.locked():
            state = self.read(); devices = state['devices']
            existing = next((d for d, r in devices.items() if hmac.compare_digest(r['installHash'], marker)), None)
            if existing and devices[existing]['status'] == 'revoked': raise GatewayError(403, 'device_revoked')
            if not existing and state['enrollment'] == 'closed': raise GatewayError(403, 'enrollment_closed')
            while self.enrollments and self.enrollments[0] < now - 86400: self.enrollments.popleft()
            if len(self.enrollments) >= ENROLL_PER_DAY or sum(1 for t in self.enrollments if t > now - 3600) >= ENROLL_PER_HOUR:
                raise GatewayError(429, 'enrollment_rate_limited')
            self.enrollments.append(now)
            self.expire(now)
            # Approved devices and waiting requests are capped separately, so unapproved
            # requests (possibly from strangers) can never use up the family's device slots.
            wanted = 'active' if state['enrollment'] == 'open' else 'pending'
            if not existing and sum(1 for r in devices.values() if r['status'] == wanted) >= MAX_DEVICES: raise GatewayError(403, 'device_limit_reached')
            token = 'ksd_' + secrets.token_urlsafe(32)
            if existing:
                # Same install asking again (lost reply, retry): rotate its token, keep its status.
                device = existing; record = devices[device]; record['tokenHash'] = digest(token); record['label'] = label or record.get('label', '')
            else:
                device = secrets.token_hex(8)
                record = {'tokenHash': digest(token), 'installHash': marker, 'role': 'reader', 'status': wanted,
                          'created': int(now), 'label': label, 'code': ''.join(secrets.choice(self.CODE_ALPHABET) for _ in range(4))}
                devices[device] = record
            self.write()
        return {'deviceID': device, 'accessToken': token, 'status': record['status'], 'role': 'reader', 'code': record['code']}

    def set_status(self, device, status):
        with self.locked():
            state = self.read(); record = state['devices'].get(device)
            if record is None: raise GatewayError(404, 'unknown_device')
            if status == 'removed': del state['devices'][device]; self.usage.pop(device, None)
            else:
                if status == 'active' and record['status'] != 'active' and sum(1 for r in state['devices'].values() if r['status'] == 'active') >= MAX_DEVICES:
                    raise GatewayError(409, 'device_limit_reached')
                record['status'] = status
            self.write()

    def set_mode(self, mode):
        if mode not in ENROLLMENT_MODES: raise GatewayError(400, 'invalid_enrollment_mode')
        with self.locked():
            self.read()['enrollment'] = mode; self.write()

    def listing(self):
        with self.guard:
            state = self.read()
            rows = [{'deviceID': device, 'label': r.get('label', ''), 'code': r.get('code', ''), 'status': r['status'], 'role': r.get('role', 'reader'), 'created': r.get('created', 0),
                     'lastSeen': int(self.seen(device)), 'requestsToday': self.usage.get(device, {}).get('count', 0) if self.usage.get(device, {}).get('day') == today() else 0}
                    for device, r in state['devices'].items()]
            return {'enrollment': state['enrollment'], 'maxDevices': MAX_DEVICES, 'dailyRequestsPerDevice': DEVICE_DAILY_REQUESTS,
                    'upstreamBudget': UPSTREAM_DAILY_BUDGET, 'upstreamUsedToday': BUDGET['count'] if BUDGET['day'] == today() else 0,
                    'devices': sorted(rows, key=lambda row: row['created'])}

    def self_status(self, device):
        with self.guard:
            record = self.read()['devices'][device]
            row = self.usage.get(device, {})
            return {'deviceID': device, 'role': 'reader', 'status': record['status'], 'code': record.get('code', ''),
                    'dailyLimit': DEVICE_DAILY_REQUESTS, 'usedToday': row.get('count', 0) if row.get('day') == today() else 0}

REGISTRY = Registry(DEVICE_FILE) if DEVICE_FILE else None

def authenticate(header):
    """Owner token → full access. Device token → read-only weather. Nothing else passes."""
    if not isinstance(header, str) or not header.startswith('Bearer ') or len(header) > 512: raise GatewayError(401, 'gateway_auth_required')
    token = header[7:]
    if ACCESS_TOKEN and hmac.compare_digest(token.encode('utf-8', 'replace'), ACCESS_TOKEN.encode()): return {'role': 'owner', 'id': 'owner', 'status': 'active'}
    if REGISTRY is not None:
        device = REGISTRY.lookup(token)
        if device is not None:
            if device['status'] == 'revoked': raise GatewayError(401, 'device_revoked')
            return {'role': 'reader', 'id': device['id'], 'status': device['status']}
    raise GatewayError(401, 'gateway_auth_required')

def require_owner(principal):
    if principal['role'] != 'owner': raise GatewayError(403, 'owner_required')

def admin_action(path, method, body):
    """Owner-only device administration. Returns the reply body."""
    if REGISTRY is None: raise GatewayError(404, 'device_access_not_configured')
    if path == '/v1/admin/enrollment' and method == 'PUT':
        REGISTRY.set_mode(body.get('mode')); return REGISTRY.listing()
    match = re.fullmatch(r'/v1/admin/devices/([0-9a-f]{16})(/approve|/revoke)?', path)
    if not match: raise GatewayError(404, 'not_found')
    device, action = match.groups()
    if method == 'POST' and action == '/approve': REGISTRY.set_status(device, 'active')
    elif method == 'POST' and action == '/revoke': REGISTRY.set_status(device, 'revoked')
    elif method == 'DELETE' and action is None: REGISTRY.set_status(device, 'removed')
    else: raise GatewayError(404, 'not_found')
    return REGISTRY.listing()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass  # Never log paths, signatures, coordinates or headers.
    def reply(self, status, data, content='application/json'):
        body = data if isinstance(data, bytes) else json.dumps(data, allow_nan=False).encode()
        self.send_response(status); self.send_header('Content-Type', content); self.send_header('Content-Length', str(len(body))); self.send_header('Cache-Control', 'no-store'); self.end_headers(); self.wfile.write(body)
    def setup(self):
        super().setup(); self.connection.settimeout(20)
    def throttle(self):
        # Global bound prevents unbounded per-IP dictionary allocation.
        with LOCK:
            recent = RATE['global']; now = time.time()
            while recent and recent[0] < now - 60: recent.popleft()
            if len(recent) >= 240: raise GatewayError(429, 'rate_limited')
            recent.append(now)
    def body(self, limit=1024, required=True):
        size = int(self.headers.get('Content-Length', '0'))
        if size == 0 and not required: return {}
        if not 0 < size <= limit: raise GatewayError(400, 'invalid_body_size')
        data = json.loads(self.rfile.read(size))
        if not isinstance(data, dict): raise GatewayError(400, 'invalid_request')
        return data
    def do_POST(self):
        try:
            self.throttle()
            if self.path == '/v1/devices':
                # Automatic enrollment: no secret in the app. Issues a read-only,
                # revocable device token, subject to the owner's enrollment mode and caps.
                if REGISTRY is None: raise GatewayError(404, 'device_access_not_configured')
                self.reply(201, REGISTRY.enroll(self.body())); return
            if self.path.startswith('/v1/admin/'):
                require_owner(authenticate(self.headers.get('Authorization', '')))
                self.reply(200, admin_action(self.path, 'POST', self.body(required=False))); return
            if self.path != '/pair': raise GatewayError(404, 'not_found')
            data = self.body(1023)
            self.reply(200, {'accessToken': redeem_pair_code(data.get('code', ''))})
        except GatewayError as error: self.reply(error.status, {'error':error.code})
        except (ValueError, TypeError, OSError): self.reply(400, {'error':'pairing_unavailable' if self.path == '/pair' else 'invalid_request'})

    def do_DELETE(self):
        try:
            self.throttle()
            principal = authenticate(self.headers.get('Authorization', ''))
            if self.path == '/v1/devices/self':
                # A device may always remove its own access.
                if principal['role'] != 'reader': raise GatewayError(400, 'not_a_device_credential')
                REGISTRY.set_status(principal['id'], 'removed'); self.reply(200, {'removed': True}); return
            require_owner(principal)
            self.reply(200, admin_action(self.path, 'DELETE', {}))
        except GatewayError as error: self.reply(error.status, {'error': error.code})
        except (ValueError, TypeError, OSError): self.reply(400, {'error': 'invalid_request'})

    def do_PUT(self):
        global FORECA_KEY
        try:
            self.throttle()
            # Vendor-key provisioning and administration are owner-only. Device tokens are refused.
            require_owner(authenticate(self.headers.get('Authorization', '')))
            if self.path.startswith('/v1/admin/'):
                self.reply(200, admin_action(self.path, 'PUT', self.body())); return
            if self.path != '/credentials': raise GatewayError(404, 'not_found')
            data = self.body(4096)
            key = data.get('forecaKey', '')
            if not isinstance(key, str) or len(key) < 12 or len(key) > 3000 or any(c.isspace() for c in key): raise GatewayError(400, 'invalid_key')
            with LOCK:
                if KEY_FILE:
                    temp = KEY_FILE + '.new'
                    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
                    with os.fdopen(fd, 'w', encoding='utf-8') as handle: handle.write(key)
                    os.chmod(temp, 0o600); os.replace(temp, KEY_FILE)
                FORECA_KEY = key
                CACHE.clear()
            self.reply(200, {'configured': True})
        except GatewayError as error: self.reply(error.status, {'error': error.code})
        except (ValueError, TypeError, OSError): self.reply(400, {'error': 'invalid_request'})

    def do_GET(self):
        try:
            self.throttle()
            parts = urlsplit(self.path); query = parse_qs(parts.query)
            if parts.path.startswith('/tiles/'):
                self.reply(200, tile(parts.path, query), 'image/png'); return
            principal = authenticate(self.headers.get('Authorization', ''))
            reader = principal['role'] == 'reader'
            if parts.path == '/v1/devices/self':
                self.reply(200, REGISTRY.self_status(principal['id']) if reader else {'role': 'owner', 'status': 'active'}); return
            if parts.path == '/v1/admin/devices':
                require_owner(principal)
                if REGISTRY is None: raise GatewayError(404, 'device_access_not_configured')
                self.reply(200, REGISTRY.listing()); return
            if parts.path == '/health': self.reply(200, {'configured': bool(FORECA_KEY), 'mapsEnabled': os.environ.get('FORECA_MAPS_ENABLED') == '1', 'role': principal['role'], 'status': principal['status']}); return
            if reader:
                if principal['status'] != 'active': raise GatewayError(403, 'device_pending')
                if parts.path not in ('/forecast', '/nowcast', '/maps'): raise GatewayError(404, 'not_found')
                REGISTRY.charge(principal['id'])
            lat, lon = coordinates(query)
            if DEVICE_FILE: lat, lon = round(lat, 2), round(lon, 2)  # ~1 km: shared cache entries, less precise location upstream
            if parts.path == '/forecast': data = forecast(lat, lon)
            elif parts.path == '/nowcast': data = nowcast(lat, lon)
            elif parts.path == '/maps': data = maps(lat, lon)
            else: raise GatewayError(404, 'not_found')
            self.reply(200, data)
        except GatewayError as error: self.reply(error.status, {'error': error.code})
        except (KeyError, TypeError, ValueError): self.reply(502, {'error': 'upstream_schema_changed'})
        except (BrokenPipeError, ConnectionResetError): pass
        except Exception: self.reply(500, {'error': 'gateway_internal_error'})

class BoundedServer(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, *args): super().__init__(*args); self.slots = threading.BoundedSemaphore(8)
    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False): self.shutdown_request(request); return
        try: super().process_request(request, address)
        except Exception: self.slots.release(); raise
    def process_request_thread(self, request, address):
        try: super().process_request_thread(request, address)
        finally: self.slots.release()

def devices_command(arguments):
    """Owner administration on the server itself: `server.py devices list|approve ID|revoke ID|remove ID|mode MODE`."""
    if REGISTRY is None: raise SystemExit('Set DEVICE_STATE_FILE first.')
    try:
        if arguments[:1] == ['list'] and len(arguments) == 1: pass
        elif arguments[:1] == ['mode'] and len(arguments) == 2: REGISTRY.set_mode(arguments[1])
        elif arguments[:1] in (['approve'], ['revoke'], ['remove']) and len(arguments) == 2:
            REGISTRY.set_status(arguments[1], {'approve': 'active', 'revoke': 'revoked', 'remove': 'removed'}[arguments[0]])
        else: raise SystemExit(devices_command.__doc__)
    except GatewayError as error: raise SystemExit('Failed: ' + error.code)
    listing = REGISTRY.listing()
    print(f"Enrollment: {listing['enrollment']} · up to {listing['maxDevices']} devices · {listing['dailyRequestsPerDevice']} requests per device per day")
    for row in listing['devices']:
        seen = time.strftime('%Y-%m-%d %H:%MZ', time.gmtime(row['lastSeen'])) if row['lastSeen'] else 'never'
        print(f"{row['deviceID']}  {row['status']:<8} code {row['code']}  last seen {seen}  {row['label']}")

if __name__ == '__main__':
    if sys.argv[1:2] == ['devices']: devices_command(sys.argv[2:]); raise SystemExit(0)
    if len(ACCESS_TOKEN) < 32: raise SystemExit('Set KLIERSKY_ACCESS_TOKEN to at least 32 random characters.')
    server = BoundedServer((os.environ.get('BIND', '127.0.0.1'), int(os.environ.get('PORT', '8787'))), Handler)
    cert, key = os.environ.get('TLS_CERT'), os.environ.get('TLS_KEY')
    if cert and key:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(cert, key); server.socket = context.wrap_socket(server.socket, server_side=True)
    elif os.environ.get('BIND', '127.0.0.1') != '127.0.0.1': raise SystemExit('Public binding requires TLS; otherwise use a loopback HTTPS reverse proxy.')
    print('KlierSky gateway running. Request logging disabled. Vendor credentials remain server-side.', flush=True)
    server.serve_forever()
