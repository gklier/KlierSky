package com.klier.kliersky;

import java.time.*;
import java.util.*;
import java.util.concurrent.*;
import org.json.*;

/**
 * Provider adapters and weighted arithmetic mirror the iOS source contract. Missing stays missing.
 */
final class ForecastSources {
  record Source(String name, JSONObject data) {}

  static final String[] VARIABLES = {
    "temperature_2m",
    "apparent_temperature",
    "precipitation_probability",
    "precipitation",
    "weather_code",
    "is_day",
    "relative_humidity_2m",
    "dew_point_2m",
    "wind_speed_10m",
    "wind_gusts_10m",
    "wind_direction_10m",
    "pressure_msl",
    "cloud_cover",
    "uv_index",
    "visibility",
    "snowfall"
  };
  static final String[][] MODELS = {
    {"ecmwf_ifs025", "ECMWF"},
    {"gfs_seamless", "NOAA GFS"},
    {"icon_seamless", "DWD ICON"},
    {"ukmo_seamless", "UK Met Office"},
    {"meteofrance_seamless", "Météo-France"},
    {"gem_seamless", "Canada GEM"}
  };

  static java.util.List<String> keys(JSONObject value) {
    java.util.List<String> keys = new java.util.ArrayList<>();
    value.keys().forEachRemaining(keys::add);
    return keys;
  }

  static void normalizeDays(List<Source> sources) throws Exception {
    String timezone =
        sources.stream()
            .map(s -> s.data().optString("timezone", ""))
            .filter(v -> !v.isEmpty())
            .findFirst()
            .orElse("");
    for (Source source : sources) {
      JSONObject f = source.data();
      if (!timezone.isEmpty() && !f.has("timezone")) f.put("timezone", timezone);
      JSONArray rows = f.optJSONArray("dailyRows");
      if (rows == null || rows.length() == 0) continue;
      ZoneId zone;
      try {
        zone =
            timezone.isEmpty()
                ? ZoneOffset.ofTotalSeconds(f.optInt("utc_offset_seconds", 0))
                : ZoneId.of(timezone);
      } catch (Exception e) {
        zone = ZoneOffset.UTC;
      }
      JSONObject daily = new JSONObject().put("time", new JSONArray());
      String[][] fields = {
        {"temperature_2m_max", "high"},
        {"temperature_2m_min", "low"},
        {"weather_code", "code"},
        {"precipitation_sum", "rain"},
        {"precipitation_probability_max", "chance"},
        {"wind_speed_10m_max", "wind"},
        {"wind_gusts_10m_max", "gust"},
        {"uv_index_max", "uv"},
        {"apparent_temperature_max", "feelsHigh"},
        {"apparent_temperature_min", "feelsLow"}
      };
      for (String[] field : fields) daily.put(field[0], new JSONArray());
      daily.put("sunrise", new JSONArray()).put("sunset", new JSONArray());
      for (int i = 0; i < rows.length(); i++) {
        JSONObject row = rows.getJSONObject(i);
        LocalDate date = LocalDate.parse(row.getString("dateKey"));
        daily.getJSONArray("time").put(date.atStartOfDay(zone).toEpochSecond());
        for (String[] field : fields)
          daily
              .getJSONArray(field[0])
              .put(row.opt(field[1]) == null ? JSONObject.NULL : row.opt(field[1]));
        for (String sun : new String[] {"sunrise", "sunset"}) {
          String value = row.optString(sun + "Local", "");
          Long time = null;
          try {
            time = stamp(value);
          } catch (Exception ignored) {
            try {
              time = LocalTime.parse(value).atDate(date).atZone(zone).toEpochSecond();
            } catch (Exception unused) {
            }
          }
          daily.getJSONArray(sun).put(time == null ? JSONObject.NULL : time);
        }
      }
      f.put("daily", daily);
    }
  }

