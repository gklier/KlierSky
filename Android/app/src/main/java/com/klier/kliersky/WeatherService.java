package com.klier.kliersky;

import java.io.ByteArrayOutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

final class WeatherService {
  record Place(String name, double latitude, double longitude) {
    JSONObject json() throws Exception {
      return new JSONObject()
          .put("name", name)
          .put("latitude", latitude)
          .put("longitude", longitude);
    }

    static Place parse(JSONObject value) throws Exception {
      return new Place(
          value.getString("name"), value.getDouble("latitude"), value.getDouble("longitude"));
    }
  }

  record RadarFrame(long seconds, String template, String kind, long issued) {
    RadarFrame(long seconds, String template) {
      this(seconds, template, "observed", 0);
    }

    boolean forecast() {
      return kind.equals("forecast");
    }
  }

  record Result(JSONObject forecast, String source, List<RadarFrame> radar, String accessMessage) {}

  final Credentials credentials;
  final Credentials owner;
  final LocalData files;
  final EvidenceStore evidence;
  final android.content.SharedPreferences preferences;

  WeatherService(android.content.Context context) {
    credentials = new Credentials(context);
    owner = new Credentials(context, true);
    files = new LocalData(context);
    evidence = new EvidenceStore(context);
    preferences = context.getSharedPreferences("weather", android.content.Context.MODE_PRIVATE);
  }

  static String encode(String value) {
    try {
      return URLEncoder.encode(value, "UTF-8");
    } catch (java.io.UnsupportedEncodingException impossible) {
      throw new IllegalStateException(impossible);
    }
  }

  static JSONObject request(String address, String method, String token, JSONObject body)
      throws Exception {
    HttpURLConnection connection = (HttpURLConnection) new URL(address).openConnection();
    connection.setConnectTimeout(12000);
    connection.setReadTimeout(18000);
    connection.setInstanceFollowRedirects(false);
    connection.setRequestMethod(method);
    connection.setRequestProperty(
        "User-Agent",
        "KlierSky-Android/" + BuildConfig.VERSION_NAME + " (https://github.com/gklier/KlierSky)");
    if (token != null && !token.isEmpty())
      connection.setRequestProperty("Authorization", "Bearer " + token);
    try {
      if (body != null) {
        connection.setDoOutput(true);
        connection.setRequestProperty("Content-Type", "application/json");
        try (var output = connection.getOutputStream()) {
          output.write(body.toString().getBytes(StandardCharsets.UTF_8));
        }
      }
      int status = connection.getResponseCode();
      if (status != 200 && status != 201) throw new java.io.IOException("HTTP " + status);
      try (var input = connection.getInputStream();
          var output = new ByteArrayOutputStream()) {
        byte[] buffer = new byte[8192];
        int count;
        while ((count = input.read(buffer)) != -1) {
          if (output.size() + count > 4 * 1024 * 1024)
            throw new java.io.IOException("Response too large");
          output.write(buffer, 0, count);
        }
        return new JSONObject(output.toString("UTF-8"));
      }
    } finally {
      connection.disconnect();
    }
  }

  synchronized JSONObject access(boolean enroll) throws Exception {
    if (!owner.read().isEmpty())
      return new JSONObject().put("accessToken", owner.read()).put("role", "owner");
    String saved = credentials.read();
    if (!saved.isEmpty()) return new JSONObject(saved);
    if (!enroll) throw new java.io.IOException("No saved service access");
    String install = preferences.getString("installID", "");
    if (install.isEmpty()) {
      install = java.util.UUID.randomUUID().toString().replace("-", "");
      if (!preferences.edit().putString("installID", install).commit())
        throw new java.io.IOException("Storage unavailable");
    }
    JSONObject record =
        request(
            BuildConfig.GATEWAY_URL + "/v1/devices",
            "POST",
            null,
            new JSONObject()
                .put("installID", install)
                .put("label", "Android KlierSky " + BuildConfig.VERSION_NAME));
    credentials.save(record.toString());
    return record;
  }

