package com.klier.kliersky;

import android.os.*;
import java.util.*;
import java.util.function.*;
import org.maplibre.android.maps.Style;
import org.maplibre.android.style.layers.*;
import org.maplibre.android.style.sources.*;

/** At most 14 resident sources, three warming frames, no synchronous file writes on scrubbing. */
final class RadarPlayback {
  final Style style;
  final List<WeatherService.RadarFrame> frames;
  final Consumer<Integer> displayed;
  final Consumer<String> status;
  final Handler handler = new Handler(Looper.getMainLooper());
  final Set<Integer> resident = new HashSet<>();
  String below;
  int target = -1, shown = -1, direction = 1, generation;
  boolean fullyRendered, loading, closed;
  long requested;

  RadarPlayback(
      Style style,
      List<WeatherService.RadarFrame> frames,
      Consumer<Integer> displayed,
      Consumer<String> status) {
    this.style = style;
    this.frames = frames;
    this.displayed = displayed;
    this.status = status;
    for (var layer : style.getLayers())
      if (layer instanceof SymbolLayer) {
        below = layer.getId();
        break;
      }
  }

  void seek(int index) {
    if (closed || frames.isEmpty()) return;
    index = Math.max(0, Math.min(frames.size() - 1, index));
    if (target >= 0 && index != target) direction = index > target ? 1 : -1;
    target = index;
    int token = ++generation;
    requested = SystemClock.uptimeMillis();
    fullyRendered = false;
    loading = target != shown;
    Set<Integer> desired = new HashSet<>();
    for (int i = Math.max(0, index - 6); i <= Math.min(frames.size() - 1, index + 6); i++)
      desired.add(i);
    if (shown >= 0) desired.add(shown);
    for (int old : new HashSet<>(resident))
      if (!desired.contains(old)) {
        style.removeLayer("weather-frame-" + old);
        style.removeSource("weather-frame-" + old);
        resident.remove(old);
      }
    for (int i : desired)
      if (!resident.contains(i)) {
        var frame = frames.get(i);
        TileSet tile = new TileSet("2.1.0", frame.template());
        tile.setMinZoom(frame.forecast() ? 2f : 0f);
        tile.setMaxZoom(7f);
        tile.setAttribution(
            frame.forecast()
                ? "NOAA HRRR · <a href=\"https://mesonet.agron.iastate.edu/GIS/model.phtml\">Iowa"
                      + " Environmental Mesonet</a>"
                : "<a href=\"https://www.rainviewer.com/\">RainViewer</a>");
        String id = "weather-frame-" + i;
        style.addSource(new RasterSource(id, tile, 256));
        RasterLayer layer =
            new RasterLayer(id, id)
                .withProperties(
                    PropertyFactory.rasterOpacity(0f), PropertyFactory.rasterFadeDuration(0f));
        if (below == null) style.addLayer(layer);
        else style.addLayerBelow(layer, below);
        resident.add(i);
      }
    opacity();
    if (loading) {
      status.accept("Loading selected frame…");
      handler.postDelayed(
          () -> {
            if (!closed && generation == token && loading) {
              show();
              status.accept("Some tiles may be unavailable");
            }
          },
          5000);
    } else displayed.accept(shown);
  }

  void opacity() {
    for (int i : resident) {
      RasterLayer layer = style.getLayerAs("weather-frame-" + i);
      if (layer == null) continue;
      int ahead = (i - target) * direction;
      boolean warm = i == target || ahead >= 1 && ahead <= 2;
      layer.setProperties(PropertyFactory.rasterOpacity(i == shown ? .78f : warm ? .004f : 0f));
    }
  }

  void rendered(boolean complete) {
    fullyRendered = complete;
    if (closed || !loading || !complete) return;
    int token = generation;
    handler.postDelayed(
        () -> {
          if (!closed
              && generation == token
              && fullyRendered
              && loading
              && SystemClock.uptimeMillis() - requested >= 180) show();
        },
        200);
  }

  void show() {
    shown = target;
    loading = false;
    opacity();
    displayed.accept(shown);
    status.accept("");
  }

  boolean ready() {
    return !loading;
  }

  void close() {
    closed = true;
    handler.removeCallbacksAndMessages(null);
  }
}
