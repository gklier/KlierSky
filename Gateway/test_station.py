"""Check station credential isolation and unit conversion without vendor credentials."""
import json
import stat
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch
import server
from station import StationError, StationService, normalize
from test_devices import DeviceAccess, INSTALL_A, INSTALL_B


class StationHTTP(DeviceAccess):
    def setUp(self):
        super().setUp()
        self.service = StationService(self.directory.name)
        self.station_patch = patch.object(server, 'STATIONS', self.service)
        self.station_patch.start()
        self.fetch_patch = patch.object(self.service, 'fetch', return_value={'configured': True, 'observation': {'name': 'Fixture only'}})
        self.fetch_patch.start()

    def tearDown(self):
        self.fetch_patch.stop()
        self.station_patch.stop()
        super().tearDown()

    def test_configuration_and_deletion_are_scoped_to_the_device(self):
        a = self.enroll(INSTALL_A)[1]
        b = self.enroll(INSTALL_B)[1]
        config = {'provider': 'tempest', 'stationID': '12345', 'key': 'test-only-key-not-a-real-secret'}
        status, reply = self.call('PUT', '/v1/station', a['accessToken'], config)
        self.assertEqual(status, 200)
        self.assertNotIn(config['key'], json.dumps(reply))
        path = Path(self.directory.name) / ('station-' + a['deviceID'] + '.json')
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(self.call('GET', '/v1/station', b['accessToken']), (200, {'configured': False}))
        self.assertEqual(self.call('DELETE', '/v1/station', b['accessToken'])[0], 200)
        self.assertTrue(self.call('GET', '/v1/station', a['accessToken'])[1]['configured'])
        self.assertEqual(self.call('DELETE', '/v1/station', a['accessToken']), (200, {'configured': False}))
        self.assertFalse(path.exists())

    def test_pending_and_revoked_devices_cannot_manage_stations(self):
        server.REGISTRY.set_mode('approval')
        a = self.enroll()[1]
        self.assertEqual(self.call('GET', '/v1/station', a['accessToken'])[0], 403)
        self.assertEqual(self.call('PUT', '/v1/station', a['accessToken'], {})[0], 403)
        server.REGISTRY.set_status(a['deviceID'], 'revoked')
        self.assertEqual(self.call('GET', '/v1/station', a['accessToken'])[0], 401)

    def test_failed_connection_does_not_replace_working_credentials(self):
        a = self.enroll()[1]
        config = {'provider': 'tempest', 'stationID': '12345', 'key': 'test-only-valid-format-key'}
        self.call('PUT', '/v1/station', a['accessToken'], config)
        path = Path(self.directory.name) / ('station-' + a['deviceID'] + '.json')
        before = path.read_bytes()
        self.service.fetch.side_effect = StationError(403, 'station_access_refused')
        self.assertEqual(self.call('PUT', '/v1/station', a['accessToken'], dict(config, key='replacement-test-key'))[0], 403)
        self.assertEqual(path.read_bytes(), before)


class StationNormalization(unittest.TestCase):
    def test_tempest_units_and_missing_measurements(self):
        reply = normalize('tempest', '123', {'status': {'status_code': 0}, 'obs': [{'timestamp': time.time(), 'air_temperature': 20, 'wind_avg': 1, 'relative_humidity': None}]})
        self.assertAlmostEqual(reply['observation']['temperature'], 68)
        self.assertAlmostEqual(reply['observation']['wind'], 2.2369362921)
        self.assertIsNone(reply['observation']['humidity'])
        self.assertIsNone(reply['observation']['uv'])

    def test_wunderground_units(self):
        reply = normalize('wunderground', 'KTEST', {'observations': [{'epoch': time.time(), 'imperial': {'temp': 72, 'pressure': 29.92}, 'humidity': 60}]})
        self.assertEqual(reply['observation']['temperature'], 72)
        self.assertAlmostEqual(reply['observation']['pressure'], 1013.2, places=0)

    def test_missing_and_future_timestamps_are_refused(self):
        for timestamp in (None, time.time() + 1000):
            with self.assertRaises(StationError):
                normalize('tempest', '123', {'obs': [{'timestamp': timestamp}]})