  static double prior(String source) {
    return switch (source) {
      case "Foreca" -> 3;
      case "NWS", "Open-Meteo", "ECMWF" -> 2;
      case "MET Norway", "DWD ICON", "NOAA GFS", "UK Met Office" -> 1.5;
      default -> 1;
    };
  }

  static int bucket(long lead) {
    return lead < 21600 ? 0 : lead < 86400 ? 1 : lead < 259200 ? 2 : 3;
  }

  static double number(JSONObject o, String key) {
    return o == null || o.isNull(key) ? Double.NaN : o.optDouble(key, Double.NaN);
  }

  static double number(JSONArray a, int i) {
    return a == null || a.isNull(i) ? Double.NaN : a.optDouble(i, Double.NaN);
  }

  static void put(JSONObject o, String key, double value) throws Exception {
    o.put(key, Double.isFinite(value) ? value : JSONObject.NULL);
  }

  static long stamp(String value) {
    try {
      return OffsetDateTime.parse(value).toEpochSecond();
    } catch (Exception e) {
      return Instant.parse(value).getEpochSecond();
    }
  }

  static String point(WeatherService.Place p) {
    return "latitude=" + p.latitude() + "&longitude=" + p.longitude();
  }

  static JSONObject get(String url) throws Exception {
    return WeatherService.request(url, "GET", null, null);
  }

  static JSONObject open(WeatherService.Place p) throws Exception {
    String vars = String.join(",", VARIABLES);
    return get(
        "https://api.open-meteo.com/v1/forecast?"
            + point(p)
            + "&current="
            + vars.replace(",visibility", "").replace(",snowfall", "")
            + "&hourly="
            + vars
            + "&daily=temperature_2m_max,temperature_2m_min,weather_code,precipitation_probability_max,precipitation_sum,snowfall_sum,wind_speed_10m_max,wind_gusts_10m_max,uv_index_max,apparent_temperature_max,apparent_temperature_min,daylight_duration,sunrise,sunset&temperature_unit=fahrenheit&wind_speed_unit=mph&timeformat=unixtime&timezone=auto&forecast_days=14");
  }

  static List<Source> models(WeatherService.Place p) throws Exception {
    String[] vars = Arrays.copyOf(VARIABLES, 13);
    JSONObject response =
        get(
            "https://api.open-meteo.com/v1/forecast?"
                + point(p)
                + "&hourly="
                + String.join(",", vars)
                + "&models="
                + String.join(",", Arrays.stream(MODELS).map(m -> m[0]).toArray(String[]::new))
                + "&temperature_unit=fahrenheit&wind_speed_unit=mph&timeformat=unixtime&forecast_days=7");
    JSONObject h = response.getJSONObject("hourly");
    List<Source> found = new ArrayList<>();
    for (String[] model : MODELS) {
      JSONArray temperatures = h.optJSONArray("temperature_2m_" + model[0]);
      if (temperatures == null) continue;
      boolean usable = false;
      for (int i = 0; i < temperatures.length(); i++)
        if (Double.isFinite(number(temperatures, i))) {
          usable = true;
          break;
        }
      if (!usable) continue;
      JSONObject hourly = new JSONObject().put("time", h.getJSONArray("time"));
      for (String key : vars)
        if (h.has(key + "_" + model[0])) hourly.put(key, h.getJSONArray(key + "_" + model[0]));
      found.add(new Source(model[1], new JSONObject().put("hourly", hourly)));
    }
    return found;
  }

  static int code(String text) {
    if (text == null || text.isEmpty()) return -1;
    String s = text.toLowerCase(Locale.ROOT);
    String[] words = {
      "thunder",
      "sleet",
      "freezing",
      "wintry",
      "snowshowers",
      "snow showers",
      "snow",
      "drizzle",
      "rainshowers",
      "showers",
      "rain",
      "fog",
      "haze",
      "clearsky",
      "mostly clear",
      "mostly sunny",
      "fair",
      "partly",
      "overcast",
      "cloudy",
      "sunny",
      "clear"
    };
    int[] codes = {95, 69, 69, 69, 85, 85, 73, 51, 80, 80, 63, 45, 45, 0, 1, 1, 1, 2, 3, 3, 0, 0};
    for (int i = 0; i < words.length; i++) if (s.contains(words[i])) return codes[i];
    return -1;
  }

