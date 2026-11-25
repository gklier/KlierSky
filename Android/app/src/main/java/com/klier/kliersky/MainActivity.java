package com.klier.kliersky;

import android.Manifest;
import android.app.Activity;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.res.ColorStateList;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.widget.*;
import android.widget.FrameLayout;
import java.time.Instant;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.json.JSONArray;
import org.json.JSONObject;
import org.maplibre.android.MapLibre;
import org.maplibre.android.annotations.MarkerOptions;
import org.maplibre.android.camera.CameraPosition;
import org.maplibre.android.geometry.LatLng;
import org.maplibre.android.maps.MapLibreMap;
import org.maplibre.android.maps.MapView;
import org.maplibre.android.maps.Style;
import org.maplibre.android.style.layers.PropertyFactory;
import org.maplibre.android.style.layers.RasterLayer;
import org.maplibre.android.style.sources.RasterSource;
import org.maplibre.android.style.sources.TileSet;

public class MainActivity extends Activity {
  private final ExecutorService worker = Executors.newSingleThreadExecutor();
  private final Handler handler = new Handler(Looper.getMainLooper());
  private SharedPreferences preferences;
  private WeatherService service;
  private WeatherService.Place place;
  private WeatherService.Result result;
  private LinearLayout content;
  private MapView mapView;
  private MapLibreMap map;
  private Style mapStyle;
  private TextView status;
  private TextView frameLabel;
  private SeekBar radarSlider;
  private Button radarPlayButton;
  private LinearLayout hourlyContent;
  private String hourlyMetric = "Temp";
  private long updatedSeconds;
  private boolean dark, celsius, expanded, savedMap, playing;
  private int foreground, muted, surface, accent, frameIndex, requestGeneration;
  private boolean started, resumed;
  private LocationManager locationManager;
  private LocationListener locationListener;
  private final Runnable play =
      new Runnable() {
        @Override
        public void run() {
          if (!playing || result == null || result.radar().isEmpty()) return;
          showFrame((frameIndex + 1) % result.radar().size());
          handler.postDelayed(this, 800);
        }
      };

  @Override
  public void onCreate(Bundle state) {
    super.onCreate(state);
    MapLibre.getInstance(this);
    preferences = getSharedPreferences("weather", MODE_PRIVATE);
    service = new WeatherService(this);
    place = new WeatherService.Place("Milwaukee", 43.0389, -87.9065);
    String saved = preferences.getString("selectedPlace", "");
    if (!saved.isEmpty())
      try {
        place = WeatherService.Place.parse(new JSONObject(saved));
      } catch (Exception ignored) {
      }
    render();
    if (preferences.getBoolean("useCurrent", true)) useCurrent();
    else refresh();
  }

  private int dp(int value) {
    return Math.round(value * getResources().getDisplayMetrics().density);
  }

  private TextView text(String value, int size, boolean bold) {
    TextView view = new TextView(this);
    view.setText(value);
    view.setTextSize(size);
    view.setTextColor(foreground);
    view.setIncludeFontPadding(false);
    view.setTypeface(Typeface.create("sans-serif", bold ? Typeface.BOLD : Typeface.NORMAL));
    return view;
  }

  private GradientDrawable roundedBackground(int color, int radius) {
    GradientDrawable shape = new GradientDrawable();
    shape.setColor(color);
    shape.setCornerRadius(dp(radius));
    return shape;
  }

  private int hairline() {
    return dark ? Color.rgb(42, 46, 52) : Color.rgb(226, 231, 235);
  }

  private int secondarySurface() {
    return dark ? Color.rgb(25, 29, 35) : Color.rgb(240, 243, 246);
  }

  private Button button(String title, Runnable action) {
    Button button = new Button(this);
    button.setText(title);
    button.setTextSize(13);
    button.setTextColor(accent);
    button.setAllCaps(false);
    button.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
    button.setPadding(dp(10), 0, dp(10), 0);
    button.setMinimumHeight(0);
    button.setMinHeight(0);
    button.setMinimumWidth(0);
    button.setMinWidth(0);
    button.setStateListAnimator(null);
    button.setBackground(
        new RippleDrawable(
            ColorStateList.valueOf(dark ? 0x223b98ce : 0x180076aa),
            roundedBackground(Color.TRANSPARENT, 18),
            null));
    button.setOnClickListener(view -> action.run());
    return button;
  }

  private View actionIcon(String kind, String label, Runnable action) {
    WeatherGraphics.Action view = new WeatherGraphics.Action(this, kind, foreground);
    GradientDrawable background = roundedBackground(secondarySurface(), 24);
    background.setStroke(dp(1), hairline());
    view.setBackground(new RippleDrawable(ColorStateList.valueOf(0x226a9abb), background, null));
    view.setOnClickListener(v -> action.run());
    view.setContentDescription(label);
    view.setLayoutParams(new LinearLayout.LayoutParams(dp(44), dp(44)));
    return view;
  }

  private void gap(int height) {
    content.addView(new View(this), new LinearLayout.LayoutParams(1, dp(height)));
  }

  private void heading(String value) {
    TextView view = text(value, 20, true);
    view.setPadding(0, dp(23), 0, dp(12));
    content.addView(view);
  }

  private void note(String value) {
    if (value == null || value.isEmpty()) return;
    TextView view = text(value, 11, false);
    view.setTextColor(muted);
    view.setLineSpacing(dp(2), 1);
    view.setPadding(0, dp(8), 0, dp(4));
    content.addView(view);
  }

  private void row(String left, String right) {
    LinearLayout row = new LinearLayout(this);
    row.setGravity(Gravity.CENTER_VERTICAL);
    TextView label = text(left, 14, false);
    row.addView(label, new LinearLayout.LayoutParams(0, dp(36), 1));
    TextView value = text(right, 14, true);
    value.setGravity(Gravity.END);
    row.addView(value);
    content.addView(row);
  }

