package com.klier.kliersky;

import org.json.JSONArray;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

final class WeatherService {
    record Place(String name, double latitude, double longitude) {
        JSONObject json() throws Exception { return new JSONObject().put("name", name).put("latitude", latitude).put("longitude", longitude); }
        static Place parse(JSONObject value) throws Exception { return new Place(value.getString("name"), value.getDouble("latitude"), value.getDouble("longitude")); }
    }
    record RadarFrame(long seconds, String template) {}
    record Result(JSONObject forecast, String source, List<RadarFrame> radar, String accessMessage) {}
    final Credentials credentials;
    final android.content.SharedPreferences preferences;
    WeatherService(android.content.Context context) {
        credentials = new Credentials(context);
        preferences = context.getSharedPreferences("weather", android.content.Context.MODE_PRIVATE);
    }
    static String encode(String value) {
        try { return URLEncoder.encode(value, "UTF-8"); }
        catch (java.io.UnsupportedEncodingException impossible) { throw new IllegalStateException(impossible); }
    }
    static JSONObject request(String address, String method, String token, JSONObject body) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) new URL(address).openConnection();
        connection.setConnectTimeout(12000); connection.setReadTimeout(18000);
        connection.setInstanceFollowRedirects(false);
        connection.setRequestMethod(method);
        connection.setRequestProperty("User-Agent", "KlierSky-Android/0.1 personal testing");
        if (token != null && !token.isEmpty()) connection.setRequestProperty("Authorization", "Bearer " + token);
        try {
            if (body != null) {
                connection.setDoOutput(true); connection.setRequestProperty("Content-Type", "application/json");
                try (var output = connection.getOutputStream()) { output.write(body.toString().getBytes(StandardCharsets.UTF_8)); }
            }
            int status = connection.getResponseCode();
            if (status != 200 && status != 201) throw new java.io.IOException("HTTP " + status);
            try (var input = connection.getInputStream(); var output = new ByteArrayOutputStream()) {
                byte[] buffer = new byte[8192]; int count;
                while ((count = input.read(buffer)) != -1) {
                    if (output.size() + count > 4 * 1024 * 1024) throw new java.io.IOException("Response too large");
                    output.write(buffer, 0, count);
                }
                return new JSONObject(output.toString("UTF-8"));
            }
        } finally { connection.disconnect(); }
    }
    private JSONObject access() throws Exception {
        String saved = credentials.read();
        if (!saved.isEmpty()) return new JSONObject(saved);
        String install = preferences.getString("installID", "");
        if (install.isEmpty()) {
            install = java.util.UUID.randomUUID().toString().replace("-", "");
            if (!preferences.edit().putString("installID", install).commit()) throw new java.io.IOException("Storage unavailable");
        }
        JSONObject record = request(BuildConfig.GATEWAY_URL + "/v1/devices", "POST", null,
            new JSONObject().put("installID", install).put("label", "Android KlierSky 0.1"));
        credentials.save(record.toString());
        return record;
    }
    Result load(Place place) throws Exception {
        JSONObject forecast = null;
        String source = "Open-Meteo";
        String message = "";
        try {
            JSONObject record = access();
            String token = record.getString("accessToken");
            JSONObject status = request(BuildConfig.GATEWAY_URL + "/v1/devices/self", "GET", token, null);
            if (status.optString("status").equals("active")) {
                forecast = request(BuildConfig.GATEWAY_URL + "/forecast?latitude=" + place.latitude + "&longitude=" + place.longitude, "GET", token, null);
                source = "Foreca";
            } else {
                message = "Waiting for owner approval. Device code " + record.optString("code", "—") + ".";
            }
        } catch (Exception ignored) { message = "Foreca service unavailable. Using Open-Meteo."; }
        if (forecast == null) {
            String hourly = "temperature_2m,apparent_temperature,precipitation_probability,precipitation,weather_code,relative_humidity_2m,uv_index,wind_speed_10m";
            forecast = request("https://api.open-meteo.com/v1/forecast?latitude=" + place.latitude + "&longitude=" + place.longitude
                + "&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m,relative_humidity_2m&hourly=" + hourly
                + "&daily=temperature_2m_max,temperature_2m_min,weather_code,precipitation_probability_max&temperature_unit=fahrenheit&wind_speed_unit=mph&timeformat=unixtime&timezone=auto&forecast_days=10", "GET", null, null);
        }
        List<RadarFrame> frames = new ArrayList<>();
        try {
            JSONObject radar = request("https://api.rainviewer.com/public/weather-maps.json", "GET", null, null);
            JSONArray past = radar.getJSONObject("radar").getJSONArray("past");
            String host = radar.getString("host");
            if (!host.startsWith("https://") || !new URL(host).getHost().endsWith("rainviewer.com")) throw new java.io.IOException("Unrecognized radar host");
            for (int i = 0; i < past.length(); i++) {
                JSONObject item = past.getJSONObject(i);
                frames.add(new RadarFrame(item.getLong("time"), host + item.getString("path") + "/256/{z}/{x}/{y}/2/1_1.png"));
            }
        } catch (Exception ignored) { /* An unavailable radar does not erase a valid forecast. */ }
        return new Result(forecast, source, frames, message);
    }
    static List<Place> search(String query) throws Exception {
        JSONObject reply = request("https://geocoding-api.open-meteo.com/v1/search?count=8&language=en&name=" + encode(query), "GET", null, null);
        List<Place> places = new ArrayList<>();
        JSONArray values = reply.optJSONArray("results");
        if (values != null) for (int i = 0; i < values.length(); i++) {
            JSONObject row = values.getJSONObject(i);
            places.add(new Place(row.getString("name") + ", " + row.optString("admin1", row.optString("country")), row.getDouble("latitude"), row.getDouble("longitude")));
        }
        return places;
    }
}
