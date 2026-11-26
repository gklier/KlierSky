package com.klier.kliersky;

import android.content.*;

public class RainReceiver extends BroadcastReceiver {
  @Override
  public void onReceive(Context context, Intent intent) {
    var prefs = context.getSharedPreferences("weather", 0);
    if (!prefs.getBoolean("rainNotifications", false)
        || System.currentTimeMillis() / 1000 > intent.getLongExtra("expires", 0)) return;
    String key = intent.getStringExtra("key");
    if (key == null
        || !key.equals(prefs.getString("rainPending", ""))
        || key.equals(prefs.getString("rainDelivered", ""))) return;
    prefs.edit().putString("rainDelivered", key).remove("rainPending").apply();
    RainNotifications.show(context, intent.getStringExtra("title"), intent.getStringExtra("body"));
  }
}