  private void disposeMap() {
    if (mapView == null) return;
    if (resumed) mapView.onPause();
    if (started) mapView.onStop();
    mapView.onDestroy();
    mapView = null;
    map = null;
    mapStyle = null;
    radarSlider = null;
    radarPlayButton = null;
  }

  private void render() {
    playing = false;
    handler.removeCallbacks(play);
    disposeMap();
    celsius = preferences.getBoolean("celsius", false);
    int appearance = preferences.getInt("appearance", 0);
    dark =
        appearance == 2
            || appearance == 0
                && (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK)
                    == Configuration.UI_MODE_NIGHT_YES;
    setTheme(dark ? R.style.AppTheme_Dark : R.style.AppTheme);
    foreground = dark ? Color.rgb(241, 245, 249) : Color.rgb(20, 28, 36);
    muted = dark ? Color.rgb(153, 165, 177) : Color.rgb(109, 123, 136);
    surface = dark ? Color.rgb(10, 13, 17) : Color.rgb(252, 253, 254);
    accent = dark ? Color.rgb(113, 190, 231) : Color.rgb(8, 111, 160);
    getWindow().setStatusBarColor(surface);
    getWindow().setNavigationBarColor(surface);
    getWindow()
        .getDecorView()
        .setSystemUiVisibility(dark ? 0 : View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR);
    LinearLayout shell = new LinearLayout(this);
    shell.setOrientation(LinearLayout.VERTICAL);
    shell.setBackgroundColor(surface);
    shell.setOnApplyWindowInsetsListener(
        (view, insets) -> {
          view.setPadding(
              0, insets.getSystemWindowInsetTop(), 0, insets.getSystemWindowInsetBottom());
          return insets;
        });
    LinearLayout header = new LinearLayout(this);
    header.setGravity(Gravity.CENTER_VERTICAL);
    header.setPadding(dp(18), dp(4), dp(18), dp(4));
    header.addView(actionIcon("search", "Search and saved locations", this::locations));
    TextView city = text(place.name(), 16, true);
    city.setGravity(Gravity.CENTER);
    city.setMaxLines(1);
    city.setEllipsize(android.text.TextUtils.TruncateAt.END);
    city.setOnClickListener(v -> locations());
    header.addView(city, new LinearLayout.LayoutParams(0, dp(44), 1));
    header.addView(actionIcon("settings", "Settings", this::settings));
    shell.addView(header);
    ScrollView scroll = new ScrollView(this);
    scroll.setFillViewport(true);
    scroll.setClipToPadding(false);
    content = new LinearLayout(this);
    content.setOrientation(LinearLayout.VERTICAL);
    content.setPadding(dp(22), 0, dp(22), dp(26));
    scroll.addView(content);
    shell.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
    setContentView(shell);
    if (android.os.Build.VERSION.SDK_INT >= 30 && getWindow().getInsetsController() != null) {
      int appearanceFlags =
          android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
              | android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
      getWindow()
          .getInsetsController()
          .setSystemBarsAppearance(dark ? 0 : appearanceFlags, appearanceFlags);
    }
    status =
        text(
            result == null
                ? "Loading forecast…"
                : result.source() + " · updated " + clock(updatedSeconds),
            11,
            false);
    status.setTextColor(muted);
    if (result != null) drawForecast();
    else {
      gap(90);
      status.setGravity(Gravity.CENTER);
      content.addView(status);
      gap(50);
      content.addView(button("Refresh forecast", this::refresh));
    }
    gap(18);
    TextView sources =
        text(
            "Weather · "
                + (result == null ? "Open-Meteo" : result.source())
                + "    Radar · RainViewer",
            10,
            false);
    sources.setTextColor(muted);
    sources.setGravity(Gravity.CENTER);
    sources.setOnClickListener(v -> refresh());
    content.addView(sources);
    TextView attribution = text("OpenFreeMap · OpenMapTiles · © OpenStreetMap", 10, false);
    attribution.setTextColor(muted);
    attribution.setGravity(Gravity.CENTER);
    attribution.setPadding(0, dp(6), 0, 0);
    content.addView(attribution);
  }

  private String temperature(double value) {
    if (!Double.isFinite(value)) return "—";
    return Math.round(celsius ? (value - 32) * 5 / 9 : value) + "°";
  }

  private static double number(JSONObject object, String key) {
    return object == null || object.isNull(key) ? Double.NaN : object.optDouble(key, Double.NaN);
  }

  private static double number(JSONArray array, int index) {
    return array == null || array.isNull(index) ? Double.NaN : array.optDouble(index, Double.NaN);
  }

  private String rounded(double value, String suffix) {
    return Double.isFinite(value) ? Math.round(value) + suffix : "—";
  }

  private ZoneId zone() {
    try {
      return ZoneId.of(result.forecast().optString("timezone", ZoneId.systemDefault().getId()));
    } catch (Exception ignored) {
      return ZoneId.systemDefault();
    }
  }

  private String clock(long seconds) {
    return DateTimeFormatter.ofPattern("h:mm a")
        .withZone(result == null ? ZoneId.systemDefault() : zone())
        .format(Instant.ofEpochSecond(seconds));
  }

  private static String condition(int code) {
    if (code == 0) return "Clear";
    if (code == 1) return "Mostly clear";
    if (code == 2) return "Partly cloudy";
    if (code == 3) return "Overcast";
    if (code == 45 || code == 48) return "Fog";
    if (code >= 51 && code <= 57) return "Drizzle";
    if (code >= 61 && code <= 67 || code >= 80 && code <= 82) return "Rain";
    if (code >= 71 && code <= 77 || code == 85 || code == 86) return "Snow";
    if (code >= 95) return "Thunderstorms";
    return "Conditions unavailable";
  }

