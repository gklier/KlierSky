package com.klier.kliersky;

import android.Manifest;
import android.app.*;
import android.appwidget.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.content.res.*;
import android.graphics.*;
import android.graphics.drawable.*;
import android.os.*;
import android.view.*;
import android.widget.*;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import org.json.*;

/**
 * Native detail and administration screens sharing the app's actual data and provider contracts.
 */
public class FeatureActivity extends Activity {
  private final ExecutorService worker = Executors.newSingleThreadExecutor();
  private android.content.SharedPreferences prefs;
  private WeatherService service;
  private LocalData files;
  private WeatherService.Place place;
  private JSONObject forecast = new JSONObject(), historyComparison, historyDay, station, devices;
  private String feature,
      metric = "UV",
      historyError = "",
      stationMessage = "",
      historyDate = LocalDate.now().minusDays(7).toString();
  private LinearLayout body;
  private TextView status;
  private int ink, muted, accent, background, surface;
  private boolean dark, celsius, testAfterPermission;
  private int widgetID = AppWidgetManager.INVALID_APPWIDGET_ID;
  private boolean widgetCelsius;
  static final String[][] METRICS = {
    {"Temperature", "temperature_2m", "°"},
    {"Feels like", "apparent_temperature", "°"},
    {"Rain", "precipitation", "mm"},
    {"Chance", "precipitation_probability", "%"},
    {"Wind", "wind_speed_10m", "mph"},
    {"Gust", "wind_gusts_10m", "mph"},
    {"UV", "uv_index", ""},
    {"Humidity", "relative_humidity_2m", "%"},
    {"Dew point", "dew_point_2m", "°"},
    {"Pressure", "pressure_msl", "hPa"},
    {"Clouds", "cloud_cover", "%"},
    {"Visibility", "visibility", "m"},
    {"Snow", "snowfall", "cm"}
  };

  static void open(Activity activity, String feature, WeatherService.Place place, int index) {
    try {
      activity.startActivity(
          new Intent(activity, FeatureActivity.class)
              .putExtra("feature", feature)
              .putExtra("place", place.json().toString())
              .putExtra("index", index));
    } catch (Exception ignored) {
    }
  }

  @Override
  public void onCreate(Bundle state) {
    super.onCreate(state);
    prefs = getSharedPreferences("weather", 0);
    files = new LocalData(this);
    service = new WeatherService(this);
    feature = getIntent().getStringExtra("feature");
    if (feature == null) feature = "metrics";
    widgetID =
        getIntent()
            .getIntExtra(
                AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID);
    if (widgetID != AppWidgetManager.INVALID_APPWIDGET_ID) {
      feature = "widget";
      setResult(RESULT_CANCELED);
    }
    try {
      String selected = getIntent().getStringExtra("place");
      if (selected == null || selected.isEmpty()) selected = prefs.getString("selectedPlace", "");
      place = WeatherService.Place.parse(new JSONObject(selected));
    } catch (Exception e) {
      place = new WeatherService.Place("Milwaukee", 43.0389, -87.9065);
    }
    JSONObject cached = files.read("forecast-" + LocalData.placeKey(place));
    if (cached.optJSONObject("forecast") != null) forecast = cached.optJSONObject("forecast");
    widgetCelsius = prefs.getBoolean("celsius", false);
    station = forecast.optJSONObject("_station");
    render();
    if (feature.equals("history")) loadHistory();
    if (feature.equals("station")) loadStation();
    if (feature.equals("owner") && !service.owner.read().isEmpty()) loadDevices();
  }

  int dp(int value) {
    return Math.round(value * getResources().getDisplayMetrics().density);
  }

  TextView text(String value, int size, boolean bold) {
    TextView v = new TextView(this);
    v.setText(value);
    v.setTextSize(size);
    v.setTextColor(ink);
    v.setIncludeFontPadding(false);
    v.setTypeface(Typeface.create(bold ? "sans-serif-medium" : "sans-serif", Typeface.NORMAL));
    return v;
  }

  GradientDrawable shape(int color, int radius) {
    GradientDrawable d = new GradientDrawable();
    d.setColor(color);
    d.setCornerRadius(dp(radius));
    return d;
  }

  void heading(String title) {
    TextView view = text(title, 18, true);
    view.setPadding(0, dp(22), 0, dp(12));
    if (Build.VERSION.SDK_INT >= 28) view.setAccessibilityHeading(true);
    body.addView(view);
  }

  void note(String value) {
    TextView view = text(value, 13, false);
    view.setTextColor(muted);
    view.setLineSpacing(dp(3), 1);
    view.setPadding(0, dp(9), 0, dp(12));
    body.addView(view);
  }

  LinearLayout row(String label, String value, Runnable action) {
    LinearLayout row = new LinearLayout(this);
    row.setGravity(Gravity.CENTER_VERTICAL);
    row.setPadding(dp(14), dp(14), dp(14), dp(14));
    row.setMinimumHeight(dp(50));
    row.setBackground(shape(surface, 14));
    TextView title = text(label, 15, false);
    row.addView(title, new LinearLayout.LayoutParams(0, -2, 1));
    if (value != null) {
      TextView reading = text(value, 15, false);
      reading.setTextColor(action == null ? muted : accent);
      reading.setGravity(Gravity.END);
      reading.setMaxWidth(dp(190));
      row.addView(reading);
    }
    if (action != null) {
      row.setFocusable(true);
      row.setOnClickListener(v -> action.run());
    }
    LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
    lp.bottomMargin = dp(3);
    body.addView(row, lp);
    return row;
  }

  void button(String title, Runnable action) {
    LinearLayout r = row(title, "›", action);
    ((TextView) r.getChildAt(0)).setTextColor(accent);
  }

