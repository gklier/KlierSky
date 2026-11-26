package com.klier.kliersky;

import android.app.job.*;
import android.content.*;
import java.util.*;
import org.json.*;

/** Opportunistic system scheduling: saved locations only; no background GPS and no enrollment. */
public class WeatherJob extends JobService {
  private java.util.concurrent.ExecutorService worker;
  private volatile boolean stopped;
  static final int PERIODIC = 101, MANUAL = 102;

  static void schedule(Context context) {
    var prefs = context.getSharedPreferences("weather", 0);
    JobScheduler scheduler = context.getSystemService(JobScheduler.class);
    boolean wanted =
        prefs.getBoolean("rainNotifications", false)
            || prefs.getBoolean("backgroundCollection", false)
                && prefs.getBoolean("verifyStations", false)
            || WeatherWidgets.any(context);
    if (!wanted) {
      scheduler.cancel(PERIODIC);
      return;
    }
    JobInfo job =
        new JobInfo.Builder(PERIODIC, new ComponentName(context, WeatherJob.class))
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setRequiresBatteryNotLow(true)
            .setPeriodic(
                prefs.getBoolean("rainNotifications", false) || WeatherWidgets.any(context)
                    ? 30 * 60 * 1000
                    : 3 * 3600 * 1000,
                10 * 60 * 1000)
            .setPersisted(true)
            .build();
    JobInfo previous = scheduler.getPendingJob(PERIODIC);
    if (previous == null || previous.getIntervalMillis() != job.getIntervalMillis())
      scheduler.schedule(job);
  }

  static void request(Context context) {
    JobScheduler scheduler = context.getSystemService(JobScheduler.class);
    if (scheduler.getPendingJob(MANUAL) != null) return;
    scheduler.schedule(
        new JobInfo.Builder(MANUAL, new ComponentName(context, WeatherJob.class))
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setOverrideDeadline(60 * 1000)
            .build());
  }

  @Override
  public boolean onStartJob(JobParameters params) {
    stopped = false;
    worker = java.util.concurrent.Executors.newSingleThreadExecutor();
    worker.execute(
        () -> {
          try {
            var prefs = getSharedPreferences("weather", 0);
            WeatherService service = new WeatherService(this);
            Map<String, WeatherService.Place> places = new LinkedHashMap<>();
            String selected = prefs.getString("selectedPlace", "");
            if (!selected.isEmpty()) {
              var p = WeatherService.Place.parse(new JSONObject(selected));
              places.put(LocalData.placeKey(p), p);
            }
            for (var place : WeatherWidgets.places(this))
              if (places.size() < 5) places.put(LocalData.placeKey(place), place);
            for (var place : places.values()) {
              if (stopped) break;
              try {
                var result = service.load(place, false, false);
                if (!stopped
                    && !selected.isEmpty()
                    && LocalData.placeKey(WeatherService.Place.parse(new JSONObject(selected)))
                        .equals(LocalData.placeKey(place)))
                  RainNotifications.update(this, place, result.forecast());
              } catch (Exception ignored) {
              }
            }
            if (!stopped) {
              WeatherWidgets.updateAll(this);
              new LocalData(this).log("Background refresh");
            }
          } catch (Exception ignored) {
          } finally {
            jobFinished(params, false);
            if (worker != null) worker.shutdown();
          }
        });
    return true;
  }

  @Override
  public boolean onStopJob(JobParameters params) {
    stopped = true;
    if (worker != null) worker.shutdownNow();
    return true;
  }
}
