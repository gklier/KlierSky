package com.klier.kliersky;

import java.time.*;
import org.json.*;

final class HistoryArchive {
  static JSONObject fetch(WeatherService.Place place, String start, String end, String zone)
      throws Exception {
    return ForecastSources.get(
            "https://archive-api.open-meteo.com/v1/archive?"
                + ForecastSources.point(place)
                + "&start_date="
                + start
                + "&end_date="
                + end
                + "&daily=temperature_2m_max,temperature_2m_min,temperature_2m_mean&temperature_unit=fahrenheit&timezone="
                + WeatherService.encode(zone)
                + "&models=era5")
        .getJSONObject("daily");
  }

  static JSONObject comparison(
      android.content.Context context, WeatherService.Place place, LocalDate date, String zone)
      throws Exception {
    LocalData files = new LocalData(context);
    String key = "baseline-" + LocalData.placeKey(place);
    JSONObject baseline = files.read(key);
    if (!baseline.has("time")) {
      baseline = fetch(place, "1991-01-01", "2020-12-31", zone);
      files.write(key, baseline);
    }
    String monthDay = date.toString().substring(5);
    JSONArray times = baseline.getJSONArray("time");
    double high = 0, low = 0;
    int count = 0;
    for (int i = 0; i < times.length(); i++) {
      if (!times.getString(i).endsWith(monthDay)) continue;
      double h = ForecastSources.number(baseline.optJSONArray("temperature_2m_max"), i),
          l = ForecastSources.number(baseline.optJSONArray("temperature_2m_min"), i);
      if (Double.isFinite(h) && Double.isFinite(l)) {
        count++;
        high += h;
        low += l;
      }
    }
    String last = date.minusYears(1).toString();
    JSONObject previous = fetch(place, last, last, zone);
    JSONObject result =
        new JSONObject().put("samples", count).put("lastDate", last).put("last", previous);
    ForecastSources.put(result, "high", count >= 20 ? high / count : Double.NaN);
    ForecastSources.put(result, "low", count >= 20 ? low / count : Double.NaN);
    return result;
  }
}
