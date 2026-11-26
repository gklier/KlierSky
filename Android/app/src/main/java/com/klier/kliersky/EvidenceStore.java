package com.klier.kliersky;

import android.content.Context;
import java.time.*;
import java.util.*;
import org.json.*;

/**
 * Temperature-only evidence, with pre-target capture, independent station and paired/held-out
 * gates.
 */
final class EvidenceStore {
  private static final java.util.concurrent.ExecutorService VERIFIER =
      java.util.concurrent.Executors.newSingleThreadExecutor();
  private static final java.util.Set<String> CHECKING =
      java.util.concurrent.ConcurrentHashMap.newKeySet();

  void verifyLater(WeatherService.Place place) {
    if (!preferences.getBoolean("verifyStations", false)) return;
    String key = LocalData.placeKey(place);
    if (!CHECKING.add(key)) return;
    VERIFIER.execute(
        () -> {
          try {
            verify(place, false);
          } catch (Exception ignored) {
            files.log("Station verification unavailable");
          } finally {
            CHECKING.remove(key);
          }
        });
  }

  final LocalData files;
  final android.content.SharedPreferences preferences;

  EvidenceStore(Context context) {
    files = new LocalData(context);
    preferences = context.getSharedPreferences("weather", 0);
  }

  static double n(JSONObject o, String key) {
    return ForecastSources.number(o, key);
  }

  static long now() {
    return Instant.now().getEpochSecond();
  }

  synchronized void capture(WeatherService.Place place, List<ForecastSources.Source> sources)
      throws Exception {
    synchronized (EvidenceStore.class) {
      if (!preferences.getBoolean("verifyStations", false)) return;
      int generation = preferences.getInt("evidenceGeneration", 0);
      JSONObject state = files.read("evidence");
      JSONArray archive = state.optJSONArray("captures");
      if (archive == null) archive = new JSONArray();
      Set<String> keys = new HashSet<>();
      long now = now();
      String location = LocalData.placeKey(place);
      JSONArray result = new JSONArray();
      for (int i = Math.max(0, archive.length() - 30000); i < archive.length(); i++) {
        JSONObject r = archive.getJSONObject(i);
        if (now - r.optLong("issued") < 30 * 86400) {
          result.put(r);
          keys.add(r.optString("key"));
        }
      }
      for (var source : sources) {
        JSONObject h = source.data().optJSONObject("hourly");
        if (h == null) continue;
        JSONArray times = h.optJSONArray("time"), temps = h.optJSONArray("temperature_2m");
        if (times == null) continue;
        for (int i = 0; i < times.length(); i++) {
          long target = times.optLong(i);
          double value = ForecastSources.number(temps, i);
          if (target < now + 1800 || !Double.isFinite(value)) continue;
          int bucket = ForecastSources.bucket(target - now);
          String key = location + "|" + source.name() + "|" + target + "|" + bucket;
          if (keys.add(key))
            result.put(
                new JSONObject()
                    .put("key", key)
                    .put("place", location)
                    .put("provider", source.name())
                    .put("issued", now)
                    .put("target", target)
                    .put("bucket", bucket)
                    .put("temperature", value));
        }
      }
      JSONArray bounded = new JSONArray();
      for (int i = Math.max(0, result.length() - 30000); i < result.length(); i++)
        bounded.put(result.get(i));
      if (!preferences.getBoolean("verifyStations", false)
          || generation != preferences.getInt("evidenceGeneration", 0)) return;
      state.put("captures", bounded);
      files.write("evidence", state);
      files.log("Evidence captured");
    }
  }

  record Pair(long target, long issued, Map<String, Double> errors) {}

