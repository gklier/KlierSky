package com.klier.kliersky;

import java.util.*;
import org.json.*;

final class WeatherAlerts {
  static boolean covers(WeatherService.Place p) {
    double a = p.latitude(), o = p.longitude();
    double[][] boxes = {
      {24, 49.6, -125.5, -66.5},
      {51, 71.6, -180, -129.5},
      {51, 55.5, 172, 180},
      {18.5, 22.6, -160.8, -154.5},
      {17.5, 18.7, -67.6, -64.4},
      {13, 20.8, 144.4, 146.3},
      {-14.8, -10.8, -171.3, -168}
    };
    for (double[] b : boxes) if (a >= b[0] && a <= b[1] && o >= b[2] && o <= b[3]) return true;
    return false;
  }

  static List<JSONObject> active(JSONArray input, long now) {
    List<JSONObject> found = new ArrayList<>();
    Set<String> ids = new HashSet<>();
    if (input == null) return found;
    for (int i = 0; i < Math.min(60, input.length()); i++) {
      JSONObject row = input.optJSONObject(i),
          p = row == null ? null : row.optJSONObject("properties");
      if (p == null
          || !p.optString("status").equals("Actual")
          || p.optString("messageType").equals("Cancel")
          || p.optString("id").isEmpty()
          || !ids.add(p.optString("id"))) continue;
      String end = p.isNull("ends") ? p.optString("expires", "") : p.optString("ends", "");
      try {
        if (ForecastSources.stamp(end) <= now) continue;
      } catch (Exception ignored) {
      }
      found.add(p);
    }
    List<String> order = Arrays.asList("Extreme", "Severe", "Moderate", "Minor", "Unknown");
    found.sort(
        Comparator.comparingInt(
            p -> {
              int rank = order.indexOf(p.optString("severity"));
              return rank < 0 ? 4 : rank;
            }));
    return found;
  }
}
