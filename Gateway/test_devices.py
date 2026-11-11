"""Acceptance checks for automatic per-device access.

Each test talks HTTP to a real gateway instance on loopback with a temporary
state directory. Upstream Foreca calls are replaced by synthetic schema fixtures
that exist only in this file; they are never shown to an app as weather.
"""
import json
import os
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

sys.path.insert(0, str(Path(__file__).parent))
import server

OWNER = 'owner-token-for-tests-0123456789abcdef'
VENDOR = 'vendor-key-must-never-leave-the-server'
INSTALL_A = 'A' * 32
INSTALL_B = 'B' * 32

def fake_foreca(path, query=None, binary=False, ttl=0):
    server.UPSTREAM_CALLS.append(path)
    if '/current/' in path: return {'current': {'time': '2026-11-07T03:00+00:00', 'temperature': 50, 'feelsLikeTemp': 48, 'windSpeed': 4, 'symbol': 'n400', 'symbolPhrase': 'overcast'}}
    if '/hourly/' in path: return {'forecast': [{'time': '2026-11-07T03:00+00:00', 'temperature': 51, 'precipAccum': 0, 'precipProb': 10, 'symbol': 'n400', 'symbolPhrase': 'overcast'}]}
    if '/daily/' in path: return {'forecast': []}
    return {'timezone': 'America/Denver'}

class DeviceAccess(unittest.TestCase):
    mode = 'open'
    limits = {}

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.state = os.path.join(self.directory.name, 'devices.json')
        server.UPSTREAM_CALLS = []
        settings = dict(ACCESS_TOKEN=OWNER, FORECA_KEY=VENDOR, DEVICE_FILE=self.state, ENROLLMENT_DEFAULT=self.mode, KEY_FILE='',
                        MAX_DEVICES=3, ENROLL_PER_HOUR=50, ENROLL_PER_DAY=100, DEVICE_DAILY_REQUESTS=400, DEVICE_PER_MINUTE=100, UPSTREAM_DAILY_BUDGET=0)
        settings.update(self.limits)
        self.patches = [patch.object(server, name, value) for name, value in settings.items()]
        self.patches.append(patch.object(server, 'request_foreca', fake_foreca))
        for item in self.patches: item.start()
        self.patches.append(patch.object(server, 'REGISTRY', server.Registry(self.state))); self.patches[-1].start()
        server.RATE.clear(); server.CACHE.clear(); server.BUDGET.update(day='', count=0)
        self.httpd = server.BoundedServer(('127.0.0.1', 0), server.Handler)
        self.base = 'http://127.0.0.1:%d' % self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown(); self.httpd.server_close()
        for item in reversed(self.patches): item.stop()
        self.directory.cleanup()

    def call(self, method, path, token=None, body=None):
        request = Request(self.base + path, method=method, data=None if body is None else json.dumps(body).encode())
        if body is not None: request.add_header('Content-Type', 'application/json')
        if token: request.add_header('Authorization', 'Bearer ' + token)
        try:
            with urlopen(request, timeout=5) as response: return response.status, json.loads(response.read())
        except HTTPError as error:
            with error: return error.code, json.loads(error.read())

    def enroll(self, install=INSTALL_A, label='iPhone 0.4.0'):
        return self.call('POST', '/v1/devices', body={'installID': install, 'label': label})

    def forecast(self, token):
        return self.call('GET', '/forecast?latitude=39.74&longitude=-104.99', token)