  static Source norway(WeatherService.Place p) throws Exception {
    JSONObject reply =
        get(
            String.format(
                Locale.ROOT,
                "https://api.met.no/weatherapi/locationforecast/2.0/complete?lat=%.2f&lon=%.2f",
                p.latitude(),
                p.longitude()));
    JSONObject h = new JSONObject();
    h.put("time", new JSONArray());
    for (String key : VARIABLES) h.put(key, new JSONArray());
    JSONObject current = null;
    JSONArray entries = reply.getJSONObject("properties").getJSONArray("timeseries");
    long now = Instant.now().getEpochSecond();
    for (int i = 0; i < entries.length(); i++) {
      JSONObject entry = entries.getJSONObject(i),
          data = entry.getJSONObject("data"),
          next = data.optJSONObject("next_1_hours");
      if (next == null) continue;
      long t = stamp(entry.getString("time"));
      JSONObject d = data.getJSONObject("instant").getJSONObject("details"),
          period = next.optJSONObject("details"),
          summary = next.optJSONObject("summary");
      String symbol = summary == null ? "" : summary.optString("symbol_code");
      JSONObject row = new JSONObject();
      put(row, "temperature_2m", number(d, "air_temperature") * 1.8 + 32);
      put(row, "apparent_temperature", number(d, "apparent_air_temperature") * 1.8 + 32);
      put(row, "dew_point_2m", number(d, "dew_point_temperature") * 1.8 + 32);
      put(row, "precipitation_probability", number(period, "probability_of_precipitation"));
      put(row, "precipitation", number(period, "precipitation_amount"));
      put(row, "relative_humidity_2m", number(d, "relative_humidity"));
      put(row, "wind_speed_10m", number(d, "wind_speed") * 2.236936);
      put(row, "wind_gusts_10m", number(d, "wind_speed_of_gust") * 2.236936);
      put(row, "wind_direction_10m", number(d, "wind_from_direction"));
      put(row, "pressure_msl", number(d, "air_pressure_at_sea_level"));
      put(row, "cloud_cover", number(d, "cloud_area_fraction"));
      if (code(symbol) >= 0) row.put("weather_code", code(symbol));
      if (symbol.endsWith("_day") || symbol.endsWith("_night"))
        row.put("is_day", symbol.endsWith("_day") ? 1 : 0);
      h.getJSONArray("time").put(t);
      for (String key : VARIABLES)
        h.getJSONArray(key).put(row.opt(key) == null ? JSONObject.NULL : row.opt(key));
      if (current == null
          && Math.abs(t - now) <= 3600
          && Double.isFinite(number(row, "temperature_2m"))) current = row.put("time", t);
    }
    JSONObject normalized = new JSONObject().put("hourly", h);
    if (current != null) normalized.put("current", current);
    return new Source("MET Norway", normalized);
  }

  static JSONObject nwsPoint(WeatherService.Place p) throws Exception {
    return get(String.format(
            Locale.ROOT, "https://api.weather.gov/points/%.4f,%.4f", p.latitude(), p.longitude()))
        .getJSONObject("properties");
  }

  static String trustedNWS(String value) throws Exception {
    java.net.URI uri = java.net.URI.create(value);
    if (!"https".equals(uri.getScheme()) || !"api.weather.gov".equals(uri.getHost()))
      throw new java.io.IOException("Unrecognized weather service link");
    return value;
  }