  private void drawForecast() {
    JSONObject forecast = result.forecast(), current = forecast.optJSONObject("current");
    JSONObject hourly = forecast.optJSONObject("hourly");
    int code = current == null ? -1 : current.optInt("weather_code", -1);
    gap(5);
    LinearLayout temperature = new LinearLayout(this);
    temperature.setGravity(Gravity.CENTER);
    temperature.addView(
        new WeatherGraphics.Glyph(this, code, foreground, dark),
        new LinearLayout.LayoutParams(dp(51), dp(51)));
    TextView degrees = text(temperature(number(current, "temperature_2m")), 62, true);
    degrees.setLetterSpacing(-0.045f);
    LinearLayout.LayoutParams degreeLayout = new LinearLayout.LayoutParams(-2, dp(70));
    degreeLayout.leftMargin = dp(5);
    temperature.addView(degrees, degreeLayout);
    content.addView(temperature);
    TextView summary = text(condition(code), 16, true);
    summary.setGravity(Gravity.CENTER);
    content.addView(summary);
    JSONObject daily = forecast.optJSONObject("daily");
    JSONArray dayRows = forecast.optJSONArray("dailyRows");
    JSONObject firstDay = dayRows == null ? null : dayRows.optJSONObject(0);
    double high =
        firstDay != null
            ? number(firstDay, "high")
            : daily == null ? Double.NaN : number(daily.optJSONArray("temperature_2m_max"), 0);
    double low =
        firstDay != null
            ? number(firstDay, "low")
            : daily == null ? Double.NaN : number(daily.optJSONArray("temperature_2m_min"), 0);
    TextView feels =
        text(
            "Feels "
                + temperature(number(current, "apparent_temperature"))
                + "  ·  High "
                + temperature(high)
                + "  ·  Low "
                + temperature(low),
            13,
            false);
    feels.setTextColor(muted);
    feels.setGravity(Gravity.CENTER);
    feels.setPadding(0, dp(6), 0, dp(8));
    content.addView(feels);
    status.setGravity(Gravity.CENTER);
    content.addView(status);
    gap(13);
    drawMap();
    if (hourly != null) {
      drawOutlook(hourly);
      hourlyContent = new LinearLayout(this);
      hourlyContent.setOrientation(LinearLayout.VERTICAL);
      content.addView(hourlyContent);
      drawHours(hourly);
      drawDays(forecast);
      heading("Right now");
      LinearLayout stats = new LinearLayout(this);
      addStat(
          stats,
          "Humidity",
          rounded(number(current, "relative_humidity_2m"), "%"),
          () -> detailForecast(hourly));
      double mph = number(current, "wind_speed_10m");
      addStat(
          stats,
          "Wind",
          rounded(celsius ? mph * 1.609344 : mph, celsius ? " km/h" : " mph"),
          () -> detailForecast(hourly));
      int first = hourIndices(hourly, 1).stream().findFirst().orElse(0);
      addStat(
          stats,
          "UV index",
          rounded(number(hourly.optJSONArray("uv_index"), first), ""),
          () -> detailForecast(hourly));
      content.addView(stats);
    }
  }

  private void addStat(LinearLayout parent, String label, String value, Runnable action) {
    LinearLayout cell = new LinearLayout(this);
    cell.setOrientation(LinearLayout.VERTICAL);
    cell.setPadding(0, dp(5), 0, dp(12));
    TextView name = text(label, 11, false);
    name.setTextColor(muted);
    cell.addView(name);
    TextView reading = text(value, 19, true);
    reading.setPadding(0, dp(6), 0, 0);
    cell.addView(reading);
    cell.setOnClickListener(v -> action.run());
    parent.addView(cell, new LinearLayout.LayoutParams(0, -2, 1));
  }

  private List<Integer> hourIndices(JSONObject hourly, int limit) {
    List<Integer> result = new ArrayList<>();
    JSONArray times = hourly.optJSONArray("time");
    long now = Instant.now().getEpochSecond();
    if (times != null)
      for (int i = 0; i < times.length() && result.size() < limit; i++)
        if (times.optLong(i) >= now - 3600) result.add(i);
    return result;
  }