  String token(boolean enroll) throws Exception {
    return access(enroll).getString("accessToken");
  }

  JSONObject gateway(String path, String method, JSONObject body) throws Exception {
    return request(BuildConfig.GATEWAY_URL + "/" + path, method, token(true), body);
  }

  void pairOwner(String code) throws Exception {
    JSONObject reply =
        request(
            BuildConfig.GATEWAY_URL + "/pair", "POST", null, new JSONObject().put("code", code));
    owner.save(reply.getString("accessToken"));
    files.log("Owner paired");
  }

  Result load(Place place) throws Exception {
    return load(place, true, true);
  }

  private record ForecaReply(ForecastSources.Source source, String message) {}

  private ForecaReply foreca(Place place, boolean enrollment) {
    try {
      JSONObject record = access(enrollment);
      String bearer = record.getString("accessToken");
      JSONObject status =
          request(BuildConfig.GATEWAY_URL + "/v1/devices/self", "GET", bearer, null);
      if (!status.optString("status").equals("active"))
        return new ForecaReply(
            null, "Waiting for owner approval. Device code " + record.optString("code", "—") + ".");
      return new ForecaReply(
          new ForecastSources.Source(
              "Foreca",
              request(
                  BuildConfig.GATEWAY_URL + "/forecast?" + ForecastSources.point(place),
                  "GET",
                  bearer,
                  null)),
          "");
    } catch (Exception ignored) {
      return new ForecaReply(null, "Foreca unavailable. Other sources are labeled below.");
    }
  }

  private static <T> T await(java.util.concurrent.Future<T> task, long deadline, int maximumSeconds)
      throws Exception {
    long millis =
        Math.min(maximumSeconds * 1000L, deadline - android.os.SystemClock.elapsedRealtime());
    if (millis <= 0 && !task.isDone()) throw new java.util.concurrent.TimeoutException();
    return task.get(Math.max(1, millis), java.util.concurrent.TimeUnit.MILLISECONDS);
  }

