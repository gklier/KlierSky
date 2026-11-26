package com.klier.kliersky;

import android.content.Context;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import org.json.*;

/**
 * App-private, bounded storage. Diagnostics deliberately omit URLs, credentials and coordinates.
 */
final class LocalData {
  private final File folder;

  LocalData(Context context) {
    folder = context.getFilesDir();
  }

  synchronized JSONObject read(String name) {
    try {
      File file = new File(folder, name + ".json");
      if (file.length() > 8 * 1024 * 1024) return new JSONObject();
      return new JSONObject(
          new String(java.nio.file.Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8));
    } catch (Exception e) {
      return new JSONObject();
    }
  }

  synchronized void write(String name, JSONObject value) {
    try {
      File temp = File.createTempFile(name + "-", ".tmp", folder);
      try (FileOutputStream output = new FileOutputStream(temp)) {
        output.write(value.toString().getBytes(StandardCharsets.UTF_8));
        output.getFD().sync();
      }
      java.nio.file.Files.move(
          temp.toPath(),
          new File(folder, name + ".json").toPath(),
          java.nio.file.StandardCopyOption.REPLACE_EXISTING,
          java.nio.file.StandardCopyOption.ATOMIC_MOVE);
    } catch (Exception ignored) {
    }
  }

  synchronized void remove(String name) {
    new File(folder, name + ".json").delete();
  }

  static String placeKey(WeatherService.Place p) {
    return String.format(Locale.ROOT, "%.3f_%.3f", p.latitude(), p.longitude()).replace('-', 'm');
  }

  synchronized void log(String event) {
    Set<String> allowed =
        new java.util.HashSet<>(
            java.util.Arrays.asList(
                "Forecast updated",
                "Forecast cached",
                "Forecast unavailable",
                "Provider unavailable",
                "Evidence captured",
                "Station verification complete",
                "Station verification unavailable",
                "Station updated",
                "Station unavailable",
                "Owner paired",
                "Access unavailable",
                "Background refresh",
                "Notification scheduled",
                "Notification cancelled"));
    if (!allowed.contains(event)) return;
    try {
      JSONObject value = read("diagnostics");
      JSONArray previous = value.optJSONArray("events"), events = new JSONArray();
      if (previous != null)
        for (int i = Math.max(0, previous.length() - 149); i < previous.length(); i++)
          events.put(previous.get(i));
      events.put(
          new JSONObject().put("time", System.currentTimeMillis() / 1000).put("event", event));
      write("diagnostics", new JSONObject().put("events", events));
    } catch (Exception ignored) {
    }
  }

  String diagnostics() {
    return "KlierSky Android "
        + BuildConfig.VERSION_NAME
        + "\nLocal sanitized diagnostics\n"
        + read("diagnostics").toString();
  }
}
