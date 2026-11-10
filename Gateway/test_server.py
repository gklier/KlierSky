import copy
import sys
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).parent))
import server

class GatewayChecks(unittest.TestCase):
    def setUp(self):
        self.current = {'current': {'temperature': 50, 'feelsLikeTemp': 48, 'windSpeed': 4, 'symbol': 'n400', 'symbolPhrase': 'overcast'}}
        self.hourly = {'forecast': [{'time': '2026-11-07T03:00+00:00', 'temperature': 51, 'precipAccum': 1.2, 'precipProb': 40, 'symbol': 'n400', 'symbolPhrase': 'overcast'}]}
    def test_units_and_interval_preserved(self):
        result = server.normalize_forecast(self.current, self.hourly)
        self.assertEqual(result['source'], 'Foreca')
        self.assertEqual(result['current']['temperature_2m'], 50)
        self.assertEqual(result['current']['weather_code'], 3)
        self.assertEqual(result['hourly']['precipitation'], [1.2])
        self.assertEqual(result['hourly']['is_day'], [0])
    def test_missing_probability_not_dry(self):
        del self.hourly['forecast'][0]['precipProb']
        self.assertIsNone(server.normalize_forecast(self.current, self.hourly)['hourly']['precipitation_probability'][0])
    def test_invalid_amount_rejected(self):
        self.hourly['forecast'][0]['precipAccum'] = -1
        with self.assertRaises(server.GatewayError): server.normalize_forecast(self.current, self.hourly)
    def test_invalid_probability_rejected(self):
        self.hourly['forecast'][0]['precipProb'] = 110
        with self.assertRaises(server.GatewayError): server.normalize_forecast(self.current, self.hourly)
    def test_signatures_bound_to_frame_and_expiry(self):
        signature = server.signature('a', 100)
        self.assertNotEqual(signature, server.signature('b', 100))
        self.assertNotEqual(signature, server.signature('a', 101))
    def test_expired_tiles_rejected(self):
        with self.assertRaises(server.GatewayError): server.tile('/tiles/' + 'a'*32 + '/2/1/1.png', {'expires':['0'], 'sig':['bad']})
    def test_bad_coordinates_rejected(self):
        for value in ['nan', 'inf', '100', '-91']:
            with self.assertRaises(server.GatewayError): server.coordinates({'latitude':[value], 'longitude':['0']})
    def test_no_map_entitlement(self):
        with patch.dict(server.os.environ, {'FORECA_MAPS_ENABLED':'0'}):
            with self.assertRaises(server.GatewayError): server.maps(40,-105)
    def test_unknown_conditions_not_clear(self):
        self.current['current']['symbolPhrase'] = 'unknown'
        self.current['current']['symbol'] = 'unknown'
        self.assertEqual(server.normalize_forecast(self.current, self.hourly)['current']['weather_code'], -1)
    def test_minute_resolution_preserved(self):
        with patch.object(server, 'request_foreca', return_value={'resolution':60, 'forecast':[{'time':'2026-11-07T04:00Z','precipRate':0.1}]}):
            self.assertEqual(server.nowcast(40,-105)['resolution'], 60)
    def test_daily_ranges_and_missing_values(self):
        daily = {'forecast':[{'date':'2026-11-08','minTemp':35,'maxTemp':55,'symbol':'d200','maxTempEnsemble':{'p025':53,'p075':57}}]}
        day = server.normalize_forecast(self.current,self.hourly,daily)['dailyRows'][0]
        self.assertEqual(day['dateKey'],'2026-11-08')
        self.assertEqual(day['highP25'],53)
        self.assertIsNone(day['rain'])
        self.assertIsNone(day['chance'])
        self.assertEqual(day['code'],2)
    def test_documented_symbol_mapping(self):
        self.assertEqual(server.weather_code({'symbol':'d421'}),69)
        self.assertEqual(server.weather_code({'symbol':'n000'}),0)
        self.assertEqual(server.weather_code({'symbol':'d440'}),95)
    def test_pair_code_single_use_and_attempt_limit(self):
        import tempfile,json,time,hashlib
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'pair.json'
            def reset(): path.write_text(json.dumps({'hash':hashlib.sha256(b'12345678').hexdigest(),'expires':time.time()+60,'attempts':0,'used':False}))
            reset()
            with patch.object(server,'PAIR_FILE',str(path)), patch.object(server,'ACCESS_TOKEN','test-access-token'):
                self.assertEqual(server.redeem_pair_code('12345678'),'test-access-token')
                with self.assertRaises(server.GatewayError): server.redeem_pair_code('12345678')
                reset()
                for _ in range(5):
                    with self.assertRaises(server.GatewayError): server.redeem_pair_code('00000000')
                with self.assertRaises(server.GatewayError): server.redeem_pair_code('12345678')

if __name__ == '__main__': unittest.main()
