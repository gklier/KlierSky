package com.klier.kliersky;

import android.app.*;
import android.content.*;
import android.os.Build;
import java.time.*;
import org.json.*;

final class RainNotifications {
  record Plan(long start, long fire, double chance, String source) {}

  static Plan next(JSONObject forecast, long now, int lead, double threshold) throws Exception {
    JSONObject hourly = forecast.getJSONObject("hourly");
    JSONArray times = hourly.getJSONArray("time"),
        rain = hourly.optJSONArray("precipitation"),
        chance = hourly.optJSONArray("precipitation_probability");
    for (int i = 0; i < times.length(); i++) {
      long time = times.optLong(i);
      double r = ForecastSources.number(rain, i), p = ForecastSources.number(chance, i);
      if (time <= now
          || time > now + 43200
          || !Double.isFinite(r)
          || r < .1
          || !Double.isFinite(p)
          || p < threshold) continue;
      if (i > 0
          && time - times.optLong(i - 1) <= 5400
          && ForecastSources.number(rain, i - 1) >= .1
          && ForecastSources.number(chance, i - 1) >= threshold) continue;
      return new Plan(
          time,
          Math.max(now + 5, time - lead * 60L),
          p,
          forecast.optString("_hourlySource", "Forecast"));
    }
    return null;
  }

  static String phase(JSONObject forecast, long time) {
    JSONObject hourly = forecast.optJSONObject("hourly");
    JSONArray times = hourly == null ? null : hourly.optJSONArray("time");
    if (times != null)
      for (int i = 0; i < times.length(); i++)
        if (times.optLong(i) == time) {
          double code = ForecastSources.number(hourly.optJSONArray("weather_code"), i);
          if (!Double.isFinite(code)) return "Precipitation";
          if (code == 56 || code == 57 || code == 66 || code == 67) return "Freezing precipitation";
          if (code >= 71 && code <= 77 || code == 85 || code == 86) return "Snow";
          return code >= 51 ? "Rain" : "Precipitation";
        }
    return "Precipitation";
  }

  static PendingIntent pending(Context context, Intent intent) {
    return PendingIntent.getBroadcast(
        context, 72, intent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
  }

  static void cancel(Context context) {
    context
        .getSystemService(AlarmManager.class)
        .cancel(pending(context, new Intent(context, RainReceiver.class)));
    boolean existed = context.getSharedPreferences("weather", 0).contains("rainPending");
    context.getSharedPreferences("weather", 0).edit().remove("rainPending").apply();
    if (existed) new LocalData(context).log("Notification cancelled");
  }

  static void update(Context context, WeatherService.Place place, JSONObject forecast)
      throws Exception {
    var prefs = context.getSharedPreferences("weather", 0);
    cancel(context);
    if (!prefs.getBoolean("rainNotifications", false)
        || forecast.optBoolean("_cached")
        || System.currentTimeMillis() / 1000 - forecast.optLong("_updated") > 1800
        || !context.getSystemService(NotificationManager.class).areNotificationsEnabled()) return;
    long now = Instant.now().getEpochSecond();
    Plan plan = next(forecast, now, prefs.getInt("rainLead", 15), prefs.getInt("rainChance", 50));
    if (plan == null) return;
    String key = LocalData.placeKey(place) + "|" + plan.start();
    if (key.equals(prefs.getString("rainDelivered", ""))) return;
    String zone = forecast.optString("timezone", ZoneId.systemDefault().getId());
    String time =
        java.time.format.DateTimeFormatter.ofPattern(
                prefs.getBoolean("clock24", false) ? "HH:mm" : "h a")
            .withZone(ZoneId.of(zone))
            .format(Instant.ofEpochSecond(plan.start()));
    Intent intent =
        new Intent(context, RainReceiver.class)
            .putExtra("title", phase(forecast, plan.start()) + " possible around " + time)
            .putExtra(
                "body",
                place.name()
                    + " · "
                    + Math.round(plan.chance())
                    + "% hourly forecast · "
                    + plan.source())
            .putExtra("key", key)
            .putExtra("expires", plan.start() + 3600);
    context
        .getSystemService(AlarmManager.class)
        .setAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP, plan.fire() * 1000, pending(context, intent));
    prefs.edit().putString("rainPending", key).apply();
    new LocalData(context).log("Notification scheduled");
  }

  static void show(Context context, String title, String text) {
    NotificationManager manager = context.getSystemService(NotificationManager.class);
    manager.createNotificationChannel(
        new NotificationChannel("rain", "Rain forecasts", NotificationManager.IMPORTANCE_DEFAULT));
    if (Build.VERSION.SDK_INT >= 33
        && context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
            != android.content.pm.PackageManager.PERMISSION_GRANTED) return;
    PendingIntent launch =
        PendingIntent.getActivity(
            context,
            0,
            new Intent(context, MainActivity.class),
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    Notification notification =
        new Notification.Builder(context, "rain")
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(new Notification.BigTextStyle().bigText(text))
            .setContentIntent(launch)
            .setAutoCancel(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .build();
    manager.notify(72, notification);
  }
}
