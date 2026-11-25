package com.klier.kliersky;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.graphics.Color;
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
import org.json.JSONArray;
import org.json.JSONObject;
import org.maplibre.android.MapLibre;
import org.maplibre.android.camera.CameraPosition;
import org.maplibre.android.geometry.LatLng;
import org.maplibre.android.maps.MapView;
import org.maplibre.android.maps.MapLibreMap;
import org.maplibre.android.maps.Style;
import org.maplibre.android.annotations.MarkerOptions;
import org.maplibre.android.style.layers.RasterLayer;
import org.maplibre.android.style.layers.PropertyFactory;
import org.maplibre.android.style.sources.RasterSource;
import org.maplibre.android.style.sources.TileSet;
import java.time.Instant;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

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
    private boolean dark, celsius, expanded, savedMap, playing;
    private int foreground, muted, surface, accent, frameIndex, requestGeneration;
    private boolean started, resumed;
    private LocationManager locationManager;
    private LocationListener locationListener;
    private final Runnable play = new Runnable() {
        @Override public void run() {
            if (!playing || result == null || result.radar().isEmpty()) return;
            showFrame((frameIndex + 1) % result.radar().size());
            handler.postDelayed(this, 800);
        }
    };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        MapLibre.getInstance(this);
        preferences = getSharedPreferences("weather", MODE_PRIVATE);
        service = new WeatherService(this);
        place = new WeatherService.Place("Milwaukee", 43.0389, -87.9065);
        String saved = preferences.getString("selectedPlace", "");
        if (!saved.isEmpty()) try { place = WeatherService.Place.parse(new JSONObject(saved)); } catch (Exception ignored) { }
        render();
        if (preferences.getBoolean("useCurrent", true)) useCurrent(); else refresh();
    }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private TextView text(String value, int size, boolean bold) {
        TextView view = new TextView(this);
        view.setText(value); view.setTextSize(size); view.setTextColor(foreground);
        if (bold) view.setTypeface(android.graphics.Typeface.DEFAULT, android.graphics.Typeface.BOLD);
        view.setPadding(0, dp(5), 0, dp(5));
        return view;
    }
    private Button button(String title, Runnable action) {
        Button button = new Button(this);
        button.setText(title); button.setTextColor(accent); button.setAllCaps(false);
        button.setOnClickListener(view -> action.run());
        return button;
    }
    private void heading(String value) {
        TextView view = text(value, 20, true);
        view.setPadding(0, dp(22), 0, dp(8)); content.addView(view);
    }
    private void note(String value) {
        if (value == null || value.isEmpty()) return;
        TextView view = text(value, 12, false); view.setTextColor(muted); content.addView(view);
    }
    private void row(String left, String right) {
        LinearLayout row = new LinearLayout(this); row.setGravity(Gravity.CENTER_VERTICAL);
        TextView label = text(left, 14, false);
        row.addView(label, new LinearLayout.LayoutParams(0, dp(37), 1));
        TextView value = text(right, 15, true); value.setGravity(Gravity.END); row.addView(value);
        content.addView(row);
    }
    private void disposeMap() {
        if (mapView == null) return;
        if (resumed) mapView.onPause();
        if (started) mapView.onStop();
        mapView.onDestroy(); mapView = null; map = null; mapStyle = null;
    }
    private void render() {
        playing = false; handler.removeCallbacks(play);
        disposeMap();
        celsius = preferences.getBoolean("celsius", false);
        int appearance = preferences.getInt("appearance", 0);
        dark = appearance == 2 || appearance == 0 && (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
        foreground = dark ? Color.WHITE : Color.rgb(22, 26, 30);
        muted = dark ? Color.LTGRAY : Color.DKGRAY;
        surface = dark ? Color.rgb(12, 15, 19) : Color.rgb(250, 250, 252);
        accent = dark ? Color.rgb(105, 197, 248) : Color.rgb(0, 104, 150);
        getWindow().setStatusBarColor(surface); getWindow().setNavigationBarColor(surface);
        getWindow().getDecorView().setSystemUiVisibility(dark ? 0 : View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR);
        ScrollView scroll = new ScrollView(this); scroll.setFillViewport(true); scroll.setBackgroundColor(surface);
        content = new LinearLayout(this); content.setOrientation(LinearLayout.VERTICAL); content.setPadding(dp(20), dp(16), dp(20), dp(24));
        scroll.addView(content); setContentView(scroll);
        scroll.setOnApplyWindowInsetsListener((view, insets) -> {
            view.setPadding(0, insets.getSystemWindowInsetTop(), 0, insets.getSystemWindowInsetBottom()); return insets;
        });
        LinearLayout header = new LinearLayout(this); header.setGravity(Gravity.CENTER_VERTICAL);
        header.addView(button("Locations", this::locations));
        TextView city = text(place.name(), 17, true); city.setGravity(Gravity.CENTER);
        header.addView(city, new LinearLayout.LayoutParams(0, dp(48), 1));
        header.addView(button("Settings", this::settings)); content.addView(header);
        status = text(result == null ? "Loading forecast…" : result.source() + " · updated " + clock(Instant.now().getEpochSecond()), 12, false);
        status.setTextColor(muted);
        if (result != null) drawForecast(); else content.addView(status);
        content.addView(button("Refresh weather", this::refresh));
        note("KlierSky Android alpha · " + BuildConfig.VERSION_NAME);
        note("Forecasts: Foreca when available, otherwise Open-Meteo. Observed radar: RainViewer. Map: OpenFreeMap / OpenMapTiles / OpenStreetMap contributors.");
        note("Android alpha has not yet ported the iOS blend, historical comparison, station setup, model futurecast, notifications or widgets.");
    }
    private String temperature(double value) {
        if (!Double.isFinite(value)) return "—";
        return Math.round(celsius ? (value - 32) * 5 / 9 : value) + "°";
    }
    private static double number(JSONObject object, String key) { return object == null || object.isNull(key) ? Double.NaN : object.optDouble(key, Double.NaN); }
    private static double number(JSONArray array, int index) { return array == null || array.isNull(index) ? Double.NaN : array.optDouble(index, Double.NaN); }
    private String rounded(double value, String suffix) { return Double.isFinite(value) ? Math.round(value) + suffix : "—"; }
    private ZoneId zone() {
        try { return ZoneId.of(result.forecast().optString("timezone", ZoneId.systemDefault().getId())); }
        catch (Exception ignored) { return ZoneId.systemDefault(); }
    }
    private String clock(long seconds) { return DateTimeFormatter.ofPattern("h:mm a").withZone(result == null ? ZoneId.systemDefault() : zone()).format(Instant.ofEpochSecond(seconds)); }
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
        JSONObject forecast = result.forecast(); JSONObject current = forecast.optJSONObject("current");
        TextView degrees = text(temperature(number(current, "temperature_2m")), 68, true); degrees.setGravity(Gravity.CENTER); content.addView(degrees);
        TextView summary = text(condition(current == null ? -1 : current.optInt("weather_code", -1)), 20, true); summary.setGravity(Gravity.CENTER); content.addView(summary);
        TextView feels = text("Feels " + temperature(number(current, "apparent_temperature")), 15, false); feels.setGravity(Gravity.CENTER); feels.setTextColor(muted); content.addView(feels);
        status.setGravity(Gravity.CENTER); content.addView(status);
        note(result.accessMessage());
        drawMap();
        JSONObject hourly = forecast.optJSONObject("hourly");
        if (hourly != null) {
            JSONArray times = hourly.optJSONArray("time"), temperatures = hourly.optJSONArray("temperature_2m");
            JSONArray chances = hourly.optJSONArray("precipitation_probability");
            heading("Hourly forecast"); int shown = 0; long now = Instant.now().getEpochSecond();
            if (times != null) for (int i = 0; i < times.length(); i++) {
                long timestamp = times.optLong(i);
                if (timestamp < now - 3600 || shown >= (expanded ? 24 : 6)) continue;
                row(clock(timestamp), temperature(number(temperatures, i)) + "   " + rounded(number(chances, i), "% rain")); shown++;
            }
            content.addView(button(expanded ? "Show 6 hours" : "Show 24 hours", () -> { expanded = !expanded; render(); }));
            heading("Daily forecast");
            JSONArray dailyRows = forecast.optJSONArray("dailyRows");
            if (dailyRows != null) {
                for (int i = 0; i < Math.min(10, dailyRows.length()); i++) {
                    JSONObject day = dailyRows.optJSONObject(i); if (day != null) row(day.optString("dateKey"), temperature(number(day, "high")) + " / " + temperature(number(day, "low")));
                }
            } else {
                JSONObject daily = forecast.optJSONObject("daily");
                if (daily != null && daily.optJSONArray("time") != null) {
                    JSONArray dates = daily.optJSONArray("time");
                    for (int i = 0; i < dates.length(); i++) {
                        String day = DateTimeFormatter.ofPattern("EEE, MMM d").withZone(zone()).format(Instant.ofEpochSecond(dates.optLong(i)));
                        row(day, temperature(number(daily.optJSONArray("temperature_2m_max"), i)) + " / " + temperature(number(daily.optJSONArray("temperature_2m_min"), i)));
                    }
                }
            }
            heading("More details");
            row("Humidity", rounded(number(current, "relative_humidity_2m"), "%"));
            double mph = number(current, "wind_speed_10m");
            row("Wind", rounded(celsius ? mph * 1.609344 : mph, celsius ? " km/h" : " mph"));
            content.addView(button("UV & humidity forecast", () -> detailForecast(hourly)));
        }
    }
    private void detailForecast(JSONObject hourly) {
        List<String> rows = new ArrayList<>(); JSONArray times = hourly.optJSONArray("time");
        if (times != null) for (int i = 0; i < times.length() && rows.size() < 48; i++) {
            if (times.optLong(i) < Instant.now().getEpochSecond() - 3600) continue;
            rows.add(clock(times.optLong(i)) + "  ·  UV " + rounded(number(hourly.optJSONArray("uv_index"), i), "") + "  ·  " + rounded(number(hourly.optJSONArray("relative_humidity_2m"), i), "% humidity"));
        }
        new AlertDialog.Builder(this).setTitle("48-hour detail forecast").setItems(rows.toArray(new String[0]), null).setPositiveButton("Done", null).show();
    }
    private void drawMap() {
        heading(savedMap ? "Saved locations" : "Observed radar");
        mapView = new MapView(this); mapView.onCreate(null);
        content.addView(mapView, new LinearLayout.LayoutParams(-1, dp(260)));
        mapView.setOnTouchListener((view, event) -> { view.getParent().requestDisallowInterceptTouchEvent(event.getAction() != MotionEvent.ACTION_UP); return false; });
        if (started) mapView.onStart(); if (resumed) mapView.onResume();
        mapView.getMapAsync(loaded -> {
            map = loaded;
            map.setCameraPosition(new CameraPosition.Builder().target(new LatLng(place.latitude(), place.longitude())).zoom(savedMap ? 3.5 : 5.5).build());
            map.setStyle(new Style.Builder().fromUri("https://tiles.openfreemap.org/styles/" + (dark ? "dark" : "positron")), style -> {
                mapStyle = style;
                if (savedMap) {
                    for (WeatherService.Place saved : favorites()) map.addMarker(new MarkerOptions().position(new LatLng(saved.latitude(), saved.longitude())).title(saved.name()));
                    map.setOnMarkerClickListener(marker -> {
                        for (WeatherService.Place saved : favorites()) if (Math.abs(saved.latitude() - marker.getPosition().getLatitude()) < 0.0001 && Math.abs(saved.longitude() - marker.getPosition().getLongitude()) < 0.0001) { select(saved); break; }
                        return true;
                    });
                } else {
                    for (int i = 0; i < result.radar().size(); i++) {
                        var frame = result.radar().get(i);
                        TileSet tiles = new TileSet("2.1.0", frame.template()); tiles.setMinZoom(0f); tiles.setMaxZoom(7f);
                        String id = "radar-" + i;
                        style.addSource(new RasterSource(id, tiles, 256));
                        style.addLayer(new RasterLayer(id, id).withProperties(PropertyFactory.rasterOpacity(0.001f), PropertyFactory.rasterFadeDuration(0f)));
                    }
                    showFrame(Math.max(0, result.radar().size() - 1));
                }
            });
        });
        frameLabel = text(result.radar().isEmpty() ? "Radar unavailable" : "Loading radar…", 12, false);
        if (!savedMap) {
            content.addView(frameLabel);
            SeekBar slider = new SeekBar(this); slider.setMax(Math.max(0, result.radar().size() - 1)); slider.setProgress(slider.getMax());
            slider.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
                public void onProgressChanged(SeekBar bar, int progress, boolean fromUser) { if (fromUser) { playing = false; handler.removeCallbacks(play); showFrame(progress); } }
                public void onStartTrackingTouch(SeekBar bar) { }
                public void onStopTrackingTouch(SeekBar bar) { }
            });
            content.addView(slider);
            content.addView(button("Play / pause radar", () -> { playing = !playing; handler.removeCallbacks(play); if (playing) handler.post(play); }));
            note("Past observations only · RainViewer · Model futurecast is pending the Android port.");
        }
        content.addView(button(savedMap ? "Back to radar" : "Saved locations map", () -> { savedMap = !savedMap; render(); }));
    }
    private void showFrame(int index) {
        if (result == null || result.radar().isEmpty()) return;
        frameIndex = Math.min(Math.max(index, 0), result.radar().size() - 1);
        if (mapStyle != null) for (int i = 0; i < result.radar().size(); i++) {
            RasterLayer layer = mapStyle.getLayerAs("radar-" + i);
            if (layer != null) layer.setProperties(PropertyFactory.rasterOpacity(i == frameIndex ? 0.75f : 0.001f));
        }
        if (frameLabel != null) frameLabel.setText("Observed " + clock(result.radar().get(frameIndex).seconds()));
    }
    private void refresh() {
        int generation = ++requestGeneration;
        if (status != null) status.setText("Refreshing weather…");
        WeatherService.Place selected = place;
        worker.execute(() -> {
            try {
                var loaded = service.load(selected);
                runOnUiThread(() -> { if (!isDestroyed() && generation == requestGeneration) { result = loaded; render(); } });
            } catch (Exception ignored) {
                runOnUiThread(() -> { if (!isDestroyed() && generation == requestGeneration && status != null) status.setText("Weather unavailable. Check your connection and tap Refresh."); });
            }
        });
    }
    private void select(WeatherService.Place next) {
        place = next; result = null; savedMap = false;
        try { preferences.edit().putString("selectedPlace", next.json().toString()).putBoolean("useCurrent", false).apply(); } catch (Exception ignored) { }
        render(); refresh();
    }
    private List<WeatherService.Place> favorites() {
        List<WeatherService.Place> saved = new ArrayList<>();
        try { JSONArray data = new JSONArray(preferences.getString("favorites", "[]")); for (int i = 0; i < data.length(); i++) saved.add(WeatherService.Place.parse(data.getJSONObject(i))); } catch (Exception ignored) { }
        return saved;
    }
    private void locations() {
        List<WeatherService.Place> saved = favorites();
        List<String> names = new ArrayList<>(); names.add("Use current location"); names.add("Search for a city"); names.add("Save / remove this location");
        for (var city : saved) names.add(city.name());
        new AlertDialog.Builder(this).setTitle("Locations").setItems(names.toArray(new String[0]), (dialog, index) -> {
            if (index == 0) { preferences.edit().putBoolean("useCurrent", true).apply(); useCurrent(); }
            else if (index == 1) search();
            else if (index == 2) saveFavorite();
            else select(saved.get(index - 3));
        }).setNegativeButton("Done", null).show();
    }
    private void saveFavorite() {
        List<WeatherService.Place> saved = favorites();
        boolean removed = saved.removeIf(item -> item.latitude() == place.latitude() && item.longitude() == place.longitude());
        if (!removed && saved.size() < 30) saved.add(place);
        JSONArray data = new JSONArray();
        try { for (var item : saved) data.put(item.json()); preferences.edit().putString("favorites", data.toString()).apply(); } catch (Exception ignored) { }
        Toast.makeText(this, removed ? "Favorite removed" : "Location saved", Toast.LENGTH_SHORT).show();
    }
    private void search() {
        EditText query = new EditText(this); query.setHint("City name"); query.setSingleLine(true);
        new AlertDialog.Builder(this).setTitle("Find a city").setView(query).setPositiveButton("Search", (dialog, which) -> {
            String value = query.getText().toString().trim(); if (value.length() < 2) return;
            worker.execute(() -> {
                try {
                    List<WeatherService.Place> found = WeatherService.search(value);
                    runOnUiThread(() -> {
                        if (isDestroyed()) return;
                        if (found.isEmpty()) { Toast.makeText(this, "No matching cities", Toast.LENGTH_LONG).show(); return; }
                        String[] names = found.stream().map(WeatherService.Place::name).toArray(String[]::new);
                        new AlertDialog.Builder(this).setTitle("Search results").setItems(names, (choice, index) -> select(found.get(index))).show();
                    });
                } catch (Exception ignored) { runOnUiThread(() -> Toast.makeText(this, "City search unavailable", Toast.LENGTH_LONG).show()); }
            });
        }).setNegativeButton("Cancel", null).show();
    }
    private void settings() {
        String[] choices = {"Appearance", celsius ? "Use Fahrenheit & mph" : "Use Celsius & km/h", "Current location on startup", "Foreca service access", "Android alpha feature status"};
        new AlertDialog.Builder(this).setTitle("Settings").setItems(choices, (dialog, index) -> {
            if (index == 0) new AlertDialog.Builder(this).setTitle("Appearance").setSingleChoiceItems(new String[]{"System", "Light", "Dark"}, preferences.getInt("appearance", 0), (choice, value) -> { preferences.edit().putInt("appearance", value).apply(); choice.dismiss(); render(); }).show();
            else if (index == 1) { preferences.edit().putBoolean("celsius", !celsius).apply(); render(); }
            else if (index == 2) { preferences.edit().putBoolean("useCurrent", true).apply(); useCurrent(); }
            else if (index == 3) new AlertDialog.Builder(this).setTitle("Foreca access").setMessage(result == null ? "Refresh to request service access. The owner approves your device on their iPhone." : result.accessMessage().isEmpty() ? "Connected to the server-held Foreca account with this device's read-only access." : result.accessMessage()).setPositiveButton("Check again", (d,w) -> refresh()).show();
            else new AlertDialog.Builder(this).setTitle("Android alpha").setMessage("Working core: current conditions, hourly and daily forecasts, unit/theme settings, current location, saved places, city search, Foreca access and observed radar.\n\nThe iOS blend, model futurecast, station connection, history, notifications and widgets still need porting.").setPositiveButton("Done", null).show();
        }).show();
    }
    private void useCurrent() {
        if (checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.ACCESS_COARSE_LOCATION}, 10); return;
        }
        locationManager = (LocationManager) getSystemService(LOCATION_SERVICE);
        try {
            String provider = locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER) ? LocationManager.NETWORK_PROVIDER : LocationManager.GPS_PROVIDER;
            locationListener = new LocationListener() {
                public void onLocationChanged(Location location) {
                    if (locationListener != null) locationManager.removeUpdates(this);
                    locationListener = null;
                    if (!Double.isFinite(location.getLatitude()) || !Double.isFinite(location.getLongitude())) return;
                    place = new WeatherService.Place("Current location", location.getLatitude(), location.getLongitude()); result = null;
                    try { preferences.edit().putString("selectedPlace", place.json().toString()).apply(); } catch (Exception ignored) { }
                    render(); refresh();
                }
                public void onProviderDisabled(String provider) { }
                public void onProviderEnabled(String provider) { }
                public void onStatusChanged(String provider, int status, Bundle extras) { }
            };
            locationManager.requestSingleUpdate(provider, locationListener, Looper.getMainLooper());
            handler.postDelayed(() -> {
                if (locationListener != null) {
                    locationManager.removeUpdates(locationListener); locationListener = null;
                    Toast.makeText(this, "Location unavailable. Choose a city in Locations.", Toast.LENGTH_LONG).show(); refresh();
                }
            }, 12000);
        } catch (Exception ignored) { Toast.makeText(this, "Location unavailable. Choose a city.", Toast.LENGTH_LONG).show(); refresh(); }
    }
    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(requestCode, permissions, results);
        if (requestCode == 10) {
            if (results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED) useCurrent();
            else { Toast.makeText(this, "Showing the saved city. Choose another in Locations.", Toast.LENGTH_LONG).show(); refresh(); }
        }
    }
    @Override public void onConfigurationChanged(Configuration configuration) { super.onConfigurationChanged(configuration); render(); }
    @Override protected void onStart() { super.onStart(); started = true; if (mapView != null) mapView.onStart(); }
    @Override protected void onResume() { super.onResume(); resumed = true; if (mapView != null) mapView.onResume(); }
    @Override protected void onPause() { resumed = false; playing = false; handler.removeCallbacks(play); if (mapView != null) mapView.onPause(); super.onPause(); }
    @Override protected void onStop() { started = false; if (mapView != null) mapView.onStop(); super.onStop(); }
    @Override public void onLowMemory() { super.onLowMemory(); if (mapView != null) mapView.onLowMemory(); }
    @Override protected void onDestroy() {
        worker.shutdownNow(); handler.removeCallbacksAndMessages(null);
        if (locationManager != null && locationListener != null) locationManager.removeUpdates(locationListener);
        disposeMap(); super.onDestroy();
    }
}
