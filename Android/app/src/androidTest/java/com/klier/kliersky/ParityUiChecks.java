package com.klier.kliersky;

import static org.junit.Assert.*;

import android.app.*;
import android.appwidget.*;
import android.content.*;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Rect;
import android.os.*;
import android.view.*;
import android.widget.*;
import androidx.test.core.app.ActivityScenario;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.uiautomator.*;
import java.io.File;
import java.util.*;
import java.util.concurrent.atomic.*;
import org.json.*;
import org.junit.*;
import org.junit.runner.RunWith;

@RunWith(AndroidJUnit4.class)
public class ParityUiChecks {
  final Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
  final UiDevice device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation());
  final WeatherService.Place place =
      new WeatherService.Place("Seattle, Washington", 47.6062, -122.3321);

  UiObject2 waitFor(BySelector selector) {
    SystemClock.sleep(280);
    UiObject2 found = device.wait(Until.findObject(selector), 60000);
    assertNotNull("Missing control " + selector, found);
    return found;
  }

  void scrollTo(String text) throws Exception {
    UiObject2 visible = device.findObject(By.text(text));
    if (visible != null && !visible.getVisibleBounds().isEmpty()) return;
    new UiScrollable(new UiSelector().scrollable(true)).scrollTextIntoView(text);
  }

  void capture(String name) throws Exception {
    SystemClock.sleep(400);
    File folder = new File(context.getExternalFilesDir(null), "parity-checks");
    folder.mkdirs();
    assertTrue(device.takeScreenshot(new File(folder, name)));
  }

  void fixedLocation() throws Exception {
    context
        .getSharedPreferences("weather", 0)
        .edit()
        .putBoolean("useCurrent", false)
        .putString("selectedPlace", place.json().toString())
        .putInt("appearance", 1)
        .putString("forecastMode", "blend")
        .apply();
  }

  @Test
  public void observedToRealFuturecastAndDailyMetrics() throws Exception {
    fixedLocation();
    try (ActivityScenario<MainActivity> scenario = ActivityScenario.launch(MainActivity.class)) {
      waitFor(By.text("Hourly"));
      waitFor(By.text("Expand")).click();
      waitFor(By.text("Return to forecast"));
      UiObject2 slider = waitFor(By.clazz("android.widget.SeekBar"));
      Rect bounds = slider.getVisibleBounds();
      device.click(bounds.right - 18, bounds.centerY());
      waitFor(By.textStartsWith("Model forecast "));
      waitFor(By.textContains("simulated reflectivity"));
      capture("futurecast-map.png");
      waitFor(By.text("Return to forecast")).click();
      scrollTo("Daily");
      UiObject2 day = waitFor(By.descContains("daily forecast details"));
      day.click();
      waitFor(By.text("Daily forecast"));
      waitFor(By.text("UV index"));
      capture("daily-detail.png");
      scrollTo("Explore hourly statistics");
      device.waitForIdle();
      UiObject2 hourlyAction = waitFor(By.text("Explore hourly statistics")).getParent();
      hourlyAction.click();
      if (!device.wait(Until.hasObject(By.text("Hourly forecast")), 2000)) {
        waitFor(By.text("Explore hourly statistics")).getParent().click();
      }
      waitFor(By.text("Hourly forecast"));
      capture("hourly-statistics.png");
    }
    var frames = RadarTimeline.future(place);
    for (int i : new int[] {0, frames.size() - 1}) {
      String url =
          frames.get(i).template().replace("{z}", "5").replace("{x}", "5").replace("{y}", "11");
      java.net.HttpURLConnection connection =
          (java.net.HttpURLConnection) new java.net.URL(url).openConnection();
      connection.setConnectTimeout(10000);
      connection.setReadTimeout(10000);
      try {
        assertEquals(200, connection.getResponseCode());
        try (var input = connection.getInputStream()) {
          Bitmap tile = BitmapFactory.decodeStream(input);
          assertNotNull("Real model tile should decode", tile);
          assertEquals(256, tile.getWidth());
          tile.recycle();
        }
      } finally {
        connection.disconnect();
      }
    }
  }

  @Test
  public void realHistoryAndSettingsFeatureEntryPoints() throws Exception {
    fixedLocation();
    Intent history =
        new Intent(context, FeatureActivity.class)
            .putExtra("feature", "history")
            .putExtra("place", place.json().toString());
    try (ActivityScenario<FeatureActivity> scenario = ActivityScenario.launch(history)) {
      waitFor(By.text("1991–2020 high / low"));
      capture("history-comparison.png");
      scrollTo("Load selected day");
      waitFor(By.text("Load selected day")).click();
      waitFor(By.text("Reload selected day"));
      scrollTo("Mean");
      UiObject2 mean = waitFor(By.text("Mean"));
      assertFalse(mean.getParent().getChildren().get(1).getText().equals("—"));
      capture("history-past-day.png");
    }
    try (ActivityScenario<MainActivity> scenario = ActivityScenario.launch(MainActivity.class)) {
      waitFor(By.desc("Settings")).click();
      waitFor(By.text("Notifications")).click();
      waitFor(By.text("Rain forecasts"));
      waitFor(By.text("Send a test notification")).click();
      SystemClock.sleep(400);
      boolean delivered = false;
      for (var notification :
          context.getSystemService(NotificationManager.class).getActiveNotifications())
        if ("KlierSky test"
            .contentEquals(
                notification
                    .getNotification()
                    .extras
                    .getCharSequence(android.app.Notification.EXTRA_TITLE, ""))) delivered = true;
      assertTrue("Test notification should reach the Android manager", delivered);
      capture("notification-settings.png");
      waitFor(By.desc("Back")).click();
      waitFor(By.text("My weather station")).click();
      waitFor(By.text("Station ID"));
      waitFor(By.text("Personal access token"));
      waitFor(By.desc("Back")).click();
      waitFor(By.text("Administration")).click();
      waitFor(By.text("Forecast sources")).click();
      waitFor(By.text("Forecast mode"));
      capture("forecast-sources.png");
      waitFor(By.desc("Back")).click();
      scrollTo("Adaptive weather");
      waitFor(By.text("Adaptive weather")).click();
      waitFor(By.text("Local evidence"));
      capture("adaptive-evidence.png");
      waitFor(By.desc("Back")).click();
      scrollTo("Server & family access");
      waitFor(By.text("Server & family access")).click();
      waitFor(By.text("One-time pairing code"));
      waitFor(By.text("Pair as owner"));
      waitFor(By.desc("Back")).click();
    }
  }

  @Test
  public void nativeWidgetInflationUsesRealCacheAndIndependentUnits() throws Exception {
    fixedLocation();
    context.getSharedPreferences("weather", 0).edit().putBoolean("celsius", true).apply();
    WeatherService service = new WeatherService(context);
    if (!new LocalData(context).read("forecast-" + LocalData.placeKey(place)).has("forecast"))
      service.load(place, false, false);
    AppWidgetManager manager = AppWidgetManager.getInstance(context);
    AppWidgetHost host = new AppWidgetHost(context, 4421);
    List<Integer> ids = new ArrayList<>();
    List<AppWidgetHostView> views = new ArrayList<>();
    AtomicReference<Throwable> failure = new AtomicReference<>();
    try {
      InstrumentationRegistry.getInstrumentation()
          .runOnMainSync(
              () -> {
                try {
                  host.startListening();
                  for (Class<?> type : WeatherWidgets.types()) {
                    int id = host.allocateAppWidgetId();
                    ids.add(id);
                    assertTrue(
                        "Widget bind permission must be granted to this development emulator",
                        manager.bindAppWidgetIdIfAllowed(id, new ComponentName(context, type)));
                    context
                        .getSharedPreferences("weather", 0)
                        .edit()
                        .putString(
                            "widget-" + id,
                            new JSONObject()
                                .put("place", place.json())
                                .put("celsius", false)
                                .toString())
                        .apply();
                    views.add(host.createView(context, id, manager.getAppWidgetInfo(id)));
                  }
                  WeatherWidgets.updateAll(context);
                } catch (Throwable t) {
                  failure.set(t);
                }
              });
      if (failure.get() != null) throw new AssertionError(failure.get());
      long deadline = SystemClock.elapsedRealtime() + 8000;
      AtomicBoolean ready = new AtomicBoolean();
      while (!ready.get() && SystemClock.elapsedRealtime() < deadline) {
        SystemClock.sleep(150);
        InstrumentationRegistry.getInstrumentation()
            .runOnMainSync(
                () -> {
                  boolean all = true;
                  for (var view : views) {
                    TextView source = view.findViewById(R.id.widget_source);
                    if (source == null || !source.getText().toString().contains("Updated"))
                      all = false;
                  }
                  ready.set(all);
                });
      }
      assertTrue("All three widgets should inflate their real forecast", ready.get());
      InstrumentationRegistry.getInstrumentation()
          .runOnMainSync(
              () -> {
                TextView temperature = views.get(0).findViewById(R.id.widget_temperature);
                JSONObject forecast =
                    new LocalData(context)
                        .read("forecast-" + LocalData.placeKey(place))
                        .optJSONObject("forecast");
                assertEquals(
                    WeatherWidgets.temperature(
                        ForecastSources.number(forecast.optJSONObject("current"), "temperature_2m"),
                        false),
                    temperature.getText().toString());
              });
    } finally {
      InstrumentationRegistry.getInstrumentation()
          .runOnMainSync(
              () -> {
                for (int id : ids) host.deleteAppWidgetId(id);
                host.stopListening();
              });
    }
  }

  @Test
  public void widgetPinAndLauncherIcon() throws Exception {
    fixedLocation();
    Intent widgets =
        new Intent(context, FeatureActivity.class)
            .putExtra("feature", "widgets")
            .putExtra("place", place.json().toString());
    try (ActivityScenario<FeatureActivity> scenario = ActivityScenario.launch(widgets)) {
      waitFor(By.text("Current conditions")).click();
      UiObject2 add =
          device.wait(
              Until.findObject(
                  By.text(java.util.regex.Pattern.compile("(?i)add(?: to home screen)?"))),
              10000);
      assertNotNull("Launcher should offer the widget pin confirmation", add);
      add.click();
      device.pressHome();
      waitFor(By.textStartsWith("Seattle"));
      capture("widget-home-screen.png");
    }
  }
}
