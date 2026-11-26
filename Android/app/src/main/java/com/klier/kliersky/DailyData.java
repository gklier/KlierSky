package com.klier.kliersky;

import java.time.*;
import org.json.*;

final class DailyData {
  static int today(JSONObject forecast, ZoneId zone) {
    JSONObject daily = forecast.optJSONObject("daily");
    JSONArray dates = daily == null ? null : daily.optJSONArray("time");
    if (dates == null) return -1;
    LocalDate today = LocalDate.now(zone);
    for (int i = 0; i < dates.length(); i++)
      if (Instant.ofEpochSecond(dates.optLong(i)).atZone(zone).toLocalDate().equals(today))
        return i;
    return -1;
  }
}
