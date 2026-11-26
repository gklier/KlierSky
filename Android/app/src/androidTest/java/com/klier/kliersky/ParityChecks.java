package com.klier.kliersky;

import static org.junit.Assert.*;

import android.app.*;
import android.appwidget.*;
import android.content.*;
import android.graphics.*;
import android.graphics.drawable.*;
import android.os.*;
import android.view.*;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import java.time.*;
import java.util.*;
import org.json.*;
import org.junit.*;
import org.junit.runner.RunWith;

@RunWith(AndroidJUnit4.class)
public class ParityChecks {
  final Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
  final WeatherService.Place seattle =
      new WeatherService.Place("Seattle, Washington", 47.6062, -122.3321);

  JSONObject hourSource(long time, Double temperature, Double rain, int code) throws Exception {
    return new JSONObject()
        .put("timezone", "UTC")
        .put(
            "current",
            new JSONObject()
                .put("temperature_2m", temperature)
                .put("apparent_temperature", temperature)
                .put("wind_speed_10m", 5)
                .put("weather_code", code))
        .put(
            "hourly",
            new JSONObject()
                .put("time", new JSONArray().put(time))
                .put("temperature_2m", new JSONArray().put(temperature))
                .put("precipitation", new JSONArray().put(rain == null ? JSONObject.NULL : rain))
                .put("weather_code", new JSONArray().put(code)));
  }

  List<Map<String, Double>> weights(String a, String b) {
    List<Map<String, Double>> tables = new ArrayList<>();
    for (int i = 0; i < 4; i++) {
      Map<String, Double> row = new HashMap<>();
      row.put(a, 3d);
      row.put(b, 1d);
      tables.add(row);
    }
    return tables;
  }

  @Test
  public void weightedBlendMissingValuesAndConditions() throws Exception {
    long t = Instant.now().getEpochSecond() + 3600;
    JSONObject a = hourSource(t, 60d, null, -1), b = hourSource(t, 40d, 2d, 63);
    JSONObject result =
        ForecastSources.blend(
            Arrays.asList(
                new ForecastSources.Source("Foreca", a),
                new ForecastSources.Source("Open-Meteo", b)),
            weights("Foreca", "Open-Meteo"));
    assertEquals(
        55, result.getJSONObject("hourly").getJSONArray("temperature_2m").getDouble(0), .0001);
    assertEquals(
        2, result.getJSONObject("hourly").getJSONArray("precipitation").getDouble(0), .0001);
    assertTrue(result.getJSONObject("hourly").getJSONArray("uv_index").isNull(0));
    assertEquals(63, result.getJSONObject("current").getInt("weather_code"));
    double direction = ForecastSources.mean(Arrays.asList(359d, 1d), Arrays.asList(1d, 1d), true);
    assertTrue(direction < .01 || direction > 359.99);
  }

  @Test
  public void dailyForecaNormalizationActuallyBlendsDisplayedRows() throws Exception {
    JSONObject foreca =
        hourSource(Instant.now().getEpochSecond() + 3600, 60d, 0d, 0)
            .put(
                "dailyRows",
                new JSONArray()
                    .put(
                        new JSONObject()
                            .put("dateKey", "2026-11-25")
                            .put("high", 60)
                            .put("low", 40)
                            .put("chance", 20)));
    JSONObject open =
        hourSource(Instant.now().getEpochSecond() + 3600, 40d, 0d, 0)
            .put(
                "daily",
                new JSONObject()
                    .put(
                        "time",
                        new JSONArray()
                            .put(
                                LocalDate.of(2026, 11, 25)
                                    .atStartOfDay(ZoneOffset.UTC)
                                    .toEpochSecond()))
                    .put("temperature_2m_max", new JSONArray().put(40))
                    .put("temperature_2m_min", new JSONArray().put(20)));
    var sources =
        Arrays.asList(
            new ForecastSources.Source("Foreca", foreca),
            new ForecastSources.Source("Open-Meteo", open));
    ForecastSources.normalizeDays(sources);
    JSONObject result = ForecastSources.blend(sources, weights("Foreca", "Open-Meteo"));
    assertFalse(result.has("dailyRows"));
    assertEquals(
        55, result.getJSONObject("daily").getJSONArray("temperature_2m_max").getDouble(0), .001);
  }