  EditText field(String hint, boolean secure) {
    EditText field = new EditText(this);
    field.setHint(hint);
    field.setTextColor(ink);
    field.setHintTextColor(muted);
    field.setTextSize(16);
    field.setSingleLine(true);
    field.setPadding(dp(14), dp(14), dp(14), dp(14));
    field.setBackground(shape(surface, 14));
    field.setInputType(
        android.text.InputType.TYPE_CLASS_TEXT
            | (secure
                ? android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD
                : android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS));
    if (secure) field.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);
    LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
    lp.bottomMargin = dp(8);
    body.addView(field, lp);
    return field;
  }

  void toggle(String label, String key, boolean fallback, Runnable changed) {
    LinearLayout row = row(label, null, null);
    SkySwitch control = new SkySwitch(this, dark);
    control.setContentDescription(label);
    control.setChecked(prefs.getBoolean(key, fallback));
    control.setOnCheckedChangeListener(
        (v, on) -> {
          prefs.edit().putBoolean(key, on).putBoolean("featureChanged", true).apply();
          changed.run();
        });
    row.addView(control);
  }

  void option(String label, String value, String[] choices, IntConsumer change) {
    LinearLayout anchor = row(label, value + " ⌄", () -> {});
    anchor.setOnClickListener(
        v -> {
          LinearLayout content = new LinearLayout(this);
          content.setOrientation(LinearLayout.VERTICAL);
          content.setBackground(shape(surface, 14));
          content.setClipToOutline(true);
          PopupWindow popup = new PopupWindow(content, dp(240), -2, true);
          popup.setBackgroundDrawable(shape(surface, 14));
          popup.setElevation(dp(12));
          popup.setOutsideTouchable(true);
          for (int i = 0; i < choices.length; i++) {
            int index = i;
            TextView item = text(choices[i], 16, false);
            item.setContentDescription(choices[i]);
            item.setPadding(dp(16), dp(15), dp(16), dp(15));
            item.setOnClickListener(
                w -> {
                  popup.dismiss();
                  change.accept(index);
                  prefs.edit().putBoolean("featureChanged", true).apply();
                  render();
                });
            content.addView(item);
          }
          popup.showAsDropDown(anchor, 0, 0, Gravity.END);
        });
  }

  ZoneId zone() {
    try {
      return ZoneId.of(forecast.optString("timezone", ZoneId.systemDefault().getId()));
    } catch (Exception e) {
      return ZoneId.systemDefault();
    }
  }

  String clock(long time) {
    return DateTimeFormatter.ofPattern(prefs.getBoolean("clock24", false) ? "HH:mm" : "h:mm a")
        .withZone(zone())
        .format(Instant.ofEpochSecond(time));
  }

  String temp(double value) {
    return WeatherWidgets.temperature(value, celsius);
  }

  String number(double value, String unit) {
    return Double.isFinite(value) ? String.format(Locale.getDefault(), "%.1f%s", value, unit) : "—";
  }

  void async(String message, Callable<JSONObject> task, Consumer<JSONObject> success) {
    if (status != null) status.setText(message);
    worker.execute(
        () -> {
          try {
            JSONObject result = task.call();
            runOnUiThread(
                () -> {
                  if (!isFinishing() && !isDestroyed()) success.accept(result);
                });
          } catch (Exception ignored) {
            runOnUiThread(
                () -> {
                  if (!isFinishing() && status != null)
                    status.setText(
                        "Service unavailable. Check your connection and access, then retry. No"
                            + " values were estimated.");
                });
          }
        });
  }

  void render() {
    int appearance = prefs.getInt("appearance", 0);
    dark =
        appearance == 2 || appearance == 0 && (getResources().getConfiguration().uiMode & 48) == 32;
    celsius = prefs.getBoolean("celsius", false);
    ink = dark ? Color.WHITE : 0xff111113;
    muted = dark ? 0xffa2a2aa : 0xff6d6d75;
    accent = dark ? 0xff64b5f6 : 0xff007aff;
    background = dark ? 0xff1c1c1e : 0xfff2f2f7;
    surface = dark ? 0xff2c2c2e : Color.WHITE;
    setTheme(dark ? R.style.AppTheme_Dark : R.style.AppTheme);
    if (feature.equals("station") || feature.equals("owner"))
      getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
    LinearLayout root = new LinearLayout(this);
    root.setOrientation(LinearLayout.VERTICAL);
    root.setBackgroundColor(background);
    root.setOnApplyWindowInsetsListener(
        (view, insets) -> {
          view.setPadding(
              0, insets.getSystemWindowInsetTop(), 0, insets.getSystemWindowInsetBottom());
          return insets;
        });
    FrameLayout header = new FrameLayout(this);
    TextView title = text(title(), 17, true);
    title.setGravity(Gravity.CENTER);
    FrameLayout.LayoutParams center = new FrameLayout.LayoutParams(-1, -1);
    center.setMargins(dp(80), 0, dp(80), 0);
    header.addView(title, center);
    TextView back = text("‹ Back", 17, false);
    back.setTextColor(accent);
    back.setGravity(Gravity.CENTER_VERTICAL);
    back.setPadding(dp(16), 0, 0, 0);
    back.setContentDescription("Back");
    back.setOnClickListener(v -> finish());
    header.addView(back, new FrameLayout.LayoutParams(dp(80), -1, Gravity.START));
    root.addView(header, new LinearLayout.LayoutParams(-1, dp(56)));
    ScrollView scroll = new ScrollView(this);
    body = new LinearLayout(this);
    body.setOrientation(LinearLayout.VERTICAL);
    body.setPadding(dp(18), 0, dp(18), dp(28));
    scroll.addView(body);
    root.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
    setContentView(root);
    if (Build.VERSION.SDK_INT >= 30 && getWindow().getInsetsController() != null)
      getWindow()
          .getInsetsController()
          .setSystemBarsAppearance(
              dark
                  ? 0
                  : android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                      | android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
              android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                  | android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS);
    if (Arrays.asList("metrics", "day", "comparison", "history").contains(feature)
        && forecast.has("_updated")) {
      long age = Math.max(0, Instant.now().getEpochSecond() - forecast.optLong("_updated"));
      note(
          (age > 1800 ? "Saved forecast" : "Forecast snapshot")
              + " · updated "
              + DateTimeFormatter.ofPattern(
                      "MMM d, " + (prefs.getBoolean("clock24", false) ? "HH:mm" : "h:mm a"))
                  .withZone(zone())
                  .format(Instant.ofEpochSecond(forecast.optLong("_updated")))
              + (age > 1800 ? " · refresh the main screen for new data" : ""));
    }
    switch (feature) {
      case "history" -> history();
      case "station" -> station();
      case "owner" -> owner();
      case "notifications" -> notifications();
      case "widgets", "widget" -> widgets();
      case "comparison" -> comparison();
      case "adaptive" -> adaptive();
      case "alerts" -> alerts();
      case "diagnostics" -> diagnostics();
      case "display" -> display();
      case "sources" -> sources();
      case "day" -> day();
      default -> metrics();
    }
    status = text("", 12, false);
    status.setTextColor(muted);
    status.setPadding(0, dp(14), 0, 0);
    body.addView(status);
  }

  String title() {
    return switch (feature) {
      case "history" -> "Weather history";
      case "station" -> "My weather station";
      case "owner" -> "Owner administration";
      case "notifications" -> "Notifications";
      case "widgets", "widget" -> "Widgets";
      case "comparison" -> "Compare sources";
      case "adaptive" -> "Adaptive weather";
      case "alerts" -> "Weather alerts";
      case "diagnostics" -> "Weather Lab";
      case "display" -> "On the main screen";
      case "sources" -> "Forecast sources";
      case "day" -> "Daily forecast";
      default -> getIntent().hasExtra("dayFilter") ? "Hourly forecast" : "48-hour forecast";
    };
  }

  void metrics() {
    heading(place.name());
    JSONObject hourly = forecast.optJSONObject("hourly");
    if (hourly == null) {
      note("Open the main forecast first, then try again.");
      return;
    }
    HorizontalScrollView scroll = new HorizontalScrollView(this);
    LinearLayout choices = new LinearLayout(this);
    for (String[] m : METRICS) {
      TextView choice = text(m[0], 13, metric.equals(m[0]));
      choice.setPadding(dp(12), dp(10), dp(12), dp(10));
      choice.setTextColor(metric.equals(m[0]) ? accent : muted);
      choice.setOnClickListener(
          v -> {
            metric = m[0];
            render();
          });
      choices.addView(choice);
    }
    scroll.addView(choices);
    body.addView(scroll);
    String[] selection =
        Arrays.stream(METRICS).filter(m -> m[0].equals(metric)).findFirst().orElse(METRICS[6]);
    JSONArray times = hourly.optJSONArray("time"), data = hourly.optJSONArray(selection[1]);
    if (times == null) return;
    List<Long> stamps = new ArrayList<>();
    List<Double> values = new ArrayList<>();
    long now = Instant.now().getEpochSecond();
    for (int i = 0; i < times.length() && stamps.size() < 48; i++) {
      if (times.optLong(i) < now - 1800) continue;
      if (getIntent().hasExtra("dayFilter")) {
        long selectedDay = getIntent().getLongExtra("dayFilter", 0);
        if (!Instant.ofEpochSecond(times.optLong(i))
            .atZone(zone())
            .toLocalDate()
            .equals(Instant.ofEpochSecond(selectedDay).atZone(zone()).toLocalDate())) continue;
      }
      stamps.add(times.optLong(i));
      values.add(convert(ForecastSources.number(data, i), selection[1]));
    }
    long[] t = new long[stamps.size()];
    double[] v = new double[values.size()];
    for (int i = 0; i < t.length; i++) {
      t[i] = stamps.get(i);
      v[i] = values.get(i);
    }
    TextView reading = text(metric + " · drag the chart", 17, true);
    reading.setPadding(0, dp(16), 0, dp(12));
    body.addView(reading);
    MetricChart chart =
        new MetricChart(
            this,
            t,
            v,
            muted,
            accent,
            dark ? 0xff444449 : 0xffd9d9df,
            index ->
                reading.setText(clock(t[index]) + " · " + number(v[index], unit(selection[1]))));
    body.addView(chart, new LinearLayout.LayoutParams(-1, dp(210)));
    note(
        "Hourly forecast · "
            + ForecastSources.fieldSource(forecast, "hourly", selection[1])
            + ". Gaps mean missing data.");
    for (int i = 0; i < t.length; i++) row(clock(t[i]), number(v[i], unit(selection[1])), null);
  }

  double convert(double value, String key) {
    if (key.equals("temperature_2m")
        || key.equals("apparent_temperature")
        || key.equals("dew_point_2m")) return celsius ? (value - 32) / 1.8 : value;
    if (key.equals("wind_speed_10m") || key.equals("wind_gusts_10m"))
      return celsius ? value * 1.609344 : value;
    if (key.equals("precipitation"))
      return prefs.getBoolean("rainInches", !celsius) ? value / 25.4 : value;
    if (key.equals("visibility")) return celsius ? value / 1000 : value / 1609.344;
    if (key.equals("snowfall"))
      return prefs.getBoolean("rainInches", !celsius) ? value / 2.54 : value;
    return value;
  }

  String unit(String key) {
    if (key.contains("temperature") || key.equals("dew_point_2m")) return "°";
    if (key.contains("wind_speed") || key.contains("wind_gust")) return celsius ? " km/h" : " mph";
    if (key.equals("precipitation"))
      return prefs.getBoolean("rainInches", !celsius) ? " in" : " mm";
    if (key.equals("visibility")) return celsius ? " km" : " mi";
    if (key.equals("snowfall")) return prefs.getBoolean("rainInches", !celsius) ? " in" : " cm";
    if (key.equals("pressure_msl")) return " hPa";
    if (key.contains("humidity")
        || key.equals("cloud_cover")
        || key.equals("precipitation_probability")) return "%";
    return "";
  }

  void day() {
    JSONObject d = forecast.optJSONObject("daily");
    int index = getIntent().getIntExtra("index", 0);
    JSONArray dates = d == null ? null : d.optJSONArray("time");
    if (dates == null || index >= dates.length()) {
      note("Daily detail is unavailable from the current source.");
      return;
    }
    long date = dates.optLong(index);
    heading(
        DateTimeFormatter.ofPattern("EEEE, MMM d")
            .withZone(zone())
            .format(Instant.ofEpochSecond(date)));
    row(
        "Conditions",
        MainActivity.condition(
            Double.isFinite(ForecastSources.number(d.optJSONArray("weather_code"), index))
                ? (int) ForecastSources.number(d.optJSONArray("weather_code"), index)
                : -1),
        null);
    row(
        "High / low",
        temp(ForecastSources.number(d.optJSONArray("temperature_2m_max"), index))
            + " / "
            + temp(ForecastSources.number(d.optJSONArray("temperature_2m_min"), index)),
        null);
    String[][] fields = {
      {"Chance", "precipitation_probability_max", "%"},
      {"Precipitation", "precipitation_sum", ""},
      {"Snow", "snowfall_sum", ""},
      {"Peak wind", "wind_speed_10m_max", ""},
      {"Peak gust", "wind_gusts_10m_max", ""},
      {"UV index", "uv_index_max", ""},
      {"Feels-like high", "apparent_temperature_max", "°"},
      {"Feels-like low", "apparent_temperature_min", "°"}
    };
    for (String[] field : fields) {
      double value = ForecastSources.number(d.optJSONArray(field[1]), index);
      String key =
          switch (field[1]) {
            case "precipitation_sum" -> "precipitation";
            case "snowfall_sum" -> "snowfall";
            case "wind_speed_10m_max" -> "wind_speed_10m";
            case "wind_gusts_10m_max" -> "wind_gusts_10m";
            case "apparent_temperature_max", "apparent_temperature_min" -> "apparent_temperature";
            default -> field[1];
          };
      row(field[0], number(convert(value, key), field[2].isEmpty() ? unit(key) : field[2]), null);
    }
    for (String sun : new String[] {"sunrise", "sunset"}) {
      double value = ForecastSources.number(d.optJSONArray(sun), index);
      row(
          sun.equals("sunrise") ? "Sunrise" : "Sunset",
          Double.isFinite(value) ? clock((long) value) : "—",
          null);
    }
    note(
        "Daily forecast · "
            + forecast.optString("_dailySource", "Forecast")
            + ". Daily probability definitions differ between providers.");
    button(
        "Explore hourly statistics",
        () -> {
          try {
            startActivity(
                new Intent(this, FeatureActivity.class)
                    .putExtra("feature", "metrics")
                    .putExtra("place", place.json().toString())
                    .putExtra("dayFilter", date));
          } catch (Exception ignored) {
          }
        });
  }

  void history() {
    heading("Today in context");
    JSONObject d = forecast.optJSONObject("daily");
    int todayIndex = DailyData.today(forecast, zone());
    if (d != null)
      row(
          "Forecast high / low",
          temp(ForecastSources.number(d.optJSONArray("temperature_2m_max"), todayIndex))
              + " / "
              + temp(ForecastSources.number(d.optJSONArray("temperature_2m_min"), todayIndex)),
          null);
    if (historyComparison != null) {
      JSONObject last = historyComparison.optJSONObject("last");
      row(
          historyComparison.optString("lastDate") + " high / low",
          temp(ForecastSources.number(last.optJSONArray("temperature_2m_max"), 0))
              + " / "
              + temp(ForecastSources.number(last.optJSONArray("temperature_2m_min"), 0)),
          null);
      row(
          "1991–2020 high / low",
          temp(ForecastSources.number(historyComparison, "high"))
              + " / "
              + temp(ForecastSources.number(historyComparison, "low")),
          null);
      double
          today =
              d == null
                  ? Double.NaN
                  : ForecastSources.number(d.optJSONArray("temperature_2m_max"), todayIndex),
          normal = ForecastSources.number(historyComparison, "high");
      if (Double.isFinite(today) && Double.isFinite(normal))
        note(
            number(Math.abs(today - normal) / (celsius ? 1.8 : 1), "°")
                + " "
                + (today >= normal ? "above" : "below")
                + " the historical average high.");
      note(
          historyComparison.optInt("samples")
              + " matching calendar days; at least 20 complete years are required.");
    } else button("Load comparison", this::loadHistory);
    heading("Explore a past day");
    row(
        "Past date",
        historyDate,
        () -> {
          WeatherSheet pickerSheet = new WeatherSheet(this, dark, "Choose a past date", null);
          DatePicker picker =
              new DatePicker(
                  this, null, 0, dark ? R.style.CalendarPicker_Dark : R.style.CalendarPicker);
          picker.setMaxDate(System.currentTimeMillis() - 7L * 86400 * 1000);
          picker.setMinDate(
              LocalDate.of(1940, 1, 1)
                  .atStartOfDay(ZoneId.systemDefault())
                  .toInstant()
                  .toEpochMilli());
          LocalDate initial = LocalDate.parse(historyDate);
          final LocalDate[] selected = {initial};
          picker.init(
              initial.getYear(),
              initial.getMonthValue() - 1,
              initial.getDayOfMonth(),
              (view, y, m, day) -> selected[0] = LocalDate.of(y, m + 1, day));
          pickerSheet
              .custom(picker)
              .primary(
                  "Use date",
                  () -> {
                    historyDate = selected[0].toString();
                    historyDay = null;
                    pickerSheet.dismiss();
                    render();
                    loadSelectedHistory();
                  })
              .show();
        });
    button(
        historyDay == null ? "Load selected day" : "Reload selected day",
        this::loadSelectedHistory);
    if (historyDay != null) {
      heading(historyDay.optJSONArray("time").optString(0));
      row(
          "High",
          temp(ForecastSources.number(historyDay.optJSONArray("temperature_2m_max"), 0)),
          null);
      row(
          "Low",
          temp(ForecastSources.number(historyDay.optJSONArray("temperature_2m_min"), 0)),
          null);
      row(
          "Mean",
          temp(ForecastSources.number(historyDay.optJSONArray("temperature_2m_mean"), 0)),
          null);
    }
    note(
        "Open-Meteo · ECMWF ERA5 reanalysis. These are gridded historical estimates, not an"
            + " official station climate normal. Today's values are forecasts; source and grid"
            + " differences affect comparisons. February 29 may have insufficient matching years.");
  }

  void loadSelectedHistory() {
    String date = historyDate;
    async(
        "Loading ERA5 history…",
        () -> HistoryArchive.fetch(place, date, date, forecast.optString("timezone", "auto")),
        value -> {
          if (historyDate.equals(date)) {
            historyDay = value;
            render();
          }
        });
  }

  void loadHistory() {
    async(
        "Loading historical comparison…",
        () ->
            HistoryArchive.comparison(
                this, place, LocalDate.now(zone()), forecast.optString("timezone", "auto")),
        value -> {
          historyComparison = value;
          render();
        });
  }

  void alerts() {
    heading(place.name());
    if (forecast.optBoolean("_alertsOutside")) {
      note("The NWS alert feed does not cover this location.");
      return;
    }
    long checked = forecast.optLong("_alertsChecked");
    boolean stale =
        forecast.optBoolean("_alertsUnavailable")
            || checked == 0
            || Instant.now().getEpochSecond() - checked > 1800;
    note(
        stale
            ? "Alerts are unavailable or out of date. Refresh the main forecast."
            : "NWS · checked " + clock(checked));
    List<JSONObject> alerts =
        WeatherAlerts.active(forecast.optJSONArray("_alerts"), Instant.now().getEpochSecond());
    for (JSONObject p : alerts) {
      heading(p.optString("event", "Weather alert"));
      note(
          p.optString("severity")
              + " · "
              + p.optString("senderName")
              + "\n"
              + p.optString("areaDesc"));
      note(p.optString("headline"));
      for (String date : new String[] {"sent", "onset", "expires", "ends"})
        if (!p.isNull(date)) note(date + ": " + p.optString(date));
      note(p.optString("description"));
      if (!p.isNull("instruction")) note(p.optString("instruction"));
    }
    if (alerts.isEmpty() && !stale) note("No active alerts returned for this point.");
    note(
        "United States and territories only. This is an in-app official alert feed, not guaranteed"
            + " push warning delivery. Keep official emergency alerts enabled.");
  }

  void comparison() {
    heading("Actual sources");
    JSONArray members = forecast.optJSONArray("_members");
    JSONObject weights = forecast.optJSONObject("_weights");
    if (members == null) {
      note("Refresh the forecast to load source comparisons.");
      return;
    }
    java.util.List<SourceComparisonChart.Line> lines = new java.util.ArrayList<>();
    if (forecast.has("_weights")) addComparisonLine(lines, "Blend", forecast, ink);
    for (int i = 0; i < members.length(); i++) {
      JSONObject member = members.optJSONObject(i);
      String name = member.optString("name");
      if (name.equals("Foreca") || name.equals("Open-Meteo"))
        addComparisonLine(
            lines,
            name,
            member.optJSONObject("forecast"),
            name.equals("Foreca") ? accent : 0xffd59b36);
    }
    if (lines.size() >= 2) {
      body.addView(
          new SourceComparisonChart(this, lines, muted, dark ? 0xff444449 : 0xffd9d9df),
          new LinearLayout.LayoutParams(-1, dp(180)));
      for (var line : lines) {
        TextView legend = text("━ " + line.name(), 12, false);
        legend.setTextColor(line.color());
        body.addView(legend);
      }
      note(
          "One line per forecast for the next 24 hours. The gap is disagreement, not a confidence"
              + " band.");
    }
    long now = Instant.now().getEpochSecond();
    double low = Double.POSITIVE_INFINITY, high = Double.NEGATIVE_INFINITY;
    int count = 0;
    for (int i = 0; i < members.length(); i++) {
      JSONObject member = members.optJSONObject(i),
          f = member.optJSONObject("forecast"),
          h = f.optJSONObject("hourly");
      double temperature = Double.NaN;
      if (h != null) {
        JSONArray times = h.optJSONArray("time");
        if (times != null)
          for (int j = 0; j < times.length(); j++)
            if (times.optLong(j) >= now - 1800) {
              temperature = ForecastSources.number(h.optJSONArray("temperature_2m"), j);
              break;
            }
      }
      String name = member.optString("name");
      row(name, temp(temperature), null);
      if (weights != null && weights.has(name))
        note("Near-term weight: " + number(ForecastSources.number(weights, name), ""));
      if (Double.isFinite(temperature)) {
        low = Math.min(low, temperature);
        high = Math.max(high, temperature);
        count++;
      }
    }
    if (count >= 2)
      note(
          "Near-term source range: "
              + temp(low)
              + " to "
              + temp(high)
              + " across "
              + count
              + " sources. This is source disagreement, not a calibrated confidence interval.");
    note(
        "The blend averages only supplied values. Wet and dry sources can average to light rain;"
            + " inspect individual sources and use single-source mode when needed. Starting weights"
            + " are assumptions; no accuracy gain has been established.");
  }

  void addComparisonLine(
      java.util.List<SourceComparisonChart.Line> lines, String name, JSONObject data, int color) {
    if (data == null) return;
    JSONObject hourly = data.optJSONObject("hourly");
    JSONArray time = hourly == null ? null : hourly.optJSONArray("time");
    if (time == null) return;
    java.util.List<Long> times = new java.util.ArrayList<>();
    java.util.List<Double> values = new java.util.ArrayList<>();
    long now = Instant.now().getEpochSecond();
    for (int i = 0; i < time.length() && times.size() < 24; i++) {
      if (time.optLong(i) < now - 1800) continue;
      times.add(time.optLong(i));
      values.add(
          convert(
              ForecastSources.number(hourly.optJSONArray("temperature_2m"), i), "temperature_2m"));
    }
    long[] t = new long[times.size()];
    double[] v = new double[times.size()];
    for (int i = 0; i < t.length; i++) {
      t[i] = times.get(i);
      v[i] = values.get(i);
    }
    lines.add(new SourceComparisonChart.Line(name, t, v, color));
  }

  void adaptive() {
    heading("Local evidence");
    note(service.evidence.summary());
    toggle(
        "Collect & verify forecasts",
        "verifyStations",
        false,
        () -> {
          prefs
              .edit()
              .putInt("evidenceGeneration", prefs.getInt("evidenceGeneration", 0) + 1)
              .apply();
          WeatherJob.schedule(this);
        });
    toggle("Background collection", "backgroundCollection", false, () -> WeatherJob.schedule(this));
    toggle("Adaptive temperature in single-source mode", "adaptiveEnabled", false, () -> {});
    note(
        "Verification uses independent NWS station history within 15 km. Forecasts must be saved at"
            + " least 30 minutes ahead; observed times must be within 15 minutes. Minimum 20 paired"
            + " hours over 5 days, a 0.5°F difference and held-out improvement gate single-source"
            + " changes. Temperature evidence adjusts blend weights only after shared-hour/day"
            + " gates. It does not calibrate rain.");
    if (prefs.getBoolean("verifyStations", false))
      button(
          "Verify saved forecasts",
          () ->
              async(
                  "Checking independent station history…",
                  () -> {
                    service.evidence.verify(place, true);
                    return new JSONObject();
                  },
                  v -> render()));
    button(
        "Clear local evidence",
        () -> {
          WeatherSheet confirmation =
              new WeatherSheet(
                  this,
                  dark,
                  "Clear local evidence?",
                  "Saved forecasts and scores will be removed.");
          confirmation.primary(
              "Clear evidence",
              () -> {
                service.evidence.clear();
                confirmation.dismiss();
                render();
              });
          confirmation.show();
        });
    JSONObject state = files.read("evidence");
    JSONArray samples = state.optJSONArray("samples");
    if (samples != null) {
      Map<String, List<Double>> groups = new TreeMap<>();
      for (int i = 0; i < samples.length(); i++) {
        JSONObject s = samples.optJSONObject(i);
        if (!s.optString("place").equals(LocalData.placeKey(place))) continue;
        String key =
            s.optString("provider")
                + " · "
                + new String[] {"0–6 h", "6–24 h", "1–3 d", "3+ d"}
                    [Math.max(0, Math.min(3, s.optInt("bucket")))];
        groups
            .computeIfAbsent(key, k -> new ArrayList<>())
            .add(Math.abs(ForecastSources.number(s, "error")));
      }
      for (var entry : groups.entrySet())
        row(
            entry.getKey(),
            number(
                    entry.getValue().stream()
                        .mapToDouble(Double::doubleValue)
                        .average()
                        .orElse(Double.NaN),
                    "°F MAE")
                + " · "
                + entry.getValue().size(),
            null);
    }
  }

  void notifications() {
    heading("Rain forecasts");
    toggle(
        "Rain notifications",
        "rainNotifications",
        false,
        () -> {
          if (prefs.getBoolean("rainNotifications", false)) enableNotifications(false);
          else RainNotifications.cancel(this);
          WeatherJob.schedule(this);
        });
    String[] leads = {"15 minutes", "30 minutes", "60 minutes"};
    option(
        "Lead time",
        prefs.getInt("rainLead", 15) + " minutes",
        leads,
        i -> {
          prefs.edit().putInt("rainLead", new int[] {15, 30, 60}[i]).apply();
          replan();
        });
    String[] chances = {"20%", "30%", "40%", "50%", "60%", "70%", "80%", "90%"};
    option(
        "Minimum chance",
        prefs.getInt("rainChance", 50) + "%",
        chances,
        i -> {
          prefs.edit().putInt("rainChance", 20 + 10 * i).apply();
          replan();
        });
    button("Send a test notification", () -> enableNotifications(true));
    note(
        "Hourly forecasts cannot promise minute-accurate rain onset. Warnings look up to 12 hours"
            + " ahead and include the source. Android may delay alarms and background refresh,"
            + " particularly under battery restrictions. This uses the last selected location, not"
            + " background GPS.");
    String pending = prefs.getString("rainPending", "");
    note(
        pending.isEmpty()
            ? "No future warning is currently scheduled."
            : "A forecast-based warning is scheduled for the selected location.");
    if (!getSystemService(NotificationManager.class).areNotificationsEnabled())
      button(
          "Open system notification settings",
          () ->
              startActivity(
                  new Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                      .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, getPackageName())));
  }

  void enableNotifications(boolean test) {
    testAfterPermission = test;
    if (Build.VERSION.SDK_INT >= 33
        && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED) {
      requestPermissions(new String[] {Manifest.permission.POST_NOTIFICATIONS}, 20);
      return;
    }
    if (test)
      RainNotifications.show(
          this, "KlierSky test", "This is a test notification, not a rain forecast.");
    else {
      prefs.edit().putBoolean("rainNotifications", true).apply();
      replan();
    }
    WeatherJob.schedule(this);
  }

  @Override
  public void onRequestPermissionsResult(int request, String[] permissions, int[] results) {
    super.onRequestPermissionsResult(request, permissions, results);
    if (request == 20) {
      boolean allowed = results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED;
      if (!testAfterPermission) prefs.edit().putBoolean("rainNotifications", allowed).apply();
      if (allowed) enableNotifications(testAfterPermission);
      render();
    }
  }

  void replan() {
    try {
      RainNotifications.update(this, place, forecast);
    } catch (Exception ignored) {
    }
    WeatherJob.schedule(this);
    WeatherJob.request(this);
  }

  void station() {
    heading("Server connection");
    if (station != null) {
      JSONObject obs = station.optJSONObject("observation");
      if (obs != null) {
        row(
            obs.optString("name", "Station"),
            temp(ForecastSources.number(obs, "temperature")),
            null);
        note(
            obs.optString("provider")
                + " · observed "
                + clock(obs.optLong("timestamp"))
                + (Instant.now().getEpochSecond() - obs.optLong("timestamp") > 1200
                    ? " · Out of date"
                    : ""));
        row("Humidity", number(ForecastSources.number(obs, "humidity"), "%"), null);
        row(
            "Wind",
            number(
                convert(ForecastSources.number(obs, "wind"), "wind_speed_10m"),
                unit("wind_speed_10m")),
            null);
        row("UV", number(ForecastSources.number(obs, "uv"), ""), null);
        row("Pressure", number(ForecastSources.number(obs, "pressure"), " hPa"), null);
        double latitude = ForecastSources.number(obs, "latitude"),
            longitude = ForecastSources.number(obs, "longitude");
        if (Double.isFinite(latitude) && Double.isFinite(longitude)) {
          float[] distance = new float[1];
          android.location.Location.distanceBetween(
              latitude, longitude, place.latitude(), place.longitude(), distance);
          row(
              "From forecast location",
              number(
                  celsius ? distance[0] / 1000 : distance[0] / 1609.344, celsius ? " km" : " mi"),
              null);
        }
      }
      if (station.optBoolean("configured"))
        button(
            "Disconnect station",
            () -> {
              WeatherSheet confirm =
                  new WeatherSheet(
                      this,
                      dark,
                      "Disconnect station?",
                      "Delete this device's station credentials from your server.");
              confirm.primary(
                  "Disconnect",
                  () -> {
                    confirm.dismiss();
                    async(
                        "Disconnecting…",
                        () -> service.gateway("v1/station", "DELETE", null),
                        v -> {
                          station = v;
                          render();
                        });
                  });
              confirm.show();
            });
    }
    String provider = prefs.getString("stationProvider", "tempest");
    option(
        "Station service",
        provider.equals("tempest") ? "Tempest" : "Weather Underground",
        new String[] {"Tempest", "Weather Underground"},
        i ->
            prefs.edit().putString("stationProvider", i == 0 ? "tempest" : "wunderground").apply());
    EditText id = field("Station ID", false),
        key = field(provider.equals("tempest") ? "Personal access token" : "PWS API key", true);
    button(
        "Connect station",
        () -> {
          String stationID = id.getText().toString().trim(),
              secret = key.getText().toString().trim();
          if (stationID.isEmpty() || secret.isEmpty()) {
            key.setError("Enter the station ID and credential");
            return;
          }
          key.setText("");
          async(
              "Connecting station…",
              () ->
                  service.gateway(
                      "v1/station",
                      "PUT",
                      new JSONObject()
                          .put("provider", provider)
                          .put("stationID", stationID)
                          .put("key", secret)),
              v -> {
                station = v;
                prefs.edit().putBoolean("featureChanged", true).apply();
                render();
              });
        });
    button("Reload station", this::loadStation);
    note(
        "Use a station you own or have permission to access. Its credential is sent over HTTPS and"
            + " stored privately on your server for this device. Readings stay separate from the"
            + " forecast, with their own time and location.");
    button(
        provider.equals("tempest") ? "Get a Tempest token" : "Weather Underground API keys",
        () ->
            startActivity(
                new Intent(
                    Intent.ACTION_VIEW,
                    android.net.Uri.parse(
                        provider.equals("tempest")
                            ? "https://tempestwx.com/settings/tokens"
                            : "https://www.wunderground.com/member/api-keys"))));
    if (provider.equals("wunderground"))
      note("Use the contributor PWS data API key, not the station upload key.");
  }

  void loadStation() {
    async(
        "Loading station…",
        () -> service.gateway("v1/station", "GET", null),
        v -> {
          station = v;
          render();
        });
  }

  JSONObject admin(String path, String method, JSONObject body) throws Exception {
    String token = service.owner.read();
    if (token.isEmpty()) throw new java.io.IOException("Owner access required");
    return WeatherService.request(BuildConfig.GATEWAY_URL + "/" + path, method, token, body);
  }

  void owner() {
    heading("Owner sign-in");
    if (service.owner.read().isEmpty()) {
      EditText code = field("One-time pairing code", true);
      code.setInputType(
          android.text.InputType.TYPE_CLASS_NUMBER
              | android.text.InputType.TYPE_NUMBER_VARIATION_PASSWORD);
      button(
          "Pair as owner",
          () -> {
            String value = code.getText().toString();
            if (!value.matches("[0-9]{8}")) {
              code.setError("Enter the eight-digit code");
              return;
            }
            code.setText("");
            async(
                "Pairing…",
                () -> {
                  service.pairOwner(value);
                  return new JSONObject();
                },
                v -> {
                  prefs.edit().putBoolean("featureChanged", true).apply();
                  render();
                  loadDevices();
                });
          });
      EditText token = field("Owner token (advanced)", true);
      button(
          "Save owner token",
          () -> {
            String value = token.getText().toString().trim();
            token.setText("");
            if (value.isEmpty()) return;
            async(
                "Checking owner access…",
                () -> {
                  JSONObject reply =
                      WeatherService.request(
                          BuildConfig.GATEWAY_URL + "/v1/admin/devices", "GET", value, null);
                  service.owner.save(value);
                  return reply;
                },
                v -> {
                  devices = v;
                  prefs.edit().putBoolean("featureChanged", true).apply();
                  render();
                });
          });
      note(
          "Owner access is encrypted with Android Keystore. Family members do not need owner"
              + " sign-in or the Foreca key.");
      return;
    }
    note("Owner access is saved on this phone.");
    button(
        "Remove owner access from this phone",
        () -> {
          WeatherSheet confirm =
              new WeatherSheet(
                  this,
                  dark,
                  "Remove owner access?",
                  "This phone will return to its read-only device access.");
          confirm.primary(
              "Remove owner access",
              () -> {
                service.owner.clear();
                confirm.dismiss();
                prefs.edit().putBoolean("featureChanged", true).apply();
                devices = null;
                render();
              });
          confirm.show();
        });
    heading("Devices");
    if (devices != null) {
      String mode = devices.optString("enrollment", "approval");
      option(
          "New devices",
          mode,
          new String[] {"Join automatically", "Need my approval", "Not accepted"},
          i ->
              async(
                  "Updating enrollment…",
                  () ->
                      admin(
                          "v1/admin/enrollment",
                          "PUT",
                          new JSONObject()
                              .put("mode", new String[] {"open", "approval", "closed"}[i])),
                  v -> {
                    devices = v;
                    render();
                  }));
      JSONArray list = devices.optJSONArray("devices");
      if (list != null)
        for (int i = 0; i < list.length(); i++) {
          JSONObject device = list.optJSONObject(i);
          String id = device.optString("deviceID", device.optString("id"));
          if (!id.matches("[a-f0-9]{16}")) continue;
          String state = device.optString("status"), label = device.optString("label", "Device");
          heading(label);
          note(
              state
                  + " · Code "
                  + device.optString("code")
                  + " · "
                  + device.optInt("requestsToday")
                  + " requests today");
          if (state.equals("pending"))
            button("Approve " + label, () -> deviceAction(id, "approve"));
          if (!state.equals("revoked")) button("Revoke " + label, () -> deviceAction(id, "revoke"));
          else
            button(
                "Forget " + label,
                () ->
                    async(
                        "Removing record…",
                        () -> admin("v1/admin/devices/" + id, "DELETE", null),
                        v -> {
                          devices = v;
                          render();
                        }));
        }
    }
    button("Reload devices", this::loadDevices);
    heading("Foreca key");
    EditText key = field("Foreca API key", true);
    button(
        "Send key to my server",
        () -> {
          String value = key.getText().toString().trim();
          key.setText("");
          if (value.isEmpty()) return;
          async(
              "Sending securely…",
              () -> admin("credentials", "PUT", new JSONObject().put("forecaKey", value)),
              v -> {
                prefs.edit().putBoolean("featureChanged", true).apply();
                status.setText("Key saved on your server. It was not stored on this phone.");
              });
        });
    note(
        "Needed once per server, not per phone. Existing server credentials do not need to be"
            + " entered again.");
  }

  void deviceAction(String id, String action) {
    WeatherSheet confirm =
        new WeatherSheet(
            this,
            dark,
            action.equals("approve") ? "Approve this device?" : "Revoke this device?",
            action.equals("approve")
                ? "Grant read-only forecast access."
                : "Block this device from your weather service.");
    confirm.primary(
        action.equals("approve") ? "Approve" : "Revoke",
        () -> {
          confirm.dismiss();
          async(
              "Updating device…",
              () -> admin("v1/admin/devices/" + id + "/" + action, "POST", new JSONObject()),
              v -> {
                devices = v;
                render();
              });
        });
    confirm.show();
  }

  void loadDevices() {
    async(
        "Loading devices…",
        () -> admin("v1/admin/devices", "GET", null),
        v -> {
          devices = v;
          render();
        });
  }

  void diagnostics() {
    heading("Local diagnostics");
    note(
        "The log is bounded to 150 events. It excludes coordinates, URLs, API keys and access"
            + " tokens.");
    note(files.diagnostics());
    button(
        "Export sanitized diagnostics",
        () ->
            startActivity(
                Intent.createChooser(
                    new Intent(Intent.ACTION_SEND)
                        .setType("text/plain")
                        .putExtra(Intent.EXTRA_TEXT, files.diagnostics()),
                    "Share diagnostics")));
    button(
        "Clear diagnostics",
        () -> {
          files.remove("diagnostics");
          render();
        });
  }

  void display() {
    heading("Forecast sections");
    for (String[] setting :
        new String[][] {
          {"Wind under the temperature", "showWind"},
          {"Daily forecast", "showDaily"},
          {"Current details", "showDetails"},
          {"Compare forecast sources", "showComparison"},
          {"Humidity & dew point", "showHumidity"},
          {"Pressure", "showPressure"},
          {"Visibility", "showVisibility"},
          {"Sunrise & sunset", "showSun"}
        }) toggle(setting[0], setting[1], !setting[1].equals("showComparison"), () -> {});
  }

  void sources() {
    heading("Forecast mode");
    option(
        "Forecast",
        prefs.getString("forecastMode", "blend").equals("blend")
            ? "Blend of all sources"
            : "One source",
        new String[] {"Blend of all sources", "One source"},
        i -> prefs.edit().putString("forecastMode", i == 0 ? "blend" : "single").apply());
    option(
        "Preferred source",
        prefs.getString("preferredProvider", "Foreca"),
        new String[] {"Foreca", "Open-Meteo"},
        i -> prefs.edit().putString("preferredProvider", i == 0 ? "Foreca" : "Open-Meteo").apply());
    toggle("Model futurecast (HRRR)", "modelFuturecast", true, () -> {});
    note(
        "Foreca stays on your server. Free sources include Open-Meteo, ECMWF, NOAA GFS, DWD ICON,"
            + " UK Met Office, Météo-France, Canada GEM, MET Norway and NWS where available. Failed"
            + " sources are omitted and missing readings stay missing. The starting weights are"
            + " assumptions, not measured accuracy.");
    note(
        "Open-Meteo's free API is for non-commercial use. MET Norway requires attribution under CC"
            + " BY 4.0; NWS/NOAA data are public domain. Map futurecast uses NOAA HRRR via Iowa"
            + " Environmental Mesonet; point-only Foreca access does not grant Foreca map access.");
    button(
        "Foreca",
        () ->
            startActivity(
                new Intent(Intent.ACTION_VIEW, android.net.Uri.parse("https://www.foreca.com/"))));
    button(
        "Open-Meteo · CC BY 4.0",
        () ->
            startActivity(
                new Intent(
                    Intent.ACTION_VIEW,
                    android.net.Uri.parse("https://open-meteo.com/en/licence"))));
    button(
        "MET Norway · CC BY 4.0",
        () ->
            startActivity(
                new Intent(
                    Intent.ACTION_VIEW, android.net.Uri.parse("https://api.met.no/doc/License"))));
    button(
        "NWS / NOAA",
        () ->
            startActivity(
                new Intent(Intent.ACTION_VIEW, android.net.Uri.parse("https://www.weather.gov/"))));
    button(
        "NOAA HRRR / Iowa Environmental Mesonet",
        () ->
            startActivity(
                new Intent(
                    Intent.ACTION_VIEW,
                    android.net.Uri.parse("https://mesonet.agron.iastate.edu/GIS/model.phtml"))));
    button(
        "RainViewer",
        () ->
            startActivity(
                new Intent(
                    Intent.ACTION_VIEW, android.net.Uri.parse("https://www.rainviewer.com/"))));
    button("Compare sources", () -> open(this, "comparison", place, 0));
    button("Adaptive weather", () -> open(this, "adaptive", place, 0));
  }

  void widgets() {
    heading(feature.equals("widget") ? "Widget location" : "Add a widget");
    note(
        "Widgets show source and update age. They use the last known or chosen location; they do"
            + " not request background GPS. Lock Screen placement depends on the Android system's"
            + " widget host.");
    if (feature.equals("widget")) {
      button("Current location (last known)", () -> configureWidget(place, true));
      option(
          "Temperature & wind",
          widgetCelsius ? "°C · km/h" : "°F · mph",
          new String[] {"°F · mph", "°C · km/h"},
          i -> widgetCelsius = i == 1);
      button("Use last shown location · " + place.name(), () -> configureWidget(place));
      try {
        JSONArray saved = new JSONArray(prefs.getString("favorites", "[]"));
        for (int i = 0; i < saved.length(); i++) {
          var city = WeatherService.Place.parse(saved.getJSONObject(i));
          button(city.name(), () -> configureWidget(city));
        }
      } catch (Exception ignored) {
      }
      return;
    }
    AppWidgetManager manager = AppWidgetManager.getInstance(this);
    String[] names = {"Current conditions", "Hourly forecast", "Daily forecast"};
    for (int i = 0; i < WeatherWidgets.types().length; i++) {
      Class<?> type = WeatherWidgets.types()[i];
      button(
          names[i],
          () -> {
            if (manager.isRequestPinAppWidgetSupported())
              manager.requestPinAppWidget(new ComponentName(this, type), null, null);
            else
              Toast.makeText(
                      this,
                      "Touch and hold your Home Screen, choose Widgets, then KlierSky.",
                      Toast.LENGTH_LONG)
                  .show();
          });
    }
  }

  void configureWidget(WeatherService.Place location) {
    configureWidget(location, false);
  }

  void configureWidget(WeatherService.Place location, boolean followCurrent) {
    if (widgetID == AppWidgetManager.INVALID_APPWIDGET_ID) return;
    try {
      prefs
          .edit()
          .putString(
              "widget-" + widgetID,
              new JSONObject()
                  .put("place", location.json())
                  .put("followCurrent", followCurrent)
                  .put("celsius", widgetCelsius)
                  .toString())
          .apply();
      WeatherWidgets.updateAll(this);
      WeatherJob.schedule(this);
      WeatherJob.request(this);
      setResult(RESULT_OK, new Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetID));
      finish();
    } catch (Exception ignored) {
    }
  }

  @Override
  protected void onDestroy() {
    worker.shutdownNow();
    super.onDestroy();
  }
}
