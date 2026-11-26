package com.klier.kliersky;

import static org.junit.Assert.*;

import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.os.SystemClock;
import android.view.View;
import android.view.ViewGroup;
import androidx.test.core.app.ActivityScenario;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.uiautomator.*;
import java.io.File;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.maplibre.android.maps.MapView;

/** Exercises real app entry points and captures live forecast screens on Android. */
@RunWith(AndroidJUnit4.class)
public class DesignChecks {
  private final UiDevice device =
      UiDevice.getInstance(InstrumentationRegistry.getInstrumentation());

  private UiObject2 waitFor(BySelector selector) {
    // Wait for the native window entrance animation before using layout coordinates.
    SystemClock.sleep(280);
    UiObject2 view = device.wait(Until.findObject(selector), 45000);
    assertNotNull("Expected visible control: " + selector, view);
    return view;
  }

  private void appearance(String value) {
    waitFor(By.desc("Settings")).click();
    waitFor(By.text("Appearance")).click();
    waitFor(By.desc(value)).click();
    waitFor(By.desc("Done")).click();
    waitFor(By.desc("Settings"));
  }

  private MapView findMap(View view) {
    if (view instanceof MapView) return (MapView) view;
    if (view instanceof ViewGroup) {
      ViewGroup group = (ViewGroup) view;
      for (int i = 0; i < group.getChildCount(); i++) {
        MapView map = findMap(group.getChildAt(i));
        if (map != null) return map;
      }
    }
    return null;
  }

  private void waitForMap(ActivityScenario<MainActivity> scenario) {
    long deadline = SystemClock.elapsedRealtime() + 20000;
    AtomicBoolean ready = new AtomicBoolean();
    while (!ready.get() && SystemClock.elapsedRealtime() < deadline) {
      scenario.onActivity(
          activity -> {
            MapView map = findMap(activity.findViewById(android.R.id.content));
            ready.set(map != null && Boolean.TRUE.equals(map.getTag()));
          });
      if (!ready.get()) SystemClock.sleep(250);
    }
    assertTrue("Map should finish a rendered frame", ready.get());
  }

  private void capture(String filename) {
    File folder =
        new File(
            InstrumentationRegistry.getInstrumentation()
                .getTargetContext()
                .getExternalFilesDir(null),
            "design-checks");
    folder.mkdirs();
    SystemClock.sleep(280);
    assertTrue(device.takeScreenshot(new File(folder, filename)));
  }

  @Test
  public void liveForecastThemesAndHourlyControls() throws Exception {
    var context = InstrumentationRegistry.getInstrumentation().getTargetContext();
    // Permission and city selection are isolated to this development emulator.
    context.getSharedPreferences("weather", 0).edit().putBoolean("useCurrent", false).apply();
    try (ActivityScenario<MainActivity> scenario = ActivityScenario.launch(MainActivity.class)) {
      waitFor(By.desc("Search and saved locations")).click();
      waitFor(By.text("Search for a city")).click();
      waitFor(By.clazz("android.widget.EditText")).setText("Seattle");
      waitFor(By.text(java.util.regex.Pattern.compile("(?i)search"))).click();
      waitFor(By.textStartsWith("Seattle,").hasAncestor(By.clazz("android.widget.ScrollView")))
          .click();
      waitFor(By.text("Hourly"));
      appearance("Light");
      waitForMap(scenario);
      scenario.onActivity(
          activity -> {
            ViewGroup root = activity.findViewById(android.R.id.content);
            assertEquals(
                Color.rgb(252, 253, 254),
                ((ColorDrawable) root.getChildAt(0).getBackground()).getColor());
          });
      capture("forecast-light.png");
      waitFor(By.desc("Hourly metric Humidity")).click();
      assertTrue(device.hasObject(By.text(java.util.regex.Pattern.compile("[0-9]+%"))));
      waitFor(By.text("Show 24 hours")).click();
      waitFor(By.text("Show 6 hours"));
      waitFor(By.text("Show 6 hours")).click();
      waitFor(By.text("Show 24 hours"));
      appearance("Dark");
      waitForMap(scenario);
      scenario.onActivity(
          activity -> {
            ViewGroup root = activity.findViewById(android.R.id.content);
            assertEquals(
                Color.rgb(10, 13, 17),
                ((ColorDrawable) root.getChildAt(0).getBackground()).getColor());
          });
      capture("forecast-dark.png");
      waitFor(By.desc("Hourly metric Temp")).click();
      device.waitForIdle();
      capture("forecast-dark-temperature.png");
      device.swipe(550, 1700, 550, 600, 25);
      device.waitForIdle();
      capture("forecast-details-dark.png");
      appearance("Light");
      waitForMap(scenario);
      capture("forecast-switched-light.png");
    }
  }

