"""Personal station connectors. Each gateway principal has its own private config."""
import json
import math
import os
import re
import tempfile
import threading
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, build_opener, HTTPRedirectHandler


class StationError(Exception):
    def __init__(self, status, code):
        self.status, self.code = status, code


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise StationError(502, 'station_redirect_refused')


def number(value, low=-100000, high=100000):
    if isinstance(value, bool) or not isinstance(value, (float, int)):
        return None
    return value if math.isfinite(value) and low <= value <= high else None


def normalize(provider, station_id, payload):
    if not isinstance(payload, dict):
        raise StationError(502, 'station_observations_missing')
    if provider == 'tempest':
        if payload.get('status', {}).get('status_code', 0) != 0:
            raise StationError(403, 'station_access_refused')
        rows = payload.get('obs') or []
        if not rows:
            raise StationError(502, 'station_observations_missing')
        row = rows[0]
        if not isinstance(row, dict):
            raise StationError(502, 'station_observations_missing')
        metric = lambda key, low=-100000, high=100000: number(row.get(key), low, high)
        temp = metric('air_temperature', -100, 70)
        wind = metric('wind_avg', 0, 150)
        result = {'provider': 'Tempest', 'stationID': station_id,
                  'name': str(payload.get('station_name') or 'My Tempest')[:120],
                  'timestamp': metric('timestamp', 0, time.time() + 300),
                  'temperature': None if temp is None else temp * 1.8 + 32,
                  'humidity': metric('relative_humidity', 0, 100),
                  'wind': None if wind is None else wind * 2.2369362921,
                  'uv': metric('uv', 0, 30),
                  'pressure': metric('sea_level_pressure', 500, 1200),
                  'latitude': number(payload.get('latitude'), -90, 90),
                  'longitude': number(payload.get('longitude'), -180, 180)}
    else:
        rows = payload.get('observations') or []
        if not rows:
            raise StationError(502, 'station_observations_missing')
        row = rows[0]
        if not isinstance(row, dict):
            raise StationError(502, 'station_observations_missing')
        imperial = row.get('imperial') or {}
        pressure = number(imperial.get('pressure'), 15, 40)
        result = {'provider': 'Weather Underground', 'stationID': station_id,
                  'name': str(row.get('neighborhood') or station_id)[:120],
                  'timestamp': number(row.get('epoch'), 0, time.time() + 300),
                  'temperature': number(imperial.get('temp'), -148, 158),
                  'humidity': number(row.get('humidity'), 0, 100),
                  'wind': number(imperial.get('windSpeed'), 0, 335),
                  'uv': number(row.get('uv'), 0, 30),
                  'pressure': None if pressure is None else pressure / 0.0295299830714,
                  'latitude': number(row.get('lat'), -90, 90),
                  'longitude': number(row.get('lon'), -180, 180)}
    if result['timestamp'] is None:
        raise StationError(502, 'station_timestamp_missing')
    return {'configured': True, 'observation': result}


class StationService:
    def __init__(self, directory):
        self.directory = Path(directory) if directory else None
        self.lock = threading.RLock()
        self.cache = {}
        self.client = build_opener(NoRedirects())

    def path(self, principal):
        identity = principal['id']
        if identity != 'owner' and not re.fullmatch(r'[0-9a-f]{16}', identity):
            raise StationError(403, 'station_access_refused')
        if self.directory is None:
            raise StationError(503, 'station_service_not_configured')
        return self.directory / ('station-' + identity + '.json')

    def fetch(self, config):
        provider, station, key = config['provider'], config['stationID'], config['key']
        if provider == 'tempest':
            url = 'https://swd.weatherflow.com/swd/rest/observations/station/' + station + '?' + urlencode({'token': key})
        else:
            url = 'https://api.weather.com/v2/pws/observations/current?' + urlencode({'stationId': station, 'format': 'json', 'units': 'e', 'numericPrecision': 'decimal', 'apiKey': key})
        try:
            with self.client.open(Request(url, headers={'User-Agent': 'KlierSky personal station access'}), timeout=12) as reply:
                raw = reply.read(1024 * 1024 + 1)
                if len(raw) > 1024 * 1024:
                    raise StationError(502, 'station_response_too_large')
                payload = json.loads(raw)
                return normalize(provider, station, payload)
        except HTTPError as error:
            raise StationError(403 if error.code in (401, 403) else 502, 'station_access_refused' if error.code in (401, 403) else 'station_unavailable') from None
        except (URLError, TimeoutError, ValueError, TypeError, KeyError, AttributeError, OSError):
            raise StationError(502, 'station_unavailable') from None

    def get(self, principal):
        with self.lock:
            path = self.path(principal)
            if not path.exists():
                return {'configured': False}
            cached = self.cache.get(principal['id'])
            if cached and time.monotonic() - cached[0] < 60:
                return cached[1]
            try:
                config = json.loads(path.read_text())
                result = self.fetch(config)
            except (OSError, ValueError):
                raise StationError(503, 'station_configuration_unavailable') from None
            self.cache[principal['id']] = (time.monotonic(), result)
            return result

    def configure(self, principal, body):
        provider = body.get('provider')
        station = body.get('stationID', '')
        key = body.get('key', '')
        if provider not in ('tempest', 'wunderground') or not isinstance(station, str) or not isinstance(key, str):
            raise StationError(400, 'invalid_station_configuration')
        pattern = r'[0-9]{1,12}' if provider == 'tempest' else r'[A-Za-z0-9_-]{3,40}'
        if not re.fullmatch(pattern, station) or not 12 <= len(key) <= 2000 or any(c.isspace() for c in key):
            raise StationError(400, 'invalid_station_configuration')
        with self.lock:
            path = self.path(principal)
            config = {'provider': provider, 'stationID': station, 'key': key}
            result = self.fetch(config)  # Verify before replacing a working connection.
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as file:
                temp = file.name
                json.dump(config, file)
            try:
                os.chmod(temp, 0o600)
                os.replace(temp, path)
            finally:
                if os.path.exists(temp):
                    os.unlink(temp)
            self.cache[principal['id']] = (time.monotonic(), result)
            return result

    def remove(self, principal):
        with self.lock:
            self.path(principal).unlink(missing_ok=True)
            self.cache.pop(principal['id'], None)
            return {'configured': False}
