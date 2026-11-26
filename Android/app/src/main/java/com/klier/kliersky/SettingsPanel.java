package com.klier.kliersky;

import android.app.Activity;
import android.app.Dialog;
import android.content.SharedPreferences;
import android.content.res.ColorStateList;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.os.Build;
import android.view.*;
import android.view.accessibility.AccessibilityNodeInfo;
import android.widget.*;
import java.util.function.Supplier;

/** Settings follows the iPhone form hierarchy: one tall panel and anchored preference menus. */
final class SettingsPanel {
  private final Activity activity;
  private final SharedPreferences preferences;
  private final Runnable changed, useCurrent, savedMap, refresh;
  private final Supplier<String> forecaStatus;
  private final java.util.function.Consumer<String> openFeature;
  private final Dialog dialog;
  private FrameLayout root;
  private LinearLayout body, group;
  private PopupWindow menu;
  private String page = "Settings";
  private boolean dark;
  private int ink, muted, accent, background, surface, separator;

  SettingsPanel(
      Activity activity,
      SharedPreferences preferences,
      Runnable changed,
      Runnable useCurrent,
      Runnable savedMap,
      Runnable refresh,
      Supplier<String> forecaStatus,
      java.util.function.Consumer<String> openFeature) {
    this.activity = activity;
    this.preferences = preferences;
    this.changed = changed;
    this.useCurrent = useCurrent;
    this.savedMap = savedMap;
    this.refresh = refresh;
    this.forecaStatus = forecaStatus;
    this.openFeature = openFeature;
    dialog = new Dialog(activity, R.style.WeatherSheet);
    dialog.setCanceledOnTouchOutside(true);
    dialog.setOnKeyListener(
        (d, key, event) -> {
          if (key == KeyEvent.KEYCODE_BACK
              && event.getAction() == KeyEvent.ACTION_UP
              && !page.equals("Settings")) {
            page = page.equals("Administration") ? "Settings" : "Administration";
            render();
            return true;
          }
          return false;
        });
    dialog.setOnDismissListener(
        d -> {
          if (menu != null) menu.dismiss();
        });
  }

  private int dp(int value) {
    return Math.round(value * activity.getResources().getDisplayMetrics().density);
  }

  private GradientDrawable rounded(int color, int radius) {
    GradientDrawable shape = new GradientDrawable();
    shape.setColor(color);
    shape.setCornerRadius(dp(radius));
    return shape;
  }

  private GradientDrawable panelBackground() {
    GradientDrawable shape = new GradientDrawable();
    shape.setColor(background);
    float radius = dp(28);
    shape.setCornerRadii(new float[] {radius, radius, radius, radius, 0, 0, 0, 0});
    return shape;
  }

  private TextView text(String value, int size, int color, boolean medium) {
    TextView view = new TextView(activity);
    view.setText(value);
    view.setTextSize(size);
    view.setTextColor(color);
    view.setIncludeFontPadding(false);
    view.setTypeface(Typeface.create(medium ? "sans-serif-medium" : "sans-serif", Typeface.NORMAL));
    return view;
  }

  private void colors() {
    int appearance = preferences.getInt("appearance", 0);
    dark =
        appearance == 2
            || appearance == 0
                && (activity.getResources().getConfiguration().uiMode
                        & Configuration.UI_MODE_NIGHT_MASK)
                    == Configuration.UI_MODE_NIGHT_YES;
    ink = dark ? Color.WHITE : 0xff111113;
    muted = dark ? 0xff98989f : 0xff6d6d75;
    accent = dark ? 0xff64b5f6 : 0xff007aff;
    background = dark ? 0xff1c1c1e : 0xfff2f2f7;
    surface = dark ? 0xff2c2c2e : Color.WHITE;
    separator = dark ? 0xff414144 : 0xffe0e0e5;
  }