class FreshInstall(DeviceAccess):
    def test_fresh_install_gets_working_read_only_access_without_any_secret(self):
        status, device = self.enroll()
        self.assertEqual(status, 201)
        self.assertEqual((device['status'], device['role']), ('active', 'reader'))
        self.assertTrue(device['accessToken'].startswith('ksd_') and device['accessToken'] != OWNER)
        status, data = self.forecast(device['accessToken'])
        self.assertEqual((status, data['source']), (200, 'Foreca'))
        self.assertEqual(self.call('GET', '/v1/devices/self', device['accessToken'])[1]['status'], 'active')

    def test_device_token_cannot_manage_credentials_or_devices(self):
        token = self.enroll()[1]['accessToken']
        self.assertEqual(self.call('PUT', '/credentials', token, {'forecaKey': 'attacker-supplied-key-123'}), (403, {'error': 'owner_required'}))
        self.assertEqual(server.FORECA_KEY, VENDOR)
        self.assertEqual(self.call('GET', '/v1/admin/devices', token)[0], 403)
        self.assertEqual(self.call('PUT', '/v1/admin/enrollment', token, {'mode': 'open'})[0], 403)
        other = self.enroll(INSTALL_B)[1]['deviceID']
        self.assertEqual(self.call('POST', f'/v1/admin/devices/{other}/revoke', token)[0], 403)
        self.assertEqual(self.call('DELETE', f'/v1/admin/devices/{other}', token)[0], 403)

    def test_no_secret_is_stored_or_returned_in_clear(self):
        status, device = self.enroll()
        saved = Path(self.state).read_text()
        self.assertNotIn(device['accessToken'], saved)
        self.assertNotIn(INSTALL_A, saved)
        self.assertNotIn(OWNER, saved)
        self.assertEqual(stat.S_IMODE(os.stat(self.state).st_mode), 0o600)
        everything = json.dumps([device, self.forecast(device['accessToken']), self.call('GET', '/health', device['accessToken']), self.call('GET', '/v1/admin/devices', OWNER)])
        self.assertNotIn(VENDOR, everything)
        self.assertNotIn(OWNER, everything)
        self.assertNotIn('tokenHash', everything)

    def test_unauthenticated_and_unknown_tokens_are_refused(self):
        self.assertEqual(self.forecast(None)[0], 401)
        self.assertEqual(self.forecast('ksd_' + 'x' * 43)[0], 401)
        self.assertEqual(self.call('GET', '/health')[0], 401)
        self.assertEqual(self.call('GET', '/v1/devices/self')[0], 401)

    def test_malformed_enrollment_is_rejected(self):
        self.assertEqual(self.call('POST', '/v1/devices', body={'installID': 'short'})[0], 400)
        self.assertEqual(self.call('POST', '/v1/devices', body={'installID': 'a b' * 12})[0], 400)
        self.assertEqual(self.call('POST', '/v1/devices', body={'installID': INSTALL_A, 'label': 5})[0], 400)
        self.assertEqual(self.call('POST', '/v1/devices', body={'installID': INSTALL_A, 'label': 'x' * 2000})[0], 400)
        status, device = self.call('POST', '/v1/devices', body={'installID': INSTALL_A, 'label': '<script>alert(1)</script>'})
        listed = self.call('GET', '/v1/admin/devices', OWNER)[1]['devices'][0]['label']
        self.assertNotIn('<', listed)

class UpdateFromOwnerToken(DeviceAccess):
    def test_existing_owner_token_keeps_working_after_migration(self):
        self.assertEqual(self.forecast(OWNER)[0], 200)
        self.assertEqual(self.call('GET', '/health', OWNER)[1]['role'], 'owner')
        self.assertEqual(self.call('PUT', '/credentials', OWNER, {'forecaKey': 'rotated-vendor-key-123456'})[0], 200)
        self.assertEqual(server.FORECA_KEY, 'rotated-vendor-key-123456')

    def test_unmigrated_server_behaves_as_before(self):
        with patch.object(server, 'REGISTRY', None), patch.object(server, 'DEVICE_FILE', ''):
            self.assertEqual(self.enroll(), (404, {'error': 'device_access_not_configured'}))
            self.assertEqual(self.forecast(OWNER)[0], 200)
            self.assertEqual(self.forecast('ksd_' + 'x' * 43)[0], 401)
            self.assertEqual(self.call('GET', '/v1/admin/devices', OWNER)[0], 404)