  @Test
  public void iphoneStyleSettingsAndAnchoredMenus() throws Exception {
    try (ActivityScenario<MainActivity> scenario = ActivityScenario.launch(MainActivity.class)) {
      appearance("Light");
      var context = InstrumentationRegistry.getInstrumentation().getTargetContext();
      var prefs = context.getSharedPreferences("weather", 0);
      waitFor(By.desc("Settings")).click();
      waitFor(By.text("Appearance & units"));
      capture("settings-sheet-light.png");
      waitFor(By.text("Appearance")).click();
      waitFor(By.desc("Dark"));
      capture("appearance-sheet-light.png");
      waitFor(By.desc("Dark")).click();
      assertEquals(2, prefs.getInt("appearance", 0));
      waitFor(By.desc("Done"));
      capture("settings-sheet-dark.png");
      waitFor(By.text("Appearance")).click();
      waitFor(By.desc("Light"));
      capture("appearance-sheet-dark.png");
      waitFor(By.desc("Light")).click();
      assertEquals(1, prefs.getInt("appearance", 0));
      waitFor(By.text("Temperature & wind")).click();
      waitFor(By.desc("°C · km/h"));
      capture("units-sheet-light.png");
      waitFor(By.desc("°C · km/h")).click();
      assertTrue(prefs.getBoolean("celsius", false));
      waitFor(By.text("Rain")).click();
      waitFor(By.desc("Inches")).click();
      assertTrue(prefs.getBoolean("rainInches", false));
      waitFor(By.text("Temperature & wind")).click();
      waitFor(By.desc("°F · mph")).click();
      assertFalse(prefs.getBoolean("celsius", true));
      // Rain units are independent of the temperature setting.
      assertTrue(prefs.getBoolean("rainInches", false));
      boolean oldClock = prefs.getBoolean("clock24", false);
      waitFor(By.desc("24-hour clock")).click();
      assertEquals(!oldClock, prefs.getBoolean("clock24", false));
      waitFor(By.desc("24-hour clock")).click();
      waitFor(By.text("When KlierSky opens")).click();
      waitFor(By.desc("Last chosen city")).click();
      assertFalse(prefs.getBoolean("useCurrent", true));
      waitFor(By.text("Administration")).click();
      if (!device.hasObject(By.text("Foreca service access"))) {
        new UiScrollable(new UiSelector().scrollable(true))
            .scrollTextIntoView("Foreca service access");
      }
      waitFor(By.text("Foreca service access"));
      capture("administration-sheet-light.png");
      waitFor(By.text("Foreca service access")).click();
      waitFor(By.textStartsWith("Your provider key stays on the server."));
      waitFor(By.desc("Back")).click();
      waitFor(By.text("Foreca service access"));
      device.pressBack();
      waitFor(By.text("Appearance & units"));
      waitFor(By.desc("Done")).click();
      waitFor(By.desc("Settings")).click();
      waitFor(By.text("Appearance & units"));
      device.pressBack();
      assertTrue(device.wait(Until.gone(By.desc("Done")), 3000));
    }
  }
}