  private void render() {
    colors();
    root = new FrameLayout(activity);
    root.setBackground(panelBackground());
    root.setClipToOutline(true);
    LinearLayout shell = new LinearLayout(activity);
    shell.setOrientation(LinearLayout.VERTICAL);
    FrameLayout header = new FrameLayout(activity);
    TextView title = text(page, 17, ink, true);
    title.setGravity(Gravity.CENTER);
    if (Build.VERSION.SDK_INT >= 28) title.setAccessibilityHeading(true);
    FrameLayout.LayoutParams titleLayout = new FrameLayout.LayoutParams(-1, -1);
    titleLayout.setMargins(dp(90), 0, dp(90), 0);
    header.addView(title, titleLayout);
    TextView done = text("Done", 17, accent, true);
    done.setGravity(Gravity.CENTER);
    done.setBackground(rounded(dark ? 0xff272729 : 0xffe8e8ee, 24));
    done.setOnClickListener(v -> dismiss());
    done.setContentDescription("Done");
    done.setFocusable(true);
    FrameLayout.LayoutParams doneLayout =
        new FrameLayout.LayoutParams(dp(72), dp(44), Gravity.END | Gravity.CENTER_VERTICAL);
    doneLayout.rightMargin = dp(16);
    header.addView(done, doneLayout);
    if (!page.equals("Settings")) {
      TextView back = text("‹ Back", 17, accent, false);
      back.setGravity(Gravity.CENTER_VERTICAL);
      back.setContentDescription("Back");
      back.setPadding(dp(16), 0, 0, 0);
      back.setFocusable(true);
      back.setOnClickListener(
          v -> {
            page = page.equals("Administration") ? "Settings" : "Administration";
            render();
          });
      header.addView(back, new FrameLayout.LayoutParams(dp(90), -1, Gravity.START));
    }
    shell.addView(header, new LinearLayout.LayoutParams(-1, dp(68)));
    ScrollView scroll = new ScrollView(activity);
    scroll.setVerticalScrollBarEnabled(false);
    scroll.setClipToPadding(false);
    body = new LinearLayout(activity);
    body.setOrientation(LinearLayout.VERTICAL);
    body.setPadding(dp(16), dp(2), dp(16), dp(30));
    group = null;
    scroll.addView(body);
    shell.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
    root.addView(shell, new FrameLayout.LayoutParams(-1, -1));
    if (page.equals("Settings")) settings();
    else if (page.equals("Administration")) administration();
    else if (page.equals("Foreca access")) {
      section("Foreca service");
      note("Your provider key stays on the server.\n\n" + forecaStatus.get());
      row(
          "Check again",
          null,
          false,
          () -> {
            dismiss();
            refresh.run();
          });
    } else {
      section("KlierSky " + BuildConfig.VERSION_NAME);
      note(
          "Working core: current conditions, hourly and daily forecasts, current location, saved"
              + " places, city search, Foreca access and observed radar.\n\n"
              + "The iOS blend, model futurecast, station connection, history, notifications and"
              + " widgets still need porting.");
    }
    dialog.setContentView(root);
    Window window = dialog.getWindow();
    if (window != null) window.setBackgroundDrawable(panelBackground());
  }

  private void section(String title) {
    TextView label = text(title, 15, muted, true);
    label.setPadding(dp(16), dp(20), dp(16), dp(10));
    if (Build.VERSION.SDK_INT >= 28) label.setAccessibilityHeading(true);
    body.addView(label);
    group = null;
  }

