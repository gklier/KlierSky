package com.klier.kliersky;

public final class WidgetConfigureActivity extends FeatureActivity {
  @Override
  public void onCreate(android.os.Bundle state) {
    getIntent().putExtra("feature", "widget");
    int id = getIntent().getIntExtra(android.appwidget.AppWidgetManager.EXTRA_APPWIDGET_ID, -1);
    android.appwidget.AppWidgetProviderInfo info =
        android.appwidget.AppWidgetManager.getInstance(this).getAppWidgetInfo(id);
    if (info == null || !info.provider.getPackageName().equals(getPackageName())) {
      super.onCreate(state);
      setResult(RESULT_CANCELED);
      finish();
      return;
    }
    super.onCreate(state);
  }
}