  static List<Pair> paired(
      JSONArray samples, List<String> sources, String place, int bucket, long now)
      throws Exception {
    Map<Long, Map<String, JSONObject>> targets = new TreeMap<>();
    for (int i = 0; i < samples.length(); i++) {
      JSONObject row = samples.getJSONObject(i);
      if (!row.has("issued") || row.optLong("issued") <= 0 || !Double.isFinite(n(row, "error")))
        continue;
      if (!row.optString("place").equals(place)
          || row.optInt("bucket") != bucket
          || row.optLong("target") > now
          || now - row.optLong("observed") >= 30 * 86400
          || !sources.contains(row.optString("provider"))) continue;
      targets
          .computeIfAbsent(row.getLong("target"), k -> new HashMap<>())
          .put(row.getString("provider"), row);
    }
    List<Pair> result = new ArrayList<>();
    for (var entry : targets.entrySet()) {
      if (entry.getValue().size() != sources.size()) continue;
      long earliest = Long.MAX_VALUE, latest = 0;
      Map<String, Double> errors = new HashMap<>();
      for (String source : sources) {
        JSONObject row = entry.getValue().get(source);
        earliest = Math.min(earliest, row.optLong("issued", Long.MAX_VALUE));
        latest = Math.max(latest, row.optLong("issued", 0));
        errors.put(source, Math.abs(row.getDouble("error")));
      }
      if (latest - earliest <= 3600 && latest <= entry.getKey() - 1800)
        result.add(new Pair(entry.getKey(), latest, errors));
    }
    return result;
  }

  static int days(List<Pair> pairs) {
    return (int) pairs.stream().map(p -> p.target() / 86400).distinct().count();
  }

  static String winner(List<Pair> pairs, List<String> sources) {
    if (pairs.size() < 20 || sources.size() < 2) return null;
    List<String> ranking = new ArrayList<>(sources);
    ranking.sort(
        Comparator.comparingDouble(
            s ->
                pairs.stream()
                    .mapToDouble(p -> p.errors().get(s))
                    .average()
                    .orElse(Double.POSITIVE_INFINITY)));
    double
        first = pairs.stream().mapToDouble(p -> p.errors().get(ranking.get(0))).average().orElse(0),
        second =
            pairs.stream().mapToDouble(p -> p.errors().get(ranking.get(1))).average().orElse(0);
    return second - first >= .5 ? ranking.get(0) : null;
  }

  static String decision(List<Pair> rows, List<String> sources, String baseline) {
    if (rows.size() < 20 || days(rows) < 5) return null;
    String candidate = winner(rows, sources);
    if (candidate == null || candidate.equals(baseline)) return null;
    int evaluated = 0, switched = 0;
    Set<Long> switchedDays = new HashSet<>();
    double base = 0, adaptive = 0;
    for (Pair row : rows) {
      List<Pair> prior =
          rows.stream()
              .filter(p -> p.target() + 900 <= row.issued())
              .collect(java.util.stream.Collectors.toList());
      if (prior.size() < 20) continue;
      String choice = winner(prior, sources);
      if (choice == null) choice = baseline;
      evaluated++;
      if (!choice.equals(baseline)) {
        switched++;
        switchedDays.add(row.target() / 86400);
      }
      base += row.errors().get(baseline);
      adaptive += row.errors().get(choice);
    }
    return evaluated > 0
            && switched >= 10
            && switchedDays.size() >= 3
            && (base - adaptive) / evaluated >= .25
        ? candidate
        : null;
  }