  Result load(Place place, boolean maps, boolean enrollment) throws Exception {
    String cache = "forecast-" + LocalData.placeKey(place);
    JSONObject prior = files.read(cache).optJSONObject("forecast");
    if (!maps
        && !enrollment
        && prior != null
        && java.time.Instant.now().getEpochSecond() - prior.optLong("_updated") < 900)
      return new Result(
          prior, files.read(cache).optString("source", "Forecast"), new ArrayList<>(), "");
    long deadline = android.os.SystemClock.elapsedRealtime() + 25000;
    java.util.concurrent.ExecutorService pool =
        java.util.concurrent.Executors.newFixedThreadPool(7);
    var open =
        pool.submit(() -> new ForecastSources.Source("Open-Meteo", ForecastSources.open(place)));
    boolean blending = preferences.getString("forecastMode", "blend").equals("blend");
    var free =
        pool.submit(
            () ->
                blending
                        || preferences.getBoolean("verifyStations", false)
                        || preferences.getBoolean("showComparison", false)
                    ? ForecastSources.free(place)
                    : new ArrayList<ForecastSources.Source>());
    var remote = pool.submit(() -> foreca(place, enrollment));
    var radar =
        pool.submit(
            () -> {
              List<RadarFrame> frames = new ArrayList<>();
              if (maps) {
                try {
                  frames.addAll(RadarTimeline.observed());
                } catch (Exception ignored) {
                }
                if (preferences.getBoolean("modelFuturecast", true))
                  try {
                    frames.addAll(RadarTimeline.future(place));
                  } catch (Exception ignored) {
                  }
              }
              return frames;
            });
    var station =
        pool.submit(
            () ->
                maps || enrollment
                    ? request(
                        BuildConfig.GATEWAY_URL + "/v1/station", "GET", token(enrollment), null)
                    : prior == null ? null : prior.optJSONObject("_station"));
    var alerts =
        pool.submit(
            () -> {
              if (!maps && !enrollment) return new JSONObject().put("_alertsUnavailable", true);
              if (!WeatherAlerts.covers(place)) return new JSONObject().put("_alertsOutside", true);
              ForecastSources.nwsPoint(place);
              JSONObject reply =
                  ForecastSources.get(
                      "https://api.weather.gov/alerts/active?status=actual&point="
                          + place.latitude()
                          + ","
                          + place.longitude());
              return new JSONObject()
                  .put("_alerts", reply.optJSONArray("features"))
                  .put("_alertsChecked", java.time.Instant.now().getEpochSecond());
            });
    var air =
        pool.submit(
            () ->
                maps || enrollment
                    ? ForecastSources.get(
                            "https://air-quality-api.open-meteo.com/v1/air-quality?"
                                + ForecastSources.point(place)
                                + "&current=us_aqi&timeformat=unixtime")
                        .optJSONObject("current")
                    : prior == null ? null : prior.optJSONObject("_airQuality"));
    try {
      List<ForecastSources.Source> sources = new ArrayList<>();
      String message = "Foreca unavailable. Other sources are labeled below.";
      try {
        ForecaReply reply = await(remote, deadline, 15);
        if (reply.source() != null) sources.add(reply.source());
        message = reply.message();
      } catch (Exception ignored) {
        files.log("Access unavailable");
      }
      try {
        sources.add(await(open, deadline, 15));
      } catch (Exception ignored) {
        files.log("Provider unavailable");
      }
      try {
        sources.addAll(await(free, deadline, 10));
      } catch (Exception ignored) {
      }
      if (sources.isEmpty()) throw new java.io.IOException("No live forecast available");
      try {
        evidence.capture(place, sources);
        evidence.verifyLater(place);
      } catch (Exception ignored) {
      }
      ForecastSources.normalizeDays(sources);
      String preferred = preferences.getString("preferredProvider", "Foreca");
      ForecastSources.Source baseline =
          sources.stream()
              .filter(v -> v.name().equals(preferred))
              .findFirst()
              .orElse(sources.get(0));
      JSONObject forecast;
      String source;
      if (blending && sources.size() > 1) {
        forecast = ForecastSources.blend(sources, evidence.weights(place, sources));
        source =
            forecast.optString("_hourlySource")
                + (preferences.getBoolean("weightsMeasured", false)
                    ? " · evidence-adjusted weights"
                    : " · starting weights");
      } else {
        forecast = new JSONObject(baseline.data().toString());
        source = baseline.name();
        forecast
            .put("_currentSource", source)
            .put("_hourlySource", source)
            .put("_dailySource", source);
        if (preferences.getBoolean("adaptiveEnabled", false))
          applyTemperatureSelection(forecast, baseline, sources, place);
      }
      JSONArray members = new JSONArray();
      for (var member : sources)
        members.put(new JSONObject().put("name", member.name()).put("forecast", member.data()));
      forecast
          .put("_members", members)
          .put("_updated", java.time.Instant.now().getEpochSecond())
          .put("_cached", false);
      try {
        JSONObject value = await(station, deadline, 1);
        if (value != null) forecast.put("_station", value);
      } catch (Exception ignored) {
        forecast.put("_stationUnavailable", true);
        if (prior != null && prior.has("_station")) forecast.put("_station", prior.get("_station"));
      }
      try {
        JSONObject value = await(alerts, deadline, 1);
        for (String key : ForecastSources.keys(value)) forecast.put(key, value.get(key));
      } catch (Exception ignored) {
        forecast.put("_alertsUnavailable", true);
        if (prior != null) {
          if (prior.has("_alerts")) forecast.put("_alerts", prior.get("_alerts"));
          forecast.put("_alertsChecked", prior.optLong("_alertsChecked"));
        }
      }
      try {
        JSONObject value = await(air, deadline, 1);
        if (value != null
            && Double.isFinite(ForecastSources.number(value, "us_aqi"))
            && ForecastSources.number(value, "us_aqi") >= 0) forecast.put("_airQuality", value);
      } catch (Exception ignored) {
        forecast.put("_airUnavailable", true);
        if (prior != null && prior.has("_airQuality"))
          forecast.put("_airQuality", prior.get("_airQuality"));
      }
      List<RadarFrame> frames;
      try {
        frames = await(radar, deadline, 3);
      } catch (Exception ignored) {
        frames = new ArrayList<>();
      }
      JSONObject saved =
          new JSONObject()
              .put("forecast", forecast)
              .put("source", source)
              .put("accessMessage", message)
              .put("place", place.json());
      files.write(cache, saved);
      files.write("last-forecast", saved);
      files.log("Forecast updated");
      return new Result(forecast, source, frames, message);
    } catch (Exception error) {
      JSONObject saved = files.read(cache), forecast = saved.optJSONObject("forecast");
      if (forecast == null
          || java.time.Instant.now().getEpochSecond() - forecast.optLong("_updated") > 24 * 3600)
        throw error;
      forecast.put("_cached", true);
      files.log("Forecast cached");
      List<RadarFrame> frames;
      try {
        frames = await(radar, deadline, 1);
      } catch (Exception ignored) {
        frames = new ArrayList<>();
      }
      return new Result(
          forecast,
          saved.optString("source", "Forecast"),
          frames,
          "Showing a saved forecast. Check its update time.");
    } finally {
      pool.shutdownNow();
    }
  }