  @Test
  public void captureOptOutAndIndependentObservationSafeguards() throws Exception {
    var prefs = context.getSharedPreferences("weather", 0);
    prefs.edit().putBoolean("verifyStations", false).apply();
    EvidenceStore evidence = new EvidenceStore(context);
    evidence.clear();
    long now = Instant.now().getEpochSecond(), target = now - 3600;
    evidence.capture(
        seattle,
        Collections.singletonList(
            new ForecastSources.Source("Foreca", hourSource(now + 3600, 50d, 0d, 0))));
    assertFalse(new LocalData(context).read("evidence").has("captures"));
    JSONObject valid =
        new JSONObject()
            .put("place", "test")
            .put("key", "test|Foreca|0")
            .put("provider", "Foreca")
            .put("target", target)
            .put("issued", target - 3600)
            .put("temperature", 50)
            .put("bucket", 0);
    JSONArray captures = new JSONArray().put(valid);
    TreeMap<Long, Double> readings = new TreeMap<>();
    readings.put(target + 300, 48d);
    JSONArray scores =
        EvidenceStore.verifyHistory(captures, new JSONArray(), "test", readings, "TEST", 10, now);
    assertEquals(1, scores.length());
    assertEquals(2, scores.getJSONObject(0).getDouble("error"), 0);
    assertEquals(
        0,
        EvidenceStore.verifyHistory(captures, scores, "test", readings, "TEST", 10, now).length());
    assertEquals(
        0,
        EvidenceStore.verifyHistory(captures, new JSONArray(), "test", readings, "TEST", 15.1, now)
            .length());
    valid.put("issued", target - 1799);
    assertEquals(
        0,
        EvidenceStore.verifyHistory(captures, new JSONArray(), "test", readings, "TEST", 10, now)
            .length());
    valid.put("issued", target - 3600);
    readings.clear();
    readings.put(target + 901, 48d);
    assertEquals(
        0,
        EvidenceStore.verifyHistory(captures, new JSONArray(), "test", readings, "TEST", 10, now)
            .length());
  }

  @Test
  public void pairedAndHeldOutGatesRejectEasyOrUnfairEvidence() throws Exception {
    long now = Instant.now().getEpochSecond();
    JSONArray samples = new JSONArray();
    List<String> sources = Arrays.asList("Foreca", "Open-Meteo");
    for (int day = 0; day < 30; day++) {
      long target = now - (29 - day) * 86400 - 3600;
      for (String source : sources)
        samples.put(
            new JSONObject()
                .put("place", "test")
                .put("provider", source)
                .put("target", target)
                .put("issued", target - 3600)
                .put("observed", target)
                .put("bucket", 0)
                .put("error", source.equals("Foreca") ? 3 : 1));
    }
    var rows = EvidenceStore.paired(samples, sources, "test", 0, now);
    assertEquals(30, rows.size());
    assertEquals("Open-Meteo", EvidenceStore.decision(rows, sources, "Foreca"));
    assertNull(EvidenceStore.decision(rows.subList(0, 20), sources, "Foreca"));
    for (int i = 0; i < samples.length(); i++)
      if (samples.getJSONObject(i).getString("provider").equals("Open-Meteo"))
        samples.getJSONObject(i).put("issued", samples.getJSONObject(i).getLong("target") - 7201);
    assertEquals(0, EvidenceStore.paired(samples, sources, "test", 0, now).size());
  }

  @Test
  public void modelTimesAreRunPinnedAndStaleRunsAreRejected() throws Exception {
    long run = Instant.parse("2026-11-25T12:00:00Z").getEpochSecond(), now = run + 7200;
    JSONObject
        first =
            new JSONObject().put("model_init_utc", Instant.ofEpochSecond(run + 3600).toString()),
        last =
            new JSONObject()
                .put("model_init_utc", Instant.ofEpochSecond(run).toString())
                .put("model_forecast_utc", Instant.ofEpochSecond(run + 64800).toString())
                .put("forecast_minute", 1080);
    var frames = RadarTimeline.future(seattle, first, last, now);
    assertFalse(frames.isEmpty());
    assertEquals(run + 64800, frames.get(frames.size() - 1).seconds());
    for (var frame : frames) {
      assertTrue(frame.forecast());
      assertTrue(frame.seconds() >= now);
      assertEquals(run, frame.issued());
      assertTrue(frame.template().contains("202611251200"));
    }
    assertTrue(
        RadarTimeline.future(new WeatherService.Place("London", 51.5, -.1), first, last, now)
            .isEmpty());
    try {
      RadarTimeline.future(seattle, first, last, run + 21601);
      fail("Stale model should be refused");
    } catch (java.io.IOException expected) {
    }
  }

