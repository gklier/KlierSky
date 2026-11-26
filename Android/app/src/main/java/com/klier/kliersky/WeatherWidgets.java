package com.klier.kliersky;

import android.app.*;
import android.appwidget.*;
import android.content.*;
import android.graphics.Color;
import android.view.View;
import android.widget.RemoteViews;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.*;
import org.json.*;

public class WeatherWidgets extends AppWidgetProvider {
  static Class<?>[] types() {
    return new Class<?>[] {WeatherWidgets.class, HourlyWidget.class, DailyWidget.class};
  }

  static boolean any(Context context) {
    for (Class<?> type : types())
      if (AppWidgetManager.getInstance(context)
              .getAppWidgetIds(new ComponentName(context, type))
              .length
          > 0) return true;
    return false;
  }

  @Override
  public void onUpdate(Context context, AppWidgetManager manager, int[] ids) {
    updateAll(context);
    WeatherJob.schedule(context);
    WeatherJob.request(context);
  }

  @Override
  public void onAppWidgetOptionsChanged(
      Context context, AppWidgetManager manager, int id, android.os.Bundle options) {
    updateAll(context);
  }

  @Override
  public void onDeleted(Context context, int[] ids) {
    var prefs = context.getSharedPreferences("weather", 0).edit();
    for (int id : ids) prefs.remove("widget-" + id);
    prefs.apply();
    WeatherJob.schedule(context);
  }

  @Override
  public void onReceive(Context context, Intent intent) {
    super.onReceive(context, intent);
    if ("com.klier.kliersky.WIDGET_REFRESH".equals(intent.getAction())) {
      updateAll(context);
      WeatherJob.request(context);
    }
  }

  static WeatherService.Place widgetPlace(
      android.content.SharedPreferences prefs, JSONObject record) throws Exception {
    if (record.optBoolean("followCurrent", false)) {
      String gps = prefs.getString("lastGPSPlace", "");
      if (!gps.isEmpty()) return WeatherService.Place.parse(new JSONObject(gps));
    }
    return WeatherService.Place.parse(record.has("place") ? record.getJSONObject("place") : record);
  }

  static List<WeatherService.Place> places(Context context) {
    List<WeatherService.Place> places = new ArrayList<>();
    var prefs = context.getSharedPreferences("weather", 0);
    for (Class<?> type : types())
      for (int id :
          AppWidgetManager.getInstance(context).getAppWidgetIds(new ComponentName(context, type))) {
        try {
          String stored =
              prefs.getString(
                  "widget-" + id,
                  prefs.getString("lastGPSPlace", prefs.getString("selectedPlace", "")));
          if (!stored.isEmpty()) {
            JSONObject json = new JSONObject(stored);
            places.add(widgetPlace(prefs, json));
          }
        } catch (Exception ignored) {
        }
      }
    return places;
  }

  static String temperature(double value, boolean celsius) {
    return Double.isFinite(value) ? Math.round(celsius ? (value - 32) / 1.8 : value) + "°" : "—";
  }