  private void applyTemperatureSelection(
      JSONObject forecast,
      ForecastSources.Source baseline,
      List<ForecastSources.Source> sources,
      Place place)
      throws Exception {
    JSONObject state = files.read("evidence");
    JSONArray samples = state.optJSONArray("samples");
    if (samples == null) return;
    List<String> names =
        sources.stream()
            .map(ForecastSources.Source::name)
            .collect(java.util.stream.Collectors.toList());
    JSONObject h = forecast.optJSONObject("hourly");
    if (h == null) return;
    JSONArray times = h.optJSONArray("time"), temperatures = h.optJSONArray("temperature_2m");
    if (times == null || temperatures == null) return;
    for (int bucket = 0; bucket < 4; bucket++) {
      String winner =
          EvidenceStore.decision(
              EvidenceStore.paired(
                  samples, names, LocalData.placeKey(place), bucket, EvidenceStore.now()),
              names,
              baseline.name());
      if (winner == null) continue;
      ForecastSources.Source chosen =
          sources.stream().filter(s -> s.name().equals(winner)).findFirst().orElse(null);
      if (chosen == null) continue;
      JSONObject alternative = chosen.data().optJSONObject("hourly");
      JSONArray at = alternative == null ? null : alternative.optJSONArray("time");
      if (at == null) continue;
      for (int i = 0; i < times.length(); i++) {
        long t = times.optLong(i);
        if (ForecastSources.bucket(t - EvidenceStore.now()) != bucket) continue;
        for (int j = 0; j < at.length(); j++)
          if (at.optLong(j) == t) {
            double value = ForecastSources.number(alternative.optJSONArray("temperature_2m"), j);
            if (Double.isFinite(value)) {
              temperatures.put(i, value);
              forecast.put("_hourlySource", baseline.name() + " · evidence-selected temperature");
            }
            break;
          }
      }
    }
  }

  static List<Place> search(String query) throws Exception {
    JSONObject reply =
        request(
            "https://geocoding-api.open-meteo.com/v1/search?count=8&language=en&name="
                + encode(query),
            "GET",
            null,
            null);
    List<Place> places = new ArrayList<>();
    JSONArray values = reply.optJSONArray("results");
    if (values != null)
      for (int i = 0; i < values.length(); i++) {
        JSONObject row = values.getJSONObject(i);
        places.add(
            new Place(
                row.getString("name") + ", " + row.optString("admin1", row.optString("country")),
                row.getDouble("latitude"),
                row.getDouble("longitude")));
      }
    return places;
  }
}
