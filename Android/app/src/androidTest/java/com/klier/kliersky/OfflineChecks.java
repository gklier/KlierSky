package com.klier.kliersky;

import static org.junit.Assert.*;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.uiautomator.UiDevice;
import org.junit.Test;
import org.junit.runner.RunWith;

@RunWith(AndroidJUnit4.class)
public class OfflineChecks {
  @Test
  public void savedForecastRetainsOriginalTimestampAndProvenance() throws Exception {
    var context = InstrumentationRegistry.getInstrumentation().getTargetContext();
    var device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation());
    var place = new WeatherService.Place("Seattle, Washington", 47.6062, -122.3321);
    var service = new WeatherService(context);
    var before =
        new LocalData(context)
            .read("forecast-" + LocalData.placeKey(place))
            .getJSONObject("forecast");
    try {
      device.executeShellCommand("cmd connectivity airplane-mode enable");
      device.executeShellCommand("svc wifi disable");
      android.os.SystemClock.sleep(1200);
      var saved = service.load(place, true, false).forecast();
      assertTrue(saved.optBoolean("_cached"));
      assertEquals(before.getLong("_updated"), saved.getLong("_updated"));
      assertEquals(before.getString("_hourlySource"), saved.getString("_hourlySource"));
      assertEquals(
          before.getJSONObject("hourly").getJSONArray("time").getLong(0),
          saved.getJSONObject("hourly").getJSONArray("time").getLong(0));
    } finally {
      device.executeShellCommand("cmd connectivity airplane-mode disable");
      device.executeShellCommand("svc wifi enable");
    }
  }
}