  @Test
  public void notificationsPreserveHourlyOnsetAndCancelObsoletePlans() throws Exception {
    long now = Instant.now().getEpochSecond();
    JSONObject f =
        new JSONObject()
            .put("_hourlySource", "Test fixture")
            .put(
                "hourly",
                new JSONObject()
                    .put("time", new JSONArray().put(now - 600).put(now + 3000).put(now + 6600))
                    .put("precipitation", new JSONArray().put(0).put(.5).put(.6))
                    .put("precipitation_probability", new JSONArray().put(0).put(70).put(80)));
    var plan = RainNotifications.next(f, now, 15, 50);
    assertNotNull(plan);
    assertEquals(now + 3000, plan.start());
    assertEquals(now + 2100, plan.fire());
    assertEquals("Precipitation", RainNotifications.phase(f, plan.start()));
    f.getJSONObject("hourly").put("weather_code", new JSONArray().put(0).put(73).put(73));
    assertEquals("Snow", RainNotifications.phase(f, plan.start()));
    f.getJSONObject("hourly").getJSONArray("precipitation").put(0, .5);
    f.getJSONObject("hourly").getJSONArray("precipitation_probability").put(0, 70);
    assertNull(RainNotifications.next(f, now, 15, 50));
    context.getSharedPreferences("weather", 0).edit().putString("rainPending", "old").apply();
    RainNotifications.cancel(context);
    assertFalse(context.getSharedPreferences("weather", 0).contains("rainPending"));
  }

  @Test
  public void actualAdaptiveIconAndDeclaredWidgetFamilies() throws Exception {
    Drawable drawable = context.getPackageManager().getApplicationIcon(context.getPackageName());
    assertTrue(drawable instanceof AdaptiveIconDrawable);
    AdaptiveIconDrawable icon = (AdaptiveIconDrawable) drawable;
    Bitmap bitmap = Bitmap.createBitmap(108, 108, Bitmap.Config.ARGB_8888);
    icon.setBounds(0, 0, 108, 108);
    icon.draw(new Canvas(bitmap));
    assertTrue(Color.alpha(bitmap.getPixel(54, 4)) > 240);
    assertTrue(Color.red(bitmap.getPixel(54, 54)) > 200);
    AppWidgetManager manager = AppWidgetManager.getInstance(context);
    Set<String> installed = new HashSet<>();
    for (var provider : manager.getInstalledProviders())
      if (provider.provider.getPackageName().equals(context.getPackageName()))
        installed.add(provider.provider.getClassName());
    for (Class<?> type : WeatherWidgets.types()) assertTrue(installed.contains(type.getName()));
  }

  @Test
  public void liveFreeForecastAndRealModelMetadata() throws Exception {
    context
        .getSharedPreferences("weather", 0)
        .edit()
        .putString("forecastMode", "blend")
        .putBoolean("verifyStations", false)
        .apply();
    WeatherService service = new WeatherService(context);
    long start = SystemClock.elapsedRealtime();
    var loaded = service.load(seattle, false, false);
    assertFalse(loaded.forecast().optBoolean("_cached"));
    assertNotNull(loaded.forecast().optJSONObject("hourly"));
    JSONArray members = loaded.forecast().getJSONArray("_members");
    assertTrue("At least two live free sources should answer", members.length() >= 2);
    assertTrue(SystemClock.elapsedRealtime() - start < 35000);
    List<String> names = new ArrayList<>();
    for (int i = 0; i < members.length(); i++)
      names.add(members.getJSONObject(i).getString("name"));
    android.util.Log.i("KlierSkyChecks", "Live sources: " + String.join(", ", names));
    var frames = RadarTimeline.future(seattle);
    assertTrue("A current run should provide genuine future frames", frames.size() > 0);
    long ahead = frames.get(frames.size() - 1).seconds() - Instant.now().getEpochSecond();
    assertTrue(ahead > 0 && ahead <= 18 * 3600);
    android.util.Log.i("KlierSkyChecks", "Live model look-ahead minutes: " + ahead / 60);
  }
}