  static Source nws(WeatherService.Place p) throws Exception {
    JSONObject point = nwsPoint(p);
    JSONArray periods =
        get(trustedNWS(point.getString("forecastHourly")))
            .getJSONObject("properties")
            .getJSONArray("periods");
    JSONObject h = new JSONObject().put("time", new JSONArray());
    for (String k : VARIABLES) h.put(k, new JSONArray());
    String[] compass = {
      "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW",
      "NNW"
    };
    for (int i = 0; i < periods.length(); i++) {
      JSONObject p1 = periods.getJSONObject(i), row = new JSONObject();
      double temperature = number(p1, "temperature");
      if (!Double.isFinite(temperature)) continue;
      put(
          row,
          "temperature_2m",
          p1.optString("temperatureUnit").equals("C") ? temperature * 1.8 + 32 : temperature);
      put(
          row,
          "precipitation_probability",
          number(p1.optJSONObject("probabilityOfPrecipitation"), "value"));
      put(row, "relative_humidity_2m", number(p1.optJSONObject("relativeHumidity"), "value"));
      JSONObject dew = p1.optJSONObject("dewpoint");
      double d = number(dew, "value");
      put(
          row,
          "dew_point_2m",
          dew != null && dew.optString("unitCode").endsWith("degF") ? d : d * 1.8 + 32);
      String wind = p1.optString("windSpeed");
      double sum = 0;
      int count = 0;
      if (wind.contains("mph")) {
        java.util.regex.Matcher m =
            java.util.regex.Pattern.compile("[0-9]+(?:\\.[0-9]+)?").matcher(wind);
        while (m.find()) {
          sum += Double.parseDouble(m.group());
          count++;
        }
      }
      put(row, "wind_speed_10m", count > 0 ? sum / count : Double.NaN);
      int direction = Arrays.asList(compass).indexOf(p1.optString("windDirection"));
      if (direction >= 0) row.put("wind_direction_10m", direction * 22.5);
      int code = code(p1.optString("shortForecast"));
      if (code >= 0) row.put("weather_code", code);
      if (p1.has("isDaytime")) row.put("is_day", p1.getBoolean("isDaytime") ? 1 : 0);
      h.getJSONArray("time").put(stamp(p1.getString("startTime")));
      for (String key : VARIABLES)
        h.getJSONArray(key).put(row.opt(key) == null ? JSONObject.NULL : row.opt(key));
    }
    return new Source("NWS", new JSONObject().put("hourly", h));
  }

  static boolean us(WeatherService.Place p) {
    return p.latitude() >= 17.5
        && p.latitude() <= 71.6
        && p.longitude() >= -180
        && p.longitude() <= -64.4;
  }

  static List<Source> free(WeatherService.Place p) {
    ExecutorService pool = Executors.newFixedThreadPool(3);
    List<Callable<List<Source>>> tasks = new ArrayList<>();
    tasks.add(() -> models(p));
    tasks.add(() -> java.util.Collections.singletonList(norway(p)));
    if (us(p)) tasks.add(() -> java.util.Collections.singletonList(nws(p)));
    List<Source> sources = new ArrayList<>();
    try {
      for (Future<List<Source>> f : pool.invokeAll(tasks, 40, TimeUnit.SECONDS))
        try {
          sources.addAll(f.get());
        } catch (Exception ignored) {
        }
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
    } finally {
      pool.shutdownNow();
    }
    sources.removeIf(
        source -> {
          JSONObject h = source.data().optJSONObject("hourly");
          JSONArray t = h == null ? null : h.optJSONArray("time");
          return t == null || t.length() == 0;
        });
    return sources;
  }

  static double mean(List<Double> values, List<Double> weights, boolean direction) {
    double sum = 0, total = 0, x = 0, y = 0;
    for (int i = 0; i < values.size(); i++) {
      double v = values.get(i), w = weights.get(i);
      if (!Double.isFinite(v) || w <= 0) continue;
      if (direction) {
        x += Math.cos(Math.toRadians(v)) * w;
        y += Math.sin(Math.toRadians(v)) * w;
      } else sum += v * w;
      total += w;
    }
    return total == 0
        ? Double.NaN
        : direction ? (Math.toDegrees(Math.atan2(y, x)) + 360) % 360 : sum / total;
  }