  private void drawOutlook(JSONObject hourly) {
    List<Integer> indices = hourIndices(hourly, 12);
    if (indices.isEmpty()) return;
    JSONArray rain = hourly.optJSONArray("precipitation"),
        chances = hourly.optJSONArray("precipitation_probability"),
        times = hourly.optJSONArray("time");
    boolean wet =
        indices.stream().anyMatch(i -> number(rain, i) > 0.05 || number(chances, i) >= 35);
    String headline = "Wind over the next 12 hours";
    if (wet) {
      int onset =
          indices.stream()
              .filter(i -> number(rain, i) > 0.05 || number(chances, i) >= 35)
              .findFirst()
              .orElse(indices.get(0));
      headline =
          onset == indices.get(0)
              ? "Rain possible this hour"
              : "Rain possible around " + clock(times.optLong(onset));
    }
    TextView title = text(headline, 17, true);
    title.setPadding(0, dp(16), 0, dp(8));
    content.addView(title);
    double[] values = new double[indices.size()];
    String[] labels = new String[indices.size()];
    double max = 0;
    int available = 0;
    for (int j = 0; j < indices.size(); j++) {
      int i = indices.get(j);
      double value = number(wet ? rain : hourly.optJSONArray("wind_speed_10m"), i);
      values[j] = wet ? (celsius ? value : value / 25.4) : (celsius ? value * 1.609344 : value);
      if (Double.isFinite(values[j])) {
        max = Math.max(max, values[j]);
        available++;
      }
      labels[j] =
          DateTimeFormatter.ofPattern("ha")
              .withZone(zone())
              .format(Instant.ofEpochSecond(times.optLong(i)))
              .toLowerCase(java.util.Locale.ROOT);
    }
    LinearLayout caption = new LinearLayout(this);
    TextView span = text("Next 12 hours · " + (wet ? "Precipitation" : "Wind"), 11, false);
    span.setTextColor(accent);
    caption.addView(span, new LinearLayout.LayoutParams(0, -2, 1));
    String unit = wet ? (celsius ? "mm" : "in") : (celsius ? "km/h" : "mph");
    TextView peak =
        text(
            available == 0
                ? "Unavailable"
                : "Peak "
                    + String.format(
                        java.util.Locale.getDefault(), wet ? "%.2f %s" : "%.0f %s", max, unit),
            10,
            false);
    peak.setTextColor(muted);
    caption.addView(peak);
    content.addView(caption);
    WeatherGraphics.Bars chart =
        new WeatherGraphics.Bars(
            this,
            values,
            labels,
            muted,
            wet ? Color.rgb(55, 145, 205) : Color.rgb(69, 151, 141),
            hairline(),
            Math.max(wet ? (celsius ? 1 : 0.04) : 5, max * 1.15));
    chart.setContentDescription(headline + ". Hourly forecast. " + result.source());
    content.addView(chart, new LinearLayout.LayoutParams(-1, dp(96)));
  }

  private void drawHours(JSONObject hourly) {
    hourlyContent.removeAllViews();
    LinearLayout header = new LinearLayout(this);
    header.setGravity(Gravity.CENTER_VERTICAL);
    header.setPadding(0, dp(13), 0, dp(8));
    TextView title = text("Hourly", 20, true);
    header.addView(title, new LinearLayout.LayoutParams(0, -2, 1));
    header.addView(
        button(
            expanded ? "Show 6 hours" : "Show 24 hours",
            () -> {
              expanded = !expanded;
              drawHours(hourly);
            }));
    hourlyContent.addView(header);
    HorizontalScrollView scroll = new HorizontalScrollView(this);
    scroll.setHorizontalScrollBarEnabled(false);
    LinearLayout tabs = new LinearLayout(this);
    for (String metric : new String[] {"Temp", "Feels", "Chance", "Wind", "UV", "Humidity"}) {
      Button tab =
          button(
              metric,
              () -> {
                hourlyMetric = metric;
                drawHours(hourly);
              });
      tab.setTextColor(metric.equals(hourlyMetric) ? surface : foreground);
      tab.setTextSize(11);
      tab.setBackground(
          roundedBackground(metric.equals(hourlyMetric) ? foreground : secondarySurface(), 14));
      LinearLayout.LayoutParams item = new LinearLayout.LayoutParams(-2, dp(29));
      item.rightMargin = dp(7);
      tabs.addView(tab, item);
    }
    scroll.addView(tabs);
    hourlyContent.addView(scroll);
    View spacer = new View(this);
    hourlyContent.addView(spacer, new LinearLayout.LayoutParams(1, dp(10)));
    List<Integer> indices = hourIndices(hourly, expanded ? 24 : 6);
    JSONArray times = hourly.optJSONArray("time");
    String key =
        switch (hourlyMetric) {
          case "Feels" -> "apparent_temperature";
          case "Chance" -> "precipitation_probability";
          case "Wind" -> "wind_speed_10m";
          case "UV" -> "uv_index";
          case "Humidity" -> "relative_humidity_2m";
          default -> "temperature_2m";
        };
    for (int i : indices) {
      LinearLayout line = new LinearLayout(this);
      line.setGravity(Gravity.CENTER_VERTICAL);
      TextView time = text(clock(times.optLong(i)).replace(":00", ""), 12, true);
      time.setGravity(Gravity.CENTER_VERTICAL);
      line.addView(time, new LinearLayout.LayoutParams(dp(64), dp(32)));
      int weather =
          hourly.optJSONArray("weather_code") == null
              ? -1
              : hourly.optJSONArray("weather_code").optInt(i, -1);
      line.addView(
          new WeatherGraphics.Glyph(this, weather, foreground, dark),
          new LinearLayout.LayoutParams(dp(28), dp(28)));
      double chance = number(hourly.optJSONArray("precipitation_probability"), i);
      TextView condition =
          text(chance >= 20 ? rounded(chance, "% rain") : condition(weather), 11, false);
      condition.setTextColor(muted);
      condition.setPadding(dp(9), 0, dp(5), 0);
      condition.setMaxLines(1);
      condition.setEllipsize(android.text.TextUtils.TruncateAt.END);
      line.addView(condition, new LinearLayout.LayoutParams(0, -2, 1));
      double value = number(hourly.optJSONArray(key), i);
      String label =
          hourlyMetric.equals("Temp") || hourlyMetric.equals("Feels")
              ? temperature(value)
              : hourlyMetric.equals("Wind")
                  ? rounded(celsius ? value * 1.609344 : value, celsius ? " km/h" : " mph")
                  : rounded(
                      value,
                      hourlyMetric.equals("Chance") || hourlyMetric.equals("Humidity") ? "%" : "");
      TextView reading = text(label, 13, true);
      reading.setGravity(Gravity.CENTER);
      reading.setPadding(dp(8), dp(4), dp(8), dp(4));
      reading.setBackground(roundedBackground(secondarySurface(), 11));
      line.addView(reading);
      line.setContentDescription(
          clock(times.optLong(i)) + ", " + hourlyMetric + " " + label + ", " + condition(weather));
      hourlyContent.addView(line, new LinearLayout.LayoutParams(-1, dp(33)));
    }
  }