class Reinstall(DeviceAccess):
    def test_reinstall_with_surviving_keychain_reuses_the_same_access(self):
        token = self.enroll()[1]['accessToken']
        self.assertEqual(self.forecast(token)[0], 200)
        self.assertEqual(self.forecast(token)[0], 200)  # same credential after reinstall: no new enrollment needed
        self.assertEqual(len(self.call('GET', '/v1/admin/devices', OWNER)[1]['devices']), 1)

    def test_retry_with_same_install_rotates_token_without_using_a_slot(self):
        first = self.enroll()[1]
        second = self.enroll()[1]
        self.assertEqual(first['deviceID'], second['deviceID'])
        self.assertNotEqual(first['accessToken'], second['accessToken'])
        self.assertEqual(self.forecast(first['accessToken'])[0], 401)
        self.assertEqual(self.forecast(second['accessToken'])[0], 200)
        self.assertEqual(len(self.call('GET', '/v1/admin/devices', OWNER)[1]['devices']), 1)

    def test_reinstall_without_keychain_enrolls_again_within_the_device_cap(self):
        tokens = [self.enroll(install)[1]['accessToken'] for install in (INSTALL_A, INSTALL_B, 'C' * 32)]
        self.assertTrue(all(self.forecast(token)[0] == 200 for token in tokens))
        self.assertEqual(self.enroll('D' * 32), (403, {'error': 'device_limit_reached'}))

    def test_idle_devices_release_their_slot(self):
        for install in (INSTALL_A, INSTALL_B, 'C' * 32): self.enroll(install)
        state = json.loads(Path(self.state).read_text())
        oldest = sorted(state['devices'])[0]
        state['devices'][oldest]['created'] = int(time.time()) - 61 * 86400
        Path(self.state).write_text(json.dumps(state)); os.chmod(self.state, 0o600)
        self.assertEqual(self.enroll('D' * 32)[0], 201)
        self.assertNotIn(oldest, [row['deviceID'] for row in self.call('GET', '/v1/admin/devices', OWNER)[1]['devices']])

    def test_device_can_remove_itself(self):
        token = self.enroll()[1]['accessToken']
        self.assertEqual(self.call('DELETE', '/v1/devices/self', token)[0], 200)
        self.assertEqual(self.forecast(token)[0], 401)
        self.assertEqual(self.call('GET', '/v1/admin/devices', OWNER)[1]['devices'], [])

