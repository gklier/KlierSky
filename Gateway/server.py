#!/usr/bin/env python3
"""Personal Foreca gateway. Vendor credentials never leave this process.
Run behind an HTTPS reverse proxy, or set TLS_CERT and TLS_KEY. Loopback by default.
"""
import base64
import hashlib
import hmac
import json
import math
import os
import re
import secrets
import ssl
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

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass  # Never log paths, signatures, coordinates or headers.
    def reply(self, status, data, content='application/json'):
        body = data if isinstance(data, bytes) else json.dumps(data, allow_nan=False).encode()
        self.send_response(status); self.send_header('Content-Type', content); self.send_header('Content-Length', str(len(body))); self.send_header('Cache-Control', 'no-store'); self.end_headers(); self.wfile.write(body)
    def setup(self):
        super().setup(); self.connection.settimeout(20)
    def do_POST(self):
        try:
            if self.path != '/pair': raise GatewayError(404, 'not_found')
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size < 1024: raise GatewayError(400, 'invalid_body_size')
            data = json.loads(self.rfile.read(size))
            self.reply(200, {'accessToken': redeem_pair_code(data.get('code', ''))})
        except GatewayError as error: self.reply(error.status, {'error':error.code})
        except (ValueError, TypeError, OSError): self.reply(400, {'error':'pairing_unavailable'})

    def do_PUT(self):
        global FORECA_KEY
        try:
            if not ACCESS_TOKEN or not hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + ACCESS_TOKEN): raise GatewayError(401, 'gateway_auth_required')
            if self.path != '/credentials': raise GatewayError(404, 'not_found')
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= 4096: raise GatewayError(400, 'invalid_body_size')
            data = json.loads(self.rfile.read(size))
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
        except (ValueError, TypeError): self.reply(400, {'error': 'invalid_request'})

    def do_GET(self):
        try:
            # Global bound prevents unbounded per-IP dictionary allocation.
            with LOCK:
                recent = RATE['global']; now = time.time()
                while recent and recent[0] < now - 60: recent.popleft()
                if len(recent) >= 240: raise GatewayError(429, 'rate_limited')
                recent.append(now)
            parts = urlsplit(self.path); query = parse_qs(parts.query)
            if parts.path.startswith('/tiles/'):
                self.reply(200, tile(parts.path, query), 'image/png'); return
            if not ACCESS_TOKEN or not hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + ACCESS_TOKEN): raise GatewayError(401, 'gateway_auth_required')
            if parts.path == '/health': self.reply(200, {'configured': bool(FORECA_KEY), 'mapsEnabled': os.environ.get('FORECA_MAPS_ENABLED') == '1'}); return
            lat, lon = coordinates(query)
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

if __name__ == '__main__':
    if len(ACCESS_TOKEN) < 32: raise SystemExit('Set KLIERSKY_ACCESS_TOKEN to at least 32 random characters.')
    server = BoundedServer((os.environ.get('BIND', '127.0.0.1'), int(os.environ.get('PORT', '8787'))), Handler)
    cert, key = os.environ.get('TLS_CERT'), os.environ.get('TLS_KEY')
    if cert and key:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(cert, key); server.socket = context.wrap_socket(server.socket, server_side=True)
    elif os.environ.get('BIND', '127.0.0.1') != '127.0.0.1': raise SystemExit('Public binding requires TLS; otherwise use a loopback HTTPS reverse proxy.')
    print('KlierSky gateway running. Request logging disabled. Vendor credentials remain server-side.', flush=True)
    server.serve_forever()