  List<Map<String, Double>> weights(
      WeatherService.Place place, List<ForecastSources.Source> sources) throws Exception {
    List<String> names =
        sources.stream()
            .map(ForecastSources.Source::name)
            .collect(java.util.stream.Collectors.toList());
    JSONObject state = files.read("evidence");
    JSONArray scores = state.optJSONArray("samples");
    if (scores == null) scores = new JSONArray();
    List<Map<String, Double>> tables = new ArrayList<>();
    boolean measured = false;
    for (int bucket = 0; bucket < 4; bucket++) {
      Map<String, Double> weights = new LinkedHashMap<>();
      for (String name : names) weights.put(name, ForecastSources.prior(name));
      List<String> eligible = new ArrayList<>();
      List<Pair> common = new ArrayList<>();
      for (String name : names) {
        List<String> candidates = new ArrayList<>(eligible);
        candidates.add(name);
        List<Pair> pairs = paired(scores, candidates, LocalData.placeKey(place), bucket, now());
        if (pairs.size() >= 20 && days(pairs) >= 5) {
          eligible = candidates;
          common = pairs;
        }
      }
      if (eligible.size() >= 2) {
        List<Pair> paired = common;
        List<Double> misses =
            eligible.stream()
                .map(s -> paired.stream().mapToDouble(p -> p.errors().get(s)).average().orElse(0))
                .sorted()
                .collect(java.util.stream.Collectors.toList());
        double typical =
            misses.size() % 2 == 1
                ? misses.get(misses.size() / 2)
                : (misses.get(misses.size() / 2 - 1) + misses.get(misses.size() / 2)) / 2;
        for (String source : eligible) {
          double mae = paired.stream().mapToDouble(p -> p.errors().get(source)).average().orElse(0);
          double ratio = Math.max(.25, typical) / Math.max(.25, mae);
          weights.put(source, weights.get(source) * Math.min(4, Math.max(.25, ratio * ratio)));
        }
        measured = true;
      }
      tables.add(weights);
    }
    preferences.edit().putBoolean("weightsMeasured", measured).apply();
    return tables;
  }

  synchronized void verify(WeatherService.Place place, boolean force) throws Exception {
    if (!preferences.getBoolean("verifyStations", false)) return;
    int generation = preferences.getInt("evidenceGeneration", 0);
    JSONObject state = files.read("evidence");
    String key = LocalData.placeKey(place);
    JSONObject stations = state.optJSONObject("stations");
    if (stations == null) stations = new JSONObject();
    JSONObject station = stations.optJSONObject(key);
    long now = now();
    if (!force && station != null && now - station.optLong("checked") < 3300) return;
    if (station == null) {
      JSONObject point = ForecastSources.nwsPoint(place);
      JSONArray candidates =
          ForecastSources.get(ForecastSources.trustedNWS(point.getString("observationStations")))
              .getJSONArray("features");
      double nearest = 15;
      for (int i = 0; i < candidates.length(); i++) {
        JSONObject row = candidates.getJSONObject(i);
        JSONArray c = row.getJSONObject("geometry").getJSONArray("coordinates");
        float[] distance = new float[1];
        android.location.Location.distanceBetween(
            place.latitude(), place.longitude(), c.getDouble(1), c.getDouble(0), distance);
        String id = row.getJSONObject("properties").getString("stationIdentifier");
        if (distance[0] / 1000 <= nearest && id.matches("[A-Za-z0-9]{1,8}")) {
          nearest = distance[0] / 1000;
          station = new JSONObject().put("id", id).put("distance", nearest);
        }
      }
      if (station == null) throw new java.io.IOException("No nearby independent station");
    }
    if (station.optDouble("distance", 99) > 15)
      throw new java.io.IOException("Station too distant");
    long since = Math.max(now - 7 * 86400, station.optLong("checked", now - 7 * 86400) - 10800);
    String url =
        "https://api.weather.gov/stations/"
            + station.getString("id")
            + "/observations?limit=500&start="
            + WeatherService.encode(Instant.ofEpochSecond(since).toString());
    TreeMap<Long, Double> readings = new TreeMap<>();
    for (int page = 0; page < 4 && url != null; page++) {
      JSONObject response = ForecastSources.get(ForecastSources.trustedNWS(url));
      JSONArray rows = response.getJSONArray("features");
      for (int i = 0; i < rows.length(); i++) {
        JSONObject p = rows.getJSONObject(i).getJSONObject("properties");
        long time = ForecastSources.stamp(p.getString("timestamp"));
        double temp = n(p.optJSONObject("temperature"), "value") * 1.8 + 32;
        if (Double.isFinite(temp)
            && temp >= -130
            && temp <= 150
            && time <= now + 60
            && now - time < 8 * 86400) readings.put(time, temp);
      }
      JSONObject pagination = response.optJSONObject("pagination");
      url = pagination == null ? null : pagination.optString("next", null);
      if (rows.length() == 0) break;
    }
    synchronized (EvidenceStore.class) {
      state = files.read("evidence");
      JSONObject latestStations = state.optJSONObject("stations");
      if (latestStations != null) stations = latestStations;
      JSONArray captures = state.optJSONArray("captures"), samples = state.optJSONArray("samples");
      if (samples == null) samples = new JSONArray();
      JSONArray bounded = new JSONArray();
      for (int i = 0; i < samples.length(); i++) {
        JSONObject row = samples.getJSONObject(i);
        if (now - row.optLong("observed") < 30 * 86400) bounded.put(row);
      }
      JSONArray added =
          verifyHistory(
              captures,
              bounded,
              key,
              readings,
              station.getString("id"),
              station.getDouble("distance"),
              now);
      for (int i = 0; i < added.length(); i++) bounded.put(added.get(i));
      JSONArray limited = new JSONArray();
      for (int i = Math.max(0, bounded.length() - 12000); i < bounded.length(); i++)
        limited.put(bounded.get(i));
      if (!preferences.getBoolean("verifyStations", false)
          || generation != preferences.getInt("evidenceGeneration", 0)) return;
      station.put("checked", now);
      stations.put(key, station);
      state.put("stations", stations).put("samples", limited);
      files.write("evidence", state);
      files.log("Station verification complete");
    }
  }