  private void drawDays(JSONObject forecast) {
    record Day(String name, double high, double low, int code, double chance) {}
    List<Day> days = new ArrayList<>();
    JSONArray rows = forecast.optJSONArray("dailyRows");
    if (rows != null)
      for (int i = 0; i < Math.min(rows.length(), 10); i++) {
        JSONObject day = rows.optJSONObject(i);
        if (day == null) continue;
        String date = day.optString("dateKey");
        String name = date;
        try {
          name = java.time.LocalDate.parse(date).format(DateTimeFormatter.ofPattern("EEE"));
        } catch (Exception ignored) {
        }
        days.add(
            new Day(
                i == 0 ? "Today" : name,
                number(day, "high"),
                number(day, "low"),
                day.optInt("code", -1),
                number(day, "chance")));
      }
    else {
      JSONObject daily = forecast.optJSONObject("daily");
      JSONArray dates = daily == null ? null : daily.optJSONArray("time");
      if (dates != null)
        for (int i = 0; i < Math.min(dates.length(), 10); i++) {
          String name =
              i == 0
                  ? "Today"
                  : DateTimeFormatter.ofPattern("EEE")
                      .withZone(zone())
                      .format(Instant.ofEpochSecond(dates.optLong(i)));
          days.add(
              new Day(
                  name,
                  number(daily.optJSONArray("temperature_2m_max"), i),
                  number(daily.optJSONArray("temperature_2m_min"), i),
                  daily.optJSONArray("weather_code") == null
                      ? -1
                      : daily.optJSONArray("weather_code").optInt(i, -1),
                  number(daily.optJSONArray("precipitation_probability_max"), i)));
        }
    }
    if (days.isEmpty()) return;
    heading("Daily");
    double minimum = days.stream().mapToDouble(Day::low).filter(Double::isFinite).min().orElse(0),
        maximum = days.stream().mapToDouble(Day::high).filter(Double::isFinite).max().orElse(100);
    for (Day day : days) {
      LinearLayout line = new LinearLayout(this);
      line.setGravity(Gravity.CENTER_VERTICAL);
      TextView name = text(day.name, 13, true);
      line.addView(name, new LinearLayout.LayoutParams(dp(53), -2));
      line.addView(
          new WeatherGraphics.Glyph(this, day.code, foreground, dark),
          new LinearLayout.LayoutParams(dp(28), dp(28)));
      TextView chance = text(day.chance >= 20 ? rounded(day.chance, "%") : "", 10, false);
      chance.setTextColor(accent);
      chance.setGravity(Gravity.CENTER);
      line.addView(chance, new LinearLayout.LayoutParams(dp(36), -2));
      TextView low = text(temperature(day.low), 13, false);
      low.setTextColor(muted);
      low.setGravity(Gravity.CENTER);
      line.addView(low, new LinearLayout.LayoutParams(dp(35), -2));
      line.addView(
          new WeatherGraphics.Range(this, day.low, day.high, minimum, maximum, hairline()),
          new LinearLayout.LayoutParams(0, dp(26), 1));
      TextView high = text(temperature(day.high), 13, true);
      high.setGravity(Gravity.END);
      line.addView(high, new LinearLayout.LayoutParams(dp(39), -2));
      content.addView(line, new LinearLayout.LayoutParams(-1, dp(33)));
    }
  }

  private void detailForecast(JSONObject hourly) {
    List<String> rows = new ArrayList<>();
    JSONArray times = hourly.optJSONArray("time");
    if (times != null)
      for (int i = 0; i < times.length() && rows.size() < 48; i++) {
        if (times.optLong(i) < Instant.now().getEpochSecond() - 3600) continue;
        rows.add(
            clock(times.optLong(i))
                + "  ·  UV "
                + rounded(number(hourly.optJSONArray("uv_index"), i), "")
                + "  ·  "
                + rounded(number(hourly.optJSONArray("relative_humidity_2m"), i), "% humidity"));
      }
    WeatherSheet sheet =
        sheet("48-hour detail forecast", "Hourly UV and humidity · " + result.source());
    for (String row : rows) sheet.row(row, null, null, false, null);
    sheet.show();
  }