  static List<Source> ranked(List<Source> sources, Map<String, Double> weights) {
    List<Source> result = new ArrayList<>(sources);
    result.sort(
        (a, b) -> {
          int compare =
              Double.compare(
                  weights.getOrDefault(b.name(), prior(b.name())),
                  weights.getOrDefault(a.name(), prior(a.name())));
          return compare == 0 ? a.name().compareTo(b.name()) : compare;
        });
    return result;
  }

  static JSONObject blend(List<Source> sources, List<Map<String, Double>> tables) throws Exception {
    if (sources.isEmpty()) throw new java.io.IOException("No forecasts available");
    List<Source> ranked = ranked(sources, tables.get(0));
    Source anchor =
        ranked.stream()
            .filter(s -> s.data().has("current") && s.data().has("daily"))
            .findFirst()
            .orElse(ranked.get(0));
    JSONObject result = new JSONObject(anchor.data().toString());
    result.remove("dailyRows");
    JSONObject members = new JSONObject();
    for (Source s : ranked)
      members.put(s.name(), tables.get(0).getOrDefault(s.name(), prior(s.name())));
    TreeSet<Long> times = new TreeSet<>();
    Map<String, Map<Long, Integer>> indices = new HashMap<>();
    for (Source source : sources) {
      JSONObject h = source.data().optJSONObject("hourly");
      Map<Long, Integer> map = new HashMap<>();
      JSONArray t = h == null ? null : h.optJSONArray("time");
      if (t != null)
        for (int i = 0; i < t.length(); i++) {
          long v = t.optLong(i);
          times.add(v);
          map.put(v, i);
        }
      indices.put(source.name(), map);
    }
    JSONObject hourly = new JSONObject().put("time", new JSONArray());
    for (String key : VARIABLES) hourly.put(key, new JSONArray());
    long now = Instant.now().getEpochSecond();
    for (long time : times) {
      hourly.getJSONArray("time").put(time);
      Map<String, Double> weights = tables.get(bucket(time - now));
      List<Source> order = ranked(sources, weights);
      for (String key : VARIABLES) {
        List<Double> values = new ArrayList<>(), w = new ArrayList<>();
        double categorical = Double.NaN;
        for (Source s : order) {
          Integer i = indices.get(s.name()).get(time);
          JSONObject h = s.data().optJSONObject("hourly");
          double v = i == null ? Double.NaN : number(h.optJSONArray(key), i);
          if (key.equals("weather_code") && v < 0) v = Double.NaN;
          if (Double.isFinite(v) && !Double.isFinite(categorical)) categorical = v;
          values.add(v);
          w.add(weights.getOrDefault(s.name(), prior(s.name())));
        }
        double value =
            key.equals("weather_code") || key.equals("is_day")
                ? categorical
                : mean(values, w, key.equals("wind_direction_10m"));
        hourly.getJSONArray(key).put(Double.isFinite(value) ? value : JSONObject.NULL);
      }
    }
    result.put("hourly", hourly);
    JSONObject current = new JSONObject();
    Set<String> currentMembers = new LinkedHashSet<>();
    for (String key : VARIABLES) {
      List<Double> values = new ArrayList<>(), weights = new ArrayList<>();
      double categorical = Double.NaN;
      for (Source s : ranked) {
        double v = number(s.data().optJSONObject("current"), key);
        if (key.equals("weather_code") && v < 0) v = Double.NaN;
        if (Double.isFinite(v)) {
          currentMembers.add(s.name());
          if (!Double.isFinite(categorical)) categorical = v;
        }
        values.add(v);
        weights.add(tables.get(0).getOrDefault(s.name(), prior(s.name())));
      }
      put(
          current,
          key,
          key.equals("weather_code") || key.equals("is_day")
              ? categorical
              : mean(values, weights, key.equals("wind_direction_10m")));
    }
    JSONObject anchorCurrent = anchor.data().optJSONObject("current");
    if (anchorCurrent != null && anchorCurrent.has("time"))
      current.put("time", anchorCurrent.get("time"));
    result.put("current", current);
    JSONObject daily = anchor.data().optJSONObject("daily");
    Set<String> dailyMembers = new LinkedHashSet<>();
    if (daily != null) {
      JSONObject output = new JSONObject(daily.toString());
      JSONArray days = daily.getJSONArray("time");
      for (String key : keys(daily)) {
        if (key.equals("time")) continue;
        JSONArray values = new JSONArray();
        for (int i = 0; i < days.length(); i++) {
          List<Double> numbers = new ArrayList<>(), weights = new ArrayList<>();
          double categorical = Double.NaN;
          for (Source s : ranked) {
            JSONObject d = s.data().optJSONObject("daily");
            JSONArray dt = d == null ? null : d.optJSONArray("time");
            int index = -1;
            if (dt != null)
              for (int j = 0; j < dt.length(); j++)
                if (String.valueOf(dt.get(j)).equals(String.valueOf(days.get(i)))) {
                  index = j;
                  break;
                }
            double v = index < 0 ? Double.NaN : number(d.optJSONArray(key), index);
            if (Double.isFinite(v)) {
              dailyMembers.add(s.name());
              if (!Double.isFinite(categorical)) categorical = v;
            }
            numbers.add(v);
            weights.add(tables.get(2).getOrDefault(s.name(), prior(s.name())));
          }
          boolean discrete =
              key.equals("weather_code") || key.equals("sunrise") || key.equals("sunset");
          double v = discrete ? categorical : mean(numbers, weights, false);
          values.put(Double.isFinite(v) ? v : JSONObject.NULL);
        }
        output.put(key, values);
      }
      result.put("daily", output);
    }
    result
        .put("_weights", members)
        .put("_currentSource", summary(currentMembers))
        .put("_hourlySource", summary(keys(members)))
        .put("_dailySource", summary(dailyMembers));
    result.put("_provenance", provenance(sources));
    return result;
  }