  static JSONArray verifyHistory(
      JSONArray captures,
      JSONArray existing,
      String place,
      TreeMap<Long, Double> input,
      String station,
      double distance,
      long now)
      throws Exception {
    JSONArray result = new JSONArray();
    if (captures == null || distance < 0 || distance > 15) return result;
    TreeMap<Long, Double> readings = new TreeMap<>();
    for (var entry : input.entrySet())
      if (Double.isFinite(entry.getValue())
          && entry.getValue() >= -130
          && entry.getValue() <= 150
          && entry.getKey() <= now + 60
          && now - entry.getKey() < 8 * 86400) readings.put(entry.getKey(), entry.getValue());
    Set<String> scored = new HashSet<>();
    if (existing != null)
      for (int i = 0; i < existing.length(); i++)
        scored.add(existing.getJSONObject(i).optString("key"));
    for (int i = 0; i < captures.length(); i++) {
      JSONObject capture = captures.getJSONObject(i);
      long target = capture.optLong("target"), issued = capture.optLong("issued");
      if (!capture.optString("place").equals(place)
          || target > now
          || issued <= 0
          || issued > target - 1800
          || !Double.isFinite(n(capture, "temperature"))
          || scored.contains(capture.optString("key"))) continue;
      Long before = readings.floorKey(target),
          after = readings.ceilingKey(target),
          time =
              before == null
                  ? after
                  : after == null
                      ? before
                      : Math.abs(target - before) <= Math.abs(after - target) ? before : after;
      if (time == null || Math.abs(target - time) > 900) continue;
      result.put(
          new JSONObject(capture.toString())
              .put("observed", time)
              .put("station", station)
              .put("distance", distance)
              .put("error", capture.getDouble("temperature") - readings.get(time)));
      scored.add(capture.getString("key"));
    }
    return result;
  }

  String summary() {
    JSONObject state = files.read("evidence");
    JSONArray c = state.optJSONArray("captures"), s = state.optJSONArray("samples");
    return (c == null ? 0 : c.length())
        + " saved forecast hours · "
        + (s == null ? 0 : s.length())
        + " scored temperatures\n"
        + "Weights start from the same stated ranking as iPhone. Measured weights require 20 shared"
        + " hours across 5 days. Single-source temperature switching also requires held-out"
        + " improvement. No accuracy gain is established.";
  }

  void clear() {
    synchronized (EvidenceStore.class) {
      preferences
          .edit()
          .putInt("evidenceGeneration", preferences.getInt("evidenceGeneration", 0) + 1)
          .apply();
      files.remove("evidence");
      preferences.edit().putBoolean("weightsMeasured", false).apply();
    }
  }
}
