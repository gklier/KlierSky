package com.klier.kliersky;

import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.*;
import org.json.*;

final class RadarTimeline {
  static boolean covers(WeatherService.Place p) {
    return p.latitude() >= 24
        && p.latitude() <= 50
        && p.longitude() >= -125.5
        && p.longitude() <= -66.5;
  }

  static List<WeatherService.RadarFrame> observed() throws Exception {
    JSONObject radar = ForecastSources.get("https://api.rainviewer.com/public/weather-maps.json");
    JSONArray past = radar.getJSONObject("radar").getJSONArray("past");
    String host = radar.getString("host");
    String hostname = java.net.URI.create(host).getHost();
    if (!host.startsWith("https://")
        || hostname == null
        || !(hostname.equals("rainviewer.com") || hostname.endsWith(".rainviewer.com")))
      throw new java.io.IOException("Unrecognized radar host");
    List<WeatherService.RadarFrame> frames = new ArrayList<>();
    for (int i = 0; i < past.length(); i++) {
      JSONObject item = past.getJSONObject(i);
      frames.add(
          new WeatherService.RadarFrame(
              item.getLong("time"),
              host + item.getString("path") + "/256/{z}/{x}/{y}/2/1_1.png",
              "observed",
              0));
    }
    return frames;
  }

  static List<WeatherService.RadarFrame> future(WeatherService.Place place) throws Exception {
    if (!covers(place)) return Collections.emptyList();
    JSONObject
        first =
            ForecastSources.get(
                "https://mesonet.agron.iastate.edu/data/gis/images/4326/hrrr/refd_0000.json"),
        last =
            ForecastSources.get(
                "https://mesonet.agron.iastate.edu/data/gis/images/4326/hrrr/refd_1080.json");
    return future(place, first, last, Instant.now().getEpochSecond());
  }

  static List<WeatherService.RadarFrame> future(
      WeatherService.Place place, JSONObject first, JSONObject last, long now) throws Exception {
    if (!covers(place)) return Collections.emptyList();
    long newest = ForecastSources.stamp(first.getString("model_init_utc")),
        complete = ForecastSources.stamp(last.getString("model_init_utc")),
        valid = ForecastSources.stamp(last.getString("model_forecast_utc")),
        run = Math.min(newest, complete);
    if (last.getInt("forecast_minute") != 1080
        || valid - complete != 1080 * 60
        || run > now + 300
        || now - run > 6 * 3600) throw new java.io.IOException("Model run incomplete or stale");
    String stamp =
        DateTimeFormatter.ofPattern("yyyyMMddHHmm")
            .withZone(ZoneOffset.UTC)
            .format(Instant.ofEpochSecond(run));
    List<WeatherService.RadarFrame> frames = new ArrayList<>();
    for (int minute = 0; minute <= 1080; minute += 15) {
      long time = run + minute * 60;
      if (time < now) continue;
      String url =
          String.format(
              Locale.ROOT,
              "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/hrrr::REFD-F%04d-%s/{z}/{x}/{y}.png",
              minute,
              stamp);
      frames.add(new WeatherService.RadarFrame(time, url, "forecast", run));
    }
    return frames;
  }
}
