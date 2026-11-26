package com.klier.kliersky;

import static org.junit.Assert.*;

import android.content.Context;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import java.io.*;
import java.nio.charset.StandardCharsets;
import org.json.*;
import org.junit.*;
import org.junit.runner.RunWith;

/** Real gateway checks use one temporary read-only emulator device, never the owner's secret. */
@RunWith(AndroidJUnit4.class)
public class GatewayAcceptanceChecks {
  final Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();

  @Test
  public void reportDeviceMetadata() throws Exception {
    WeatherService service = new WeatherService(context);
    JSONObject record = service.access(true);
    JSONObject status =
        WeatherService.request(
            BuildConfig.GATEWAY_URL + "/v1/devices/self",
            "GET",
            record.getString("accessToken"),
            null);
    JSONObject metadata =
        new JSONObject()
            .put("deviceID", status.getString("deviceID"))
            .put("code", status.optString("code"))
            .put("status", status.getString("status"));
    File path = new File(context.getExternalFilesDir(null), "qa-device-metadata.json");
    try (FileOutputStream output = new FileOutputStream(path)) {
      output.write(metadata.toString().getBytes(StandardCharsets.UTF_8));
    }
    assertTrue(metadata.getString("deviceID").matches("[0-9a-f]{16}"));
  }

  @Test
  public void forecaAndStationAccessAreReadonly() throws Exception {
    WeatherService service = new WeatherService(context);
    JSONObject status = service.gateway("v1/devices/self", "GET", null);
    assertEquals("active", status.getString("status"));
    assertEquals("reader", status.getString("role"));
    JSONObject forecast = service.gateway("forecast?latitude=47.61&longitude=-122.33", "GET", null);
    assertEquals("Foreca", forecast.getString("source"));
    assertTrue(
        Double.isFinite(
            ForecastSources.number(forecast.getJSONObject("current"), "temperature_2m")));
    assertTrue(forecast.getJSONObject("hourly").getJSONArray("time").length() >= 12);
    assertTrue(forecast.getJSONArray("dailyRows").length() > 0);
    JSONObject station = service.gateway("v1/station", "GET", null);
    assertTrue(station.has("configured"));
    try {
      service.gateway("v1/admin/devices", "GET", null);
      fail("A reader must not gain owner access");
    } catch (java.io.IOException expected) {
      assertTrue(expected.getMessage().contains("403"));
    }
    var prefs = context.getSharedPreferences("weather", 0);
    prefs.edit().putString("forecastMode", "blend").putBoolean("verifyStations", false).apply();
    var live =
        service.load(
            new WeatherService.Place("Seattle, Washington", 47.6062, -122.3321), true, false);
    boolean used = false;
    JSONArray members = live.forecast().getJSONArray("_members");
    for (int i = 0; i < members.length(); i++)
      if (members.getJSONObject(i).getString("name").equals("Foreca")) used = true;
    assertTrue("A configured reachable Foreca account must participate", used);
    android.util.Log.i(
        "KlierSkyChecks",
        "Foreca reader, daily forecast, station contract and owner-operation refusal verified");
  }

  @Test
  public void encryptedOwnerStorageIsSeparateFromDeviceAccess() throws Exception {
    Context isolated = context.createDeviceProtectedStorageContext();
    Credentials owner = new Credentials(isolated, true);
    String fixture = "test-only-owner-credential-not-a-real-token";
    try {
      owner.save(fixture);
      assertEquals(fixture, owner.read());
      String encrypted =
          isolated.getSharedPreferences("private-owner-access", 0).getString("record", "");
      assertFalse(encrypted.contains(fixture));
      assertTrue(encrypted.contains(":"));
    } finally {
      owner.clear();
    }
  }

  @Test
  public void removeTemporaryGatewayAccess() throws Exception {
    WeatherService service = new WeatherService(context);
    service.gateway("v1/devices/self", "DELETE", null);
    service.credentials.clear();
    new File(context.getExternalFilesDir(null), "qa-device-metadata.json").delete();
  }
}