  static JSONObject provenance(List<Source> sources) throws Exception {
    JSONObject metadata = new JSONObject();
    for (String group : new String[] {"current", "hourly", "daily"}) {
      JSONObject fields = new JSONObject();
      Set<String> keys = new LinkedHashSet<>();
      for (Source source : sources) {
        JSONObject data = source.data().optJSONObject(group);
        if (data != null) keys.addAll(keys(data));
      }
      for (String key : keys) {
        if (key.equals("time")) continue;
        JSONArray contributors = new JSONArray();
        for (Source source : sources) {
          JSONObject data = source.data().optJSONObject(group);
          if (data == null) continue;
          boolean available = Double.isFinite(number(data, key));
          JSONArray values = data.optJSONArray(key);
          if (values != null)
            for (int i = 0; i < values.length() && !available; i++)
              available = Double.isFinite(number(values, i));
          if (available) contributors.put(source.name());
        }
        fields.put(key, contributors);
      }
      metadata.put(group, fields);
    }
    return metadata;
  }

  static String fieldSource(JSONObject forecast, String group, String key) {
    JSONObject metadata = forecast.optJSONObject("_provenance"),
        fields = metadata == null ? null : metadata.optJSONObject(group);
    JSONArray names = fields == null ? null : fields.optJSONArray(key);
    if (names == null) return forecast.optString("_" + group + "Source", "Forecast");
    if (names.length() == 0) return "Unavailable";
    if (names.length() == 1) return names.optString(0);
    if (names.length() == 2) return names.optString(0) + " + " + names.optString(1);
    return "Blend of " + names.length() + " sources";
  }

  static String summary(Collection<String> names) {
    return names.isEmpty()
        ? "Unavailable"
        : names.size() == 1 ? names.iterator().next() : "Blend of " + names.size() + " sources";
  }
}