  private void ensureGroup() {
    if (group == null) {
      group = new LinearLayout(activity);
      group.setOrientation(LinearLayout.VERTICAL);
      group.setBackground(rounded(surface, 22));
      group.setClipToOutline(true);
      body.addView(group, new LinearLayout.LayoutParams(-1, -2));
    } else {
      View line = new View(activity);
      line.setBackgroundColor(separator);
      LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, dp(1));
      lp.setMargins(dp(16), 0, dp(16), 0);
      group.addView(line, lp);
    }
  }

  private LinearLayout rowBase(String label) {
    ensureGroup();
    LinearLayout row = new LinearLayout(activity);
    row.setGravity(Gravity.CENTER_VERTICAL);
    row.setPadding(dp(16), dp(12), dp(16), dp(12));
    row.setMinimumHeight(dp(51));
    row.addView(text(label, 17, ink, false), new LinearLayout.LayoutParams(0, -2, 1));
    row.setBackground(
        new RippleDrawable(
            ColorStateList.valueOf(dark ? 0x22ffffff : 0x11000000),
            new ColorDrawable(Color.TRANSPARENT),
            null));
    group.addView(row, new LinearLayout.LayoutParams(-1, -2));
    return row;
  }

  private void row(String label, String value, boolean picker, Runnable action) {
    LinearLayout row = rowBase(label);
    if (value != null) {
      TextView reading = text(value, 16, picker ? accent : muted, false);
      reading.setGravity(Gravity.END);
      reading.setMaxWidth(dp(190));
      reading.setPadding(dp(8), 0, dp(5), 0);
      row.addView(reading);
    }
    View arrow;
    if (picker) arrow = new PickerIndicator();
    else {
      TextView chevron = text("›", 25, muted, false);
      chevron.setGravity(Gravity.CENTER);
      arrow = chevron;
    }
    arrow.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
    row.addView(arrow, new LinearLayout.LayoutParams(dp(14), dp(22)));
    row.setFocusable(true);
    row.setOnClickListener(v -> action.run());
  }

  private void picker(
      String label,
      String value,
      String[] options,
      int selected,
      java.util.function.IntConsumer selection) {
    // Attach to the row itself, matching the iPhone's inline preference menu.
    row(label, value, true, () -> {});
    View anchor = group.getChildAt(group.getChildCount() - 1);
    anchor.setOnClickListener(v -> showMenu(anchor, label, options, selected, selection));
  }

  private void showMenu(
      View anchor,
      String title,
      String[] options,
      int selected,
      java.util.function.IntConsumer selection) {
    if (menu != null) menu.dismiss();
    LinearLayout choices = new LinearLayout(activity);
    choices.setOrientation(LinearLayout.VERTICAL);
    choices.setBackground(rounded(dark ? 0xff353537 : 0xfffcfcfe, 14));
    choices.setClipToOutline(true);
    for (int i = 0; i < options.length; i++) {
      if (i > 0) {
        View line = new View(activity);
        line.setBackgroundColor(separator);
        choices.addView(line, new LinearLayout.LayoutParams(-1, dp(1)));
      }
      final int index = i;
      LinearLayout item = new LinearLayout(activity);
      item.setGravity(Gravity.CENTER_VERTICAL);
      item.setPadding(dp(16), 0, dp(16), 0);
      TextView mark = text(i == selected ? "✓" : "", 18, accent, true);
      mark.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
      item.addView(mark, new LinearLayout.LayoutParams(dp(26), -2));
      item.addView(text(options[i], 17, ink, false), new LinearLayout.LayoutParams(0, -2, 1));
      item.setContentDescription(options[i]);
      item.setFocusable(true);
      item.setOnClickListener(
          v -> {
            menu.dismiss();
            selection.accept(index);
            changed.run();
            render();
          });
      item.setAccessibilityDelegate(
          new View.AccessibilityDelegate() {
            @Override
            public void onInitializeAccessibilityNodeInfo(View host, AccessibilityNodeInfo info) {
              super.onInitializeAccessibilityNodeInfo(host, info);
              info.setCheckable(true);
              info.setChecked(index == selected);
            }
          });
      choices.addView(item, new LinearLayout.LayoutParams(-1, dp(48)));
    }
    menu = new PopupWindow(choices, Math.min(dp(250), root.getWidth() - dp(32)), -2, true);
    menu.setBackgroundDrawable(rounded(dark ? 0xff353537 : 0xfffcfcfe, 14));
    menu.setElevation(dp(16));
    menu.setOutsideTouchable(true);
    menu.setInputMethodMode(PopupWindow.INPUT_METHOD_NOT_NEEDED);
    menu.setAnimationStyle(android.R.style.Animation_Dialog);
    choices.setContentDescription(title + " options");
    menu.showAsDropDown(anchor, 0, -dp(4), Gravity.END);
  }

  private void note(String value) {
    TextView text = text(value, 13, muted, false);
    text.setPadding(dp(16), dp(10), dp(16), dp(12));
    text.setLineSpacing(dp(2), 1);
    body.addView(text);
    group = null;
  }

  private void settings() {
    section("Appearance & units");
    int appearance = preferences.getInt("appearance", 0);
    picker(
        "Appearance",
        new String[] {"System", "Light", "Dark"}[appearance],
        new String[] {"System", "Light", "Dark"},
        appearance,
        v -> preferences.edit().putInt("appearance", v).apply());
    boolean celsius = preferences.getBoolean("celsius", false);
    picker(
        "Temperature & wind",
        celsius ? "°C · km/h" : "°F · mph",
        new String[] {"°F · mph", "°C · km/h"},
        celsius ? 1 : 0,
        v -> preferences.edit().putBoolean("celsius", v == 1).apply());
    boolean inches = preferences.getBoolean("rainInches", !celsius);
    picker(
        "Rain",
        inches ? "Inches" : "Millimeters",
        new String[] {"Millimeters", "Inches"},
        inches ? 1 : 0,
        v -> preferences.edit().putBoolean("rainInches", v == 1).apply());
    LinearLayout clockRow = rowBase("24-hour clock");
    SkySwitch clock = new SkySwitch(activity, dark);
    clock.setChecked(preferences.getBoolean("clock24", false));
    clock.setContentDescription("24-hour clock");
    clock.setOnCheckedChangeListener(
        (button, checked) -> {
          preferences.edit().putBoolean("clock24", checked).apply();
          changed.run();
        });
    clockRow.addView(clock);
    section("Locations");
    boolean current = preferences.getBoolean("useCurrent", true);
    picker(
        "When KlierSky opens",
        current ? "Current location" : "Last chosen city",
        new String[] {"Current location", "Last chosen city"},
        current ? 0 : 1,
        v -> {
          preferences.edit().putBoolean("useCurrent", v == 0).apply();
          if (v == 0) useCurrent.run();
        });
    row(
        "Saved locations map",
        null,
        false,
        () -> {
          dismiss();
          savedMap.run();
        });
    section("");
    row("Notifications", null, false, () -> openFeature.accept("notifications"));
    row("My weather station", null, false, () -> openFeature.accept("station"));
    row("Widgets", null, false, () -> openFeature.accept("widgets"));
    row(
        "Administration",
        null,
        false,
        () -> {
          page = "Administration";
          render();
        });
    note(
        "Administration contains forecast sources, screen options, diagnostics and server"
            + " settings.");
  }

  private void administration() {
    section("Forecast");
    row("Forecast sources", null, false, () -> openFeature.accept("sources"));
    row("Compare sources", null, false, () -> openFeature.accept("comparison"));
    row("On the main screen", null, false, () -> openFeature.accept("display"));
    row("Adaptive weather", null, false, () -> openFeature.accept("adaptive"));
    section("More");
    row("Weather history", null, false, () -> openFeature.accept("history"));
    row("Weather alerts", null, false, () -> openFeature.accept("alerts"));
    row("Weather Lab · diagnostics", null, false, () -> openFeature.accept("diagnostics"));
    row("Server & family access", null, false, () -> openFeature.accept("owner"));
    section("Service");
    row(
        "Foreca service access",
        null,
        false,
        () -> {
          page = "Foreca access";
          render();
        });
    row(
        "Refresh weather",
        null,
        false,
        () -> {
          dismiss();
          refresh.run();
        });
    note("Version " + BuildConfig.VERSION_NAME);
  }

  private final class PickerIndicator extends View {
    private final android.graphics.Paint paint =
        new android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG);

    PickerIndicator() {
      super(activity);
    }

    @Override
    protected void onDraw(android.graphics.Canvas canvas) {
      paint.setColor(accent);
      paint.setStrokeWidth(dp(1));
      paint.setStyle(android.graphics.Paint.Style.STROKE);
      paint.setStrokeCap(android.graphics.Paint.Cap.ROUND);
      paint.setStrokeJoin(android.graphics.Paint.Join.ROUND);
      float x = getWidth() / 2f, y = getHeight() / 2f;
      android.graphics.Path path = new android.graphics.Path();
      path.moveTo(x - dp(3), y - dp(3));
      path.lineTo(x, y - dp(6));
      path.lineTo(x + dp(3), y - dp(3));
      path.moveTo(x - dp(3), y + dp(3));
      path.lineTo(x, y + dp(6));
      path.lineTo(x + dp(3), y + dp(3));
      canvas.drawPath(path, paint);
    }
  }

  void show() {
    render();
    dialog.show();
    Window window = dialog.getWindow();
    if (window == null) return;
    window.setBackgroundDrawable(panelBackground());
    window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
    window.setDimAmount(.25f);
    window.setGravity(Gravity.BOTTOM);
    window.setLayout(-1, (int) (activity.getResources().getDisplayMetrics().heightPixels * .90f));
    WindowManager.LayoutParams params = window.getAttributes();
    params.y = 0;
    window.setAttributes(params);
    window.setWindowAnimations(R.style.WeatherSheetAnimation);
    if (Build.VERSION.SDK_INT >= 33)
      dialog
          .getOnBackInvokedDispatcher()
          .registerOnBackInvokedCallback(
              android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT,
              () -> {
                if (page.equals("Settings")) dismiss();
                else {
                  page = page.equals("Administration") ? "Settings" : "Administration";
                  render();
                }
              });
  }

  void dismiss() {
    dialog.dismiss();
  }
}