  private void drawMap() {
    FrameLayout frame = new FrameLayout(this);
    frame.setBackground(roundedBackground(secondarySurface(), 15));
    frame.setClipToOutline(true);
    mapView =
        new MapView(
            this,
            org.maplibre.android.maps.MapLibreMapOptions.createFromAttributes(this)
                .textureMode(true));
    mapView.onCreate(null);
    frame.addView(mapView, new FrameLayout.LayoutParams(-1, -1));
    content.addView(frame, new LinearLayout.LayoutParams(-1, dp(savedMap ? 310 : 158)));
    mapView.setOnTouchListener(
        (view, event) -> {
          view.getParent()
              .getParent()
              .requestDisallowInterceptTouchEvent(
                  event.getAction() != MotionEvent.ACTION_UP
                      && event.getAction() != MotionEvent.ACTION_CANCEL);
          return false;
        });
    frameLabel =
        text(
            savedMap
                ? "Saved locations"
                : result.radar().isEmpty() ? "Radar unavailable" : "Loading radar…",
            10,
            true);
    frameLabel.setTextColor(foreground);
    frameLabel.setPadding(dp(10), dp(7), dp(10), dp(7));
    frameLabel.setBackground(roundedBackground(dark ? 0xe520272e : 0xecffffff, 10));
    FrameLayout.LayoutParams labelLayout =
        new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.START);
    labelLayout.setMargins(dp(10), dp(10), 0, 0);
    frame.addView(frameLabel, labelLayout);
    if (started) mapView.onStart();
    if (resumed) mapView.onResume();
    MapView ownedMap = mapView;
    ownedMap.addOnDidFinishRenderingMapListener(
        fullyRendered -> {
          if (fullyRendered) ownedMap.setTag(Boolean.TRUE);
        });
    mapView.getMapAsync(
        loaded -> {
          if (isDestroyed() || mapView != ownedMap) return;
          map = loaded;
          map.getUiSettings().setLogoEnabled(false);
          map.getUiSettings().setAttributionGravity(Gravity.BOTTOM | Gravity.RIGHT);
          map.getUiSettings().setAttributionMargins(0, 0, dp(5), dp(5));
          map.setCameraPosition(
              new CameraPosition.Builder()
                  .target(new LatLng(place.latitude(), place.longitude()))
                  .zoom(savedMap ? 3.5 : 5.3)
                  .build());
          map.setStyle(
              new Style.Builder()
                  .fromUri("https://tiles.openfreemap.org/styles/" + (dark ? "dark" : "positron")),
              style -> {
                if (isDestroyed() || mapView != ownedMap) return;
                mapStyle = style;
                if (dark) {
                  for (var layer : style.getLayers()) {
                    if (layer instanceof org.maplibre.android.style.layers.SymbolLayer symbols) {
                      symbols.setProperties(
                          PropertyFactory.textColor(Color.rgb(220, 230, 237)),
                          PropertyFactory.textHaloColor(Color.rgb(24, 30, 36)),
                          PropertyFactory.textHaloWidth(1.2f));
                    }
                  }
                }
                if (savedMap) {
                  for (WeatherService.Place saved : favorites())
                    map.addMarker(
                        new MarkerOptions()
                            .position(new LatLng(saved.latitude(), saved.longitude()))
                            .title(saved.name()));
                  map.setOnMarkerClickListener(
                      marker -> {
                        for (WeatherService.Place saved : favorites())
                          if (Math.abs(saved.latitude() - marker.getPosition().getLatitude())
                                  < 0.0001
                              && Math.abs(saved.longitude() - marker.getPosition().getLongitude())
                                  < 0.0001) {
                            select(saved);
                            break;
                          }
                        return true;
                      });
                } else {
                  String labels = null;
                  for (var layer : style.getLayers())
                    if (layer instanceof org.maplibre.android.style.layers.SymbolLayer) {
                      labels = layer.getId();
                      break;
                    }
                  for (int i = 0; i < result.radar().size(); i++) {
                    var radar = result.radar().get(i);
                    TileSet tiles = new TileSet("2.1.0", radar.template());
                    tiles.setMinZoom(0f);
                    tiles.setMaxZoom(7f);
                    String id = "radar-" + i;
                    style.addSource(new RasterSource(id, tiles, 256));
                    RasterLayer layer =
                        new RasterLayer(id, id)
                            .withProperties(
                                PropertyFactory.rasterOpacity(0.001f),
                                PropertyFactory.rasterFadeDuration(0f));
                    if (labels == null) style.addLayer(layer);
                    else style.addLayerBelow(layer, labels);
                  }
                  showFrame(Math.max(0, result.radar().size() - 1));
                }
              });
        });
    if (!savedMap) {
      LinearLayout controls = new LinearLayout(this);
      controls.setGravity(Gravity.CENTER_VERTICAL);
      Button playButton =
          button(
              "Play",
              () -> {
                playing = !playing;
                handler.removeCallbacks(play);
                if (playing) handler.post(play);
                else if (radarPlayButton != null) radarPlayButton.setText("Play");
              });
      radarPlayButton = playButton;
      playButton.setContentDescription("Play or pause observed radar");
      controls.addView(playButton, new LinearLayout.LayoutParams(dp(48), dp(32)));
      SeekBar slider = new SeekBar(this);
      radarSlider = slider;
      slider.setMax(Math.max(0, result.radar().size() - 1));
      slider.setProgress(slider.getMax());
      slider.setProgressTintList(ColorStateList.valueOf(accent));
      slider.setThumbTintList(ColorStateList.valueOf(accent));
      slider.setOnSeekBarChangeListener(
          new SeekBar.OnSeekBarChangeListener() {
            public void onProgressChanged(SeekBar bar, int value, boolean fromUser) {
              if (fromUser) {
                playing = false;
                handler.removeCallbacks(play);
                showFrame(value);
              }
            }

            public void onStartTrackingTouch(SeekBar bar) {}

            public void onStopTrackingTouch(SeekBar bar) {}
          });
      slider.setContentDescription("Observed radar time");
      controls.addView(slider, new LinearLayout.LayoutParams(0, dp(32), 1));
      TextView past = text("PAST", 9, false);
      past.setTextColor(muted);
      controls.addView(past);
      content.addView(controls);
    } else
      content.addView(
          button(
              "Return to weather map",
              () -> {
                savedMap = false;
                render();
              }));
  }

  private void showFrame(int index) {
    if (result == null || result.radar().isEmpty()) return;
    frameIndex = Math.min(Math.max(index, 0), result.radar().size() - 1);
    if (radarSlider != null) radarSlider.setProgress(frameIndex);
    if (radarPlayButton != null) radarPlayButton.setText(playing ? "Pause" : "Play");
    if (mapStyle != null)
      for (int i = 0; i < result.radar().size(); i++) {
        RasterLayer layer = mapStyle.getLayerAs("radar-" + i);
        if (layer != null)
          layer.setProperties(PropertyFactory.rasterOpacity(i == frameIndex ? 0.75f : 0.001f));
      }
    if (frameLabel != null)
      frameLabel.setText("Observed " + clock(result.radar().get(frameIndex).seconds()));
  }

  private void refresh() {
    int generation = ++requestGeneration;
    if (status != null) status.setText("Refreshing weather…");
    WeatherService.Place selected = place;
    worker.execute(
        () -> {
          try {
            var loaded = service.load(selected);
            runOnUiThread(
                () -> {
                  if (!isDestroyed() && generation == requestGeneration) {
                    result = loaded;
                    updatedSeconds = Instant.now().getEpochSecond();
                    render();
                  }
                });
          } catch (Exception ignored) {
            runOnUiThread(
                () -> {
                  if (!isDestroyed() && generation == requestGeneration && status != null)
                    status.setText("Weather unavailable. Check your connection and tap Refresh.");
                });
          }
        });
  }

  private void select(WeatherService.Place next) {
    place = next;
    result = null;
    savedMap = false;
    try {
      preferences
          .edit()
          .putString("selectedPlace", next.json().toString())
          .putBoolean("useCurrent", false)
          .apply();
    } catch (Exception ignored) {
    }
    render();
    refresh();
  }

  private List<WeatherService.Place> favorites() {
    List<WeatherService.Place> saved = new ArrayList<>();
    try {
      JSONArray data = new JSONArray(preferences.getString("favorites", "[]"));
      for (int i = 0; i < data.length(); i++)
        saved.add(WeatherService.Place.parse(data.getJSONObject(i)));
    } catch (Exception ignored) {
    }
    return saved;
  }

  private WeatherSheet sheet(String title, String subtitle) {
    return new WeatherSheet(this, dark, title, subtitle);
  }

  private void locations() {
    WeatherSheet sheet = sheet("Locations", "Your weather, wherever you are.");
    sheet
        .section("Find a place")
        .row(
            "Use current location",
            "Weather near you",
            null,
            false,
            () -> {
              preferences.edit().putBoolean("useCurrent", true).apply();
              useCurrent();
            })
        .row("Search for a city", null, null, false, this::search);
    boolean saved =
        favorites().stream()
            .anyMatch(
                item ->
                    item.latitude() == place.latitude() && item.longitude() == place.longitude());
    sheet
        .section("This location")
        .row(
            saved ? "Remove from favorites" : "Save to favorites",
            place.name(),
            null,
            false,
            this::saveFavorite);
    List<WeatherService.Place> favorites = favorites();
    if (!favorites.isEmpty()) {
      sheet.section("Saved places");
      for (var city : favorites) sheet.row(city.name(), null, null, false, () -> select(city));
      sheet.row(
          "Saved locations map",
          "Choose a place on the map",
          null,
          false,
          () -> {
            savedMap = true;
            render();
          });
    }
    sheet.show();
  }

  private void saveFavorite() {
    List<WeatherService.Place> saved = favorites();
    boolean removed =
        saved.removeIf(
            item -> item.latitude() == place.latitude() && item.longitude() == place.longitude());
    if (!removed && saved.size() < 30) saved.add(place);
    JSONArray data = new JSONArray();
    try {
      for (var item : saved) data.put(item.json());
      preferences.edit().putString("favorites", data.toString()).apply();
    } catch (Exception ignored) {
    }
    Toast.makeText(this, removed ? "Favorite removed" : "Location saved", Toast.LENGTH_SHORT)
        .show();
  }

  private void search() {
    WeatherSheet searchSheet = sheet("Find a city", "Search by city name to see its forecast.");
    EditText query = searchSheet.input("City name");
    Runnable submitSearch =
        () -> {
          String value = query.getText().toString().trim();
          if (value.length() < 2) {
            query.setError("Enter at least two letters");
            return;
          }
          searchSheet.dismiss();
          worker.execute(
              () -> {
                try {
                  List<WeatherService.Place> found = WeatherService.search(value);
                  runOnUiThread(
                      () -> {
                        if (isDestroyed()) return;
                        WeatherSheet results = sheet("Search results", "Choose a location");
                        if (found.isEmpty())
                          results
                              .message("No matching cities. Try another name.")
                              .primary(
                                  "Search again",
                                  () -> {
                                    results.dismiss();
                                    search();
                                  });
                        else
                          for (var city : found)
                            results.row(city.name(), null, null, false, () -> select(city));
                        results.show();
                      });
                } catch (Exception ignored) {
                  runOnUiThread(
                      () ->
                          Toast.makeText(this, "City search unavailable", Toast.LENGTH_LONG)
                              .show());
                }
              });
        };
    searchSheet.primary("Search", submitSearch);
    query.setImeOptions(android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH);
    query.setOnEditorActionListener(
        (view, action, event) -> {
          if (action == android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH) {
            submitSearch.run();
            return true;
          }
          return false;
        });
    searchSheet.show();
  }

  private String appearanceName() {
    return new String[] {"System", "Light", "Dark"}[preferences.getInt("appearance", 0)];
  }

  private void appearance() {
    WeatherSheet sheet = sheet("Appearance", "Choose how KlierSky looks.");
    String[] names = {"System", "Light", "Dark"};
    String[] descriptions = {
      "Follow your device appearance", "A clear, bright forecast", "Comfortable after dark"
    };
    for (int i = 0; i < names.length; i++) {
      final int choice = i;
      sheet.choice(
          names[i],
          descriptions[i],
          preferences.getInt("appearance", 0) == i,
          () -> {
            preferences.edit().putInt("appearance", choice).apply();
            render();
          });
    }
    sheet.show();
  }

  private void units() {
    WeatherSheet sheet = sheet("Units", "Temperature and wind speed");
    sheet.choice(
        "Fahrenheit",
        "°F · miles per hour",
        !celsius,
        () -> {
          preferences.edit().putBoolean("celsius", false).apply();
          render();
        });
    sheet.choice(
        "Celsius",
        "°C · kilometers per hour",
        celsius,
        () -> {
          preferences.edit().putBoolean("celsius", true).apply();
          render();
        });
    sheet.show();
  }

  private void administration() {
    sheet("Administration", "Service access and development details")
        .row(
            "Foreca service access",
            "Owner-approved access to your weather server",
            null,
            false,
            this::forecaAccess)
        .row(
            "Android alpha feature status",
            "What is available in this preview",
            null,
            false,
            this::alphaStatus)
        .show();
  }

  private void forecaAccess() {
    WeatherSheet sheet = sheet("Foreca access", "Your provider key stays on the server.");
    sheet.message(
        result == null
            ? "Refresh to request service access. The owner approves your device on their iPhone."
            : result.accessMessage().isEmpty()
                ? "Connected to the server-held Foreca account with this device's read-only access."
                : result.accessMessage());
    sheet.primary(
        "Check again",
        () -> {
          sheet.dismiss();
          refresh();
        });
    sheet.show();
  }

  private void alphaStatus() {
    sheet("Android alpha", "KlierSky " + BuildConfig.VERSION_NAME)
        .message(
            "Working core: current conditions, hourly and daily forecasts, unit/theme settings,"
                + " current location, saved places, city search, Foreca access and observed"
                + " radar.\n\n"
                + "The iOS blend, model futurecast, station connection, history, notifications and"
                + " widgets still need porting.")
        .show();
  }

  private void settings() {
    WeatherSheet sheet = sheet("Settings", "Make KlierSky feel like yours.");
    sheet
        .section("Preferences")
        .row("Appearance", null, appearanceName(), false, this::appearance)
        .row("Units", null, celsius ? "°C · km/h" : "°F · mph", false, this::units);
    sheet
        .section("Your weather")
        .row(
            "Current location on startup",
            "Use your position when KlierSky opens",
            preferences.getBoolean("useCurrent", true) ? "On" : "Off",
            false,
            () -> {
              boolean enabled = !preferences.getBoolean("useCurrent", true);
              preferences.edit().putBoolean("useCurrent", enabled).apply();
              if (enabled) useCurrent();
            })
        .row(
            "Saved locations map",
            "Choose a place on the map",
            null,
            false,
            () -> {
              savedMap = true;
              render();
            })
        .row("Refresh weather", null, null, false, this::refresh);
    sheet
        .section("Advanced")
        .row(
            "Administration",
            "Service access and app information",
            null,
            false,
            this::administration);
    sheet.show();
  }

  private void useCurrent() {
    if (checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION)
        != PackageManager.PERMISSION_GRANTED) {
      requestPermissions(new String[] {Manifest.permission.ACCESS_COARSE_LOCATION}, 10);
      return;
    }
    locationManager = (LocationManager) getSystemService(LOCATION_SERVICE);
    try {
      String provider =
          locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
              ? LocationManager.NETWORK_PROVIDER
              : LocationManager.GPS_PROVIDER;
      locationListener =
          new LocationListener() {
            public void onLocationChanged(Location location) {
              if (locationListener != null) locationManager.removeUpdates(this);
              locationListener = null;
              if (!Double.isFinite(location.getLatitude())
                  || !Double.isFinite(location.getLongitude())) return;
              place =
                  new WeatherService.Place(
                      "Current location", location.getLatitude(), location.getLongitude());
              result = null;
              try {
                preferences.edit().putString("selectedPlace", place.json().toString()).apply();
              } catch (Exception ignored) {
              }
              render();
              refresh();
            }

            public void onProviderDisabled(String provider) {}

            public void onProviderEnabled(String provider) {}

            public void onStatusChanged(String provider, int status, Bundle extras) {}
          };
      locationManager.requestSingleUpdate(provider, locationListener, Looper.getMainLooper());
      handler.postDelayed(
          () -> {
            if (locationListener != null) {
              locationManager.removeUpdates(locationListener);
              locationListener = null;
              Toast.makeText(
                      this, "Location unavailable. Choose a city in Locations.", Toast.LENGTH_LONG)
                  .show();
              refresh();
            }
          },
          12000);
    } catch (Exception ignored) {
      Toast.makeText(this, "Location unavailable. Choose a city.", Toast.LENGTH_LONG).show();
      refresh();
    }
  }

  @Override
  public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
    super.onRequestPermissionsResult(requestCode, permissions, results);
    if (requestCode == 10) {
      if (results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED) useCurrent();
      else {
        Toast.makeText(
                this, "Showing the saved city. Choose another in Locations.", Toast.LENGTH_LONG)
            .show();
        refresh();
      }
    }
  }

  @Override
  public void onConfigurationChanged(Configuration configuration) {
    super.onConfigurationChanged(configuration);
    render();
  }

  @Override
  protected void onStart() {
    super.onStart();
    started = true;
    if (mapView != null) mapView.onStart();
  }

  @Override
  protected void onResume() {
    super.onResume();
    resumed = true;
    if (mapView != null) mapView.onResume();
  }

  @Override
  protected void onPause() {
    resumed = false;
    playing = false;
    handler.removeCallbacks(play);
    if (mapView != null) mapView.onPause();
    super.onPause();
  }

  @Override
  protected void onStop() {
    started = false;
    if (mapView != null) mapView.onStop();
    super.onStop();
  }

  @Override
  public void onLowMemory() {
    super.onLowMemory();
    if (mapView != null) mapView.onLowMemory();
  }

  @Override
  protected void onDestroy() {
    worker.shutdownNow();
    handler.removeCallbacksAndMessages(null);
    if (locationManager != null && locationListener != null)
      locationManager.removeUpdates(locationListener);
    disposeMap();
    super.onDestroy();
  }
}