class Revocation(DeviceAccess):
    def test_revoked_device_loses_access_and_cannot_silently_return(self):
        a, b = self.enroll(INSTALL_A)[1], self.enroll(INSTALL_B)[1]
        self.assertEqual(self.call('POST', f"/v1/admin/devices/{a['deviceID']}/revoke", OWNER)[0], 200)
        self.assertEqual(self.forecast(a['accessToken']), (401, {'error': 'device_revoked'}))
        self.assertEqual(self.call('GET', '/v1/devices/self', a['accessToken']), (401, {'error': 'device_revoked'}))
        self.assertEqual(self.enroll(INSTALL_A), (403, {'error': 'device_revoked'}))
        self.assertEqual(self.forecast(b['accessToken'])[0], 200)
        self.assertEqual(self.forecast(OWNER)[0], 200)

    def test_revoked_devices_do_not_consume_slots(self):
        a = self.enroll(INSTALL_A)[1]; self.enroll(INSTALL_B); self.enroll('C' * 32)
        self.call('POST', f"/v1/admin/devices/{a['deviceID']}/revoke", OWNER)
        self.assertEqual(self.enroll('D' * 32)[0], 201)

    def test_server_command_revokes_while_the_gateway_is_running(self):
        device = self.enroll()[1]
        self.assertEqual(self.forecast(device['accessToken'])[0], 200)
        environment = dict(os.environ, DEVICE_STATE_FILE=self.state)
        time.sleep(0.01)
        result = subprocess.run([sys.executable, str(Path(server.__file__)), 'devices', 'revoke', device['deviceID']], env=environment, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('revoked', result.stdout)
        self.assertNotIn(device['accessToken'], result.stdout)
        self.assertEqual(self.forecast(device['accessToken']), (401, {'error': 'device_revoked'}))

    def test_closing_enrollment_blocks_new_devices_but_keeps_existing_ones(self):
        token = self.enroll()[1]['accessToken']
        self.assertEqual(self.call('PUT', '/v1/admin/enrollment', OWNER, {'mode': 'closed'})[1]['enrollment'], 'closed')
        self.assertEqual(self.enroll(INSTALL_B), (403, {'error': 'enrollment_closed'}))
        self.assertEqual(self.forecast(token)[0], 200)
        self.assertEqual(self.call('PUT', '/v1/admin/enrollment', OWNER, {'mode': 'everyone'})[0], 400)

class ApprovalMode(DeviceAccess):
    mode = 'approval'
    def test_new_device_waits_for_owner_approval(self):
        device = self.enroll()[1]
        self.assertEqual(device['status'], 'pending')
        self.assertEqual(self.forecast(device['accessToken']), (403, {'error': 'device_pending'}))
        self.assertEqual(server.UPSTREAM_CALLS, [])
        listed = self.call('GET', '/v1/admin/devices', OWNER)[1]['devices'][0]
        self.assertEqual((listed['status'], listed['code']), ('pending', device['code']))
        self.assertEqual(self.call('POST', f"/v1/admin/devices/{device['deviceID']}/approve", OWNER)[0], 200)
        self.assertEqual(self.call('GET', '/v1/devices/self', device['accessToken'])[1]['status'], 'active')
        self.assertEqual(self.forecast(device['accessToken'])[0], 200)

    def test_unapproved_requests_cannot_use_up_device_slots(self):
        # Strangers can fill the waiting list (3 here), never the approved slots.
        waiting = [self.enroll(c * 32)[1] for c in 'ABC']
        self.assertEqual(self.enroll('D' * 32), (403, {'error': 'device_limit_reached'}))
        self.assertTrue(all(self.forecast(d['accessToken']) == (403, {'error': 'device_pending'}) for d in waiting))
        # The owner clears the list and opens enrollment: every approved slot is still free.
        for d in waiting: self.assertEqual(self.call('DELETE', f"/v1/admin/devices/{d['deviceID']}", OWNER)[0], 200)
        family = self.enroll('E' * 32)[1]
        self.assertEqual(self.call('POST', f"/v1/admin/devices/{family['deviceID']}/approve", OWNER)[0], 200)
        self.assertEqual(self.forecast(family['accessToken'])[0], 200)

    def test_waiting_requests_do_not_block_open_enrollment_or_approved_devices(self):
        for c in 'ABC': self.enroll(c * 32)
        self.call('PUT', '/v1/admin/enrollment', OWNER, {'mode': 'open'})
        tokens = [self.enroll(c * 32)[1] for c in 'EFG']
        self.assertTrue(all(d['status'] == 'active' and self.forecast(d['accessToken'])[0] == 200 for d in tokens))
        self.assertEqual(self.enroll('H' * 32), (403, {'error': 'device_limit_reached'}))

    def test_approval_cannot_exceed_the_device_limit(self):
        self.call('PUT', '/v1/admin/enrollment', OWNER, {'mode': 'open'})
        for c in 'ABC': self.enroll(c * 32)
        self.call('PUT', '/v1/admin/enrollment', OWNER, {'mode': 'approval'})
        extra = self.enroll('D' * 32)[1]
        self.assertEqual(self.call('POST', f"/v1/admin/devices/{extra['deviceID']}/approve", OWNER), (409, {'error': 'device_limit_reached'}))
        self.assertEqual(self.forecast(extra['accessToken']), (403, {'error': 'device_pending'}))

    def test_unapproved_requests_expire(self):
        device = self.enroll()[1]
        self.call('GET', '/v1/devices/self', device['accessToken'])     # polling must not keep the request alive
        state = json.loads(Path(self.state).read_text())
        state['devices'][device['deviceID']]['created'] = int(time.time()) - 8 * 86400
        Path(self.state).write_text(json.dumps(state)); os.chmod(self.state, 0o600)
        self.assertEqual(self.enroll(INSTALL_B)[0], 201)
        self.assertEqual(self.call('GET', '/v1/devices/self', device['accessToken'])[0], 401)
        # The same install simply asks again and gets a fresh request.
        self.assertEqual(self.enroll(INSTALL_A)[1]['status'], 'pending')

class ClosedByDefault(DeviceAccess):
    mode = 'closed'
    def test_enrollment_is_refused_until_the_owner_opens_it(self):
        self.assertEqual(self.enroll(), (403, {'error': 'enrollment_closed'}))

class CostControls(DeviceAccess):
    limits = dict(ENROLL_PER_HOUR=2, DEVICE_DAILY_REQUESTS=3, UPSTREAM_DAILY_BUDGET=8)
    def test_enrollment_rate_limit(self):
        self.assertEqual(self.enroll(INSTALL_A)[0], 201)
        self.assertEqual(self.enroll(INSTALL_B)[0], 201)
        self.assertEqual(self.enroll('C' * 32), (429, {'error': 'enrollment_rate_limited'}))

    def test_device_daily_quota(self):
        token = self.enroll()[1]['accessToken']
        for _ in range(3): self.assertEqual(self.forecast(token)[0], 200)
        self.assertEqual(self.forecast(token), (429, {'error': 'device_quota_exceeded'}))
        self.assertEqual(self.call('GET', '/v1/devices/self', token)[1]['usedToday'], 3)
        self.assertEqual(self.forecast(OWNER)[0], 200)

    def test_device_per_minute_limit(self):
        token = self.enroll()[1]['accessToken']
        with patch.object(server, 'DEVICE_PER_MINUTE', 2):
            self.assertEqual(self.forecast(token)[0], 200); self.assertEqual(self.forecast(token)[0], 200)
            self.assertEqual(self.forecast(token), (429, {'error': 'device_rate_limited'}))

    def test_coordinates_are_coarsened_before_reaching_the_vendor(self):
        token = self.enroll()[1]['accessToken']
        self.assertEqual(self.call('GET', '/forecast?latitude=39.739236&longitude=-104.990251', token)[0], 200)
        self.assertTrue(server.UPSTREAM_CALLS and all(path.endswith('-104.99,39.74') for path in server.UPSTREAM_CALLS), server.UPSTREAM_CALLS)

class UpstreamBudget(unittest.TestCase):
    def test_vendor_call_budget_stops_real_requests_only(self):
        class Reply:
            def __enter__(self): return self
            def __exit__(self, *_): return False
            def read(self, _): return b'{}'
        with patch.object(server, 'FORECA_KEY', VENDOR), patch.object(server, 'UPSTREAM_DAILY_BUDGET', 2), patch.object(server.UPSTREAM_CLIENT, 'open', return_value=Reply()) as opened:
            server.CACHE.clear(); server.BUDGET.update(day='', count=0)
            server.request_foreca('/a', ttl=300); server.request_foreca('/a', ttl=300); server.request_foreca('/b')
            with self.assertRaises(server.GatewayError) as raised: server.request_foreca('/c')
            self.assertEqual((raised.exception.status, raised.exception.code), (429, 'upstream_budget_exhausted'))
            self.assertEqual(opened.call_count, 2)
            server.CACHE.clear(); server.BUDGET.update(day='', count=0)

if __name__ == '__main__':
    unittest.main()