  static void updateAll(Context context) {
    AppWidgetManager manager = AppWidgetManager.getInstance(context);
    var prefs = context.getSharedPreferences("weather", 0);
    LocalData files = new LocalData(context);
    for (int kind = 0; kind < types().length; kind++)
      for (int id : manager.getAppWidgetIds(new ComponentName(context, types()[kind]))) {
        RemoteViews view = new RemoteViews(context.getPackageName(), R.layout.weather_widget);
        boolean dark =
            prefs.getInt("appearance", 0) == 2
                || prefs.getInt("appearance", 0) == 0
                    && (context.getResources().getConfiguration().uiMode & 48) == 32;
        int ink = dark ? Color.WHITE : 0xff17212b, muted = dark ? 0xffb7c5ce : 0xff5f6c78;
        view.setInt(
            R.id.widget_root,
            "setBackgroundResource",
            dark ? R.drawable.widget_dark : R.drawable.widget_light);
        for (int text :
            new int[] {
              R.id.widget_city, R.id.widget_temperature, R.id.widget_body, R.id.widget_source
            }) view.setTextColor(text, text == R.id.widget_source ? muted : ink);
        String targetPlace = "";
        boolean followCurrent = false;
        try {
          String stored =
              prefs.getString(
                  "widget-" + id,
                  prefs.getString("lastGPSPlace", prefs.getString("selectedPlace", "")));
          JSONObject configuration = new JSONObject(stored);
          WeatherService.Place place = widgetPlace(prefs, configuration);
          targetPlace = place.json().toString();
          followCurrent = configuration.optBoolean("followCurrent", !configuration.has("place"));
          boolean celsius = configuration.optBoolean("celsius", prefs.getBoolean("celsius", false));
          JSONObject saved = files.read("forecast-" + LocalData.placeKey(place)),
              forecast = saved.optJSONObject("forecast");
          view.setTextViewText(R.id.widget_city, place.name());
          if (forecast == null) {
            view.setTextViewText(R.id.widget_temperature, "—");
            view.setTextViewText(R.id.widget_body, "Open KlierSky to load this forecast");
            view.setTextViewText(R.id.widget_source, "Waiting for a forecast");
          } else {
            JSONObject current = forecast.optJSONObject("current");
            view.setTextViewText(
                R.id.widget_temperature,
                temperature(ForecastSources.number(current, "temperature_2m"), celsius));
            StringBuilder body = new StringBuilder();
            String source;
            int height =
                manager
                    .getAppWidgetOptions(id)
                    .getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, kind == 2 ? 250 : 200);
            float scale = context.getResources().getConfiguration().fontScale;
            int rows =
                Math.max(1, Math.min(kind == 2 ? 7 : 6, (int) ((height - 88) / (21 * scale))));
            ZoneId zone;
            try {
              zone = ZoneId.of(forecast.optString("timezone", ZoneId.systemDefault().getId()));
            } catch (Exception e) {
              zone = ZoneId.systemDefault();
            }
            if (kind == 0) {
              source = forecast.optString("_currentSource", saved.optString("source"));
              body.append("Feels ")
                  .append(
                      temperature(
                          ForecastSources.number(current, "apparent_temperature"), celsius));
              double weather = ForecastSources.number(current, "weather_code");
              int code = Double.isFinite(weather) ? (int) weather : -1;
              body.append("\n").append(MainActivity.condition(code));
              JSONObject daily = forecast.optJSONObject("daily");
              int today = DailyData.today(forecast, zone);
              if (daily != null && today >= 0)
                body.append("\nHigh ")
                    .append(
                        temperature(
                            ForecastSources.number(daily.optJSONArray("temperature_2m_max"), today),
                            celsius))
                    .append(" · Low ")
                    .append(
                        temperature(
                            ForecastSources.number(daily.optJSONArray("temperature_2m_min"), today),
                            celsius));
              double humidity = ForecastSources.number(current, "relative_humidity_2m");
              if (Double.isFinite(humidity))
                body.append(" · ").append(Math.round(humidity)).append("% humidity");
            } else if (kind == 1) {
              source = forecast.optString("_hourlySource", saved.optString("source"));
              JSONObject h = forecast.getJSONObject("hourly");
              JSONArray times = h.getJSONArray("time");
              int count = 0;
              for (int i = 0; i < times.length() && count < rows; i++) {
                if (times.optLong(i) < System.currentTimeMillis() / 1000 - 1800) continue;
                if (count++ > 0) body.append('\n');
                body.append(
                        DateTimeFormatter.ofPattern(
                                prefs.getBoolean("clock24", false) ? "HH:mm" : "ha")
                            .withZone(zone)
                            .format(Instant.ofEpochSecond(times.optLong(i))))
                    .append("    ")
                    .append(
                        temperature(
                            ForecastSources.number(h.optJSONArray("temperature_2m"), i), celsius));
                double chance =
                    ForecastSources.number(h.optJSONArray("precipitation_probability"), i);
                if (Double.isFinite(chance))
                  body.append("    ").append(Math.round(chance)).append("% precip");
              }
            } else {
              source = forecast.optString("_dailySource", saved.optString("source"));
              JSONObject d = forecast.optJSONObject("daily");
              if (d != null) {
                JSONArray days = d.getJSONArray("time");
                int count = 0;
                java.time.LocalDate today = java.time.LocalDate.now(zone);
                for (int i = 0; i < days.length() && count < rows; i++) {
                  java.time.LocalDate date =
                      java.time.Instant.ofEpochSecond(days.optLong(i)).atZone(zone).toLocalDate();
                  if (date.isBefore(today)) continue;
                  if (count++ > 0) body.append('\n');
                  body.append(
                          date.equals(today)
                              ? "Today"
                              : date.format(DateTimeFormatter.ofPattern("EEE")))
                      .append("    ")
                      .append(
                          temperature(
                              ForecastSources.number(d.optJSONArray("temperature_2m_min"), i),
                              celsius))
                      .append(" / ")
                      .append(
                          temperature(
                              ForecastSources.number(d.optJSONArray("temperature_2m_max"), i),
                              celsius));
                }
              }
            }
            view.setTextViewText(R.id.widget_body, body.toString());
            view.setViewVisibility(R.id.widget_temperature, kind == 0 ? View.VISIBLE : View.GONE);
            long age =
                Math.max(0, System.currentTimeMillis() / 1000 - forecast.optLong("_updated"));
            view.setTextViewText(
                R.id.widget_source,
                source
                    + " · "
                    + "Updated "
                    + DateTimeFormatter.ofPattern(
                            prefs.getBoolean("clock24", false) ? "MMM d HH:mm" : "MMM d h:mm a")
                        .withZone(zone)
                        .format(Instant.ofEpochSecond(forecast.optLong("_updated")))
                    + (age > 21600 ? " · Saved" : ""));
          }
        } catch (Exception e) {
          view.setTextViewText(R.id.widget_city, "KlierSky");
          view.setTextViewText(R.id.widget_temperature, "—");
          view.setTextViewText(R.id.widget_body, "Open KlierSky and choose a location");
          view.setTextViewText(R.id.widget_source, "No forecast yet");
        }
        Intent launch =
            new Intent(context, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra("widgetPlace", targetPlace)
                .putExtra("widgetFollowCurrent", followCurrent);
        view.setOnClickPendingIntent(
            R.id.widget_root,
            PendingIntent.getActivity(
                context,
                id,
                launch,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
        manager.updateAppWidget(id, view);
      }
  }
}
