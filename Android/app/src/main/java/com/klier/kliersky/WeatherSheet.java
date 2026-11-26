package com.klier.kliersky;

import android.app.Activity;
import android.app.Dialog;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.os.Build;
import android.view.*;
import android.widget.*;

/** Shared, accessible native sheet styling for preferences, places and forecast details. */
final class WeatherSheet {
  private final Activity activity;
  private final Dialog dialog;
  private final LinearLayout body;
  private final boolean dark;
  private final int ink, muted, accent, groupColor, lineColor;
  private LinearLayout group;
  private final GradientDrawable glass;

  WeatherSheet(Activity activity, boolean dark, String title, String subtitle) {
    this.activity = activity;
    this.dark = dark;
    ink = dark ? 0xffeff4f8 : 0xff17212b;
    muted = dark ? 0xffa5b0bd : 0xff637181;
    accent = dark ? 0xff79c9f1 : 0xff087695;
    groupColor = dark ? 0xff272e38 : 0xffffffff;
    lineColor = dark ? 0xff3a424e : 0xffe7ecf1;
    dialog = new Dialog(activity, dark ? R.style.WeatherSheet_Dark : R.style.WeatherSheet);
    dialog.setCanceledOnTouchOutside(true);
    LinearLayout shell =
        new LinearLayout(activity) {
          @Override
          protected void onMeasure(int width, int height) {
            int maximum = (int) (getResources().getDisplayMetrics().heightPixels * .86f);
            super.onMeasure(width, MeasureSpec.makeMeasureSpec(maximum, MeasureSpec.AT_MOST));
          }
        };
    shell.setOrientation(LinearLayout.VERTICAL);
    glass = background(dark ? 0xf51b222b : 0xf5f2f5f9, 30);
    glass.setStroke(dp(1), dark ? 0x557e8d9d : 0xccffffff);
    shell.setBackground(glass);
    shell.setClipToOutline(true);
    shell.setPadding(dp(18), dp(9), dp(18), dp(16));
    LinearLayout gripArea = new LinearLayout(activity);
    gripArea.setGravity(Gravity.CENTER);
    View grip = new View(activity);
    grip.setBackground(background(dark ? 0xff596471 : 0xffb8c2cc, 3));
    gripArea.addView(grip, new LinearLayout.LayoutParams(dp(34), dp(4)));
    shell.addView(gripArea, new LinearLayout.LayoutParams(-1, dp(15)));
    gripArea.setOnTouchListener(
        new View.OnTouchListener() {
          float start;

          public boolean onTouch(View view, MotionEvent event) {
            if (event.getAction() == MotionEvent.ACTION_DOWN) {
              start = event.getRawY();
              return true;
            }
            if (event.getAction() == MotionEvent.ACTION_UP) {
              if (event.getRawY() - start > dp(45)) dialog.dismiss();
              view.performClick();
              return true;
            }
            return true;
          }
        });
    LinearLayout header = new LinearLayout(activity);
    header.setGravity(Gravity.CENTER_VERTICAL);
    TextView heading = text(title, 25, ink, true);
    if (Build.VERSION.SDK_INT >= 28) heading.setAccessibilityHeading(true);
    header.addView(heading, new LinearLayout.LayoutParams(0, -2, 1));
    TextView close = text("×", 25, muted, false);
    close.setGravity(Gravity.CENTER);
    close.setBackground(ripple(background(dark ? 0xff303945 : 0xffe3e9ef, 24)));
    close.setContentDescription("Close " + title);
    close.setOnClickListener(v -> dismiss());
    close.setFocusable(true);
    header.addView(close, new LinearLayout.LayoutParams(dp(44), dp(44)));
    shell.addView(header);
    if (subtitle != null && !subtitle.isEmpty()) {
      TextView description = text(subtitle, 13, muted, false);
      description.setPadding(0, dp(5), dp(8), dp(14));
      shell.addView(description);
    }
    ScrollView scroll = new ScrollView(activity);
    scroll.setFillViewport(false);
    scroll.setVerticalScrollBarEnabled(false);
    body = new LinearLayout(activity);
    body.setOrientation(LinearLayout.VERTICAL);
    scroll.addView(body);
    shell.addView(scroll, new LinearLayout.LayoutParams(-1, -2));
    dialog.setContentView(shell);
  }

  private int dp(int value) {
    return Math.round(value * activity.getResources().getDisplayMetrics().density);
  }

  private GradientDrawable background(int color, int radius) {
    GradientDrawable shape = new GradientDrawable();
    shape.setColor(color);
    shape.setCornerRadius(dp(radius));
    return shape;
  }

  private RippleDrawable ripple(GradientDrawable shape) {
    return new RippleDrawable(
        ColorStateList.valueOf(dark ? 0x2279c9f1 : 0x18087695), shape, background(Color.WHITE, 18));
  }

  private TextView text(String value, int size, int color, boolean bold) {
    TextView view = new TextView(activity);
    view.setText(value);
    view.setTextSize(size);
    view.setTextColor(color);
    view.setIncludeFontPadding(false);
    view.setTypeface(Typeface.create(bold ? "sans-serif-medium" : "sans-serif", Typeface.NORMAL));
    return view;
  }

  WeatherSheet section(String label) {
    TextView title = text(label, 12, muted, true);
    title.setPadding(dp(8), dp(16), 0, dp(8));
    if (Build.VERSION.SDK_INT >= 28) title.setAccessibilityHeading(true);
    body.addView(title);
    group = null;
    return this;
  }

  WeatherSheet row(String title, String detail, String value, boolean selected, Runnable action) {
    if (group == null) {
      group = new LinearLayout(activity);
      group.setOrientation(LinearLayout.VERTICAL);
      group.setBackground(background(groupColor, 20));
      group.setClipToOutline(true);
      body.addView(group, new LinearLayout.LayoutParams(-1, -2));
    } else {
      View divider = new View(activity);
      divider.setBackgroundColor(lineColor);
      LinearLayout.LayoutParams separator = new LinearLayout.LayoutParams(-1, dp(1));
      separator.setMargins(dp(16), 0, dp(16), 0);
      group.addView(divider, separator);
    }
    LinearLayout row = new LinearLayout(activity);
    row.setGravity(Gravity.CENTER_VERTICAL);
    row.setPadding(dp(16), dp(14), dp(14), dp(14));
    row.setMinimumHeight(dp(56));
    LinearLayout labels = new LinearLayout(activity);
    labels.setOrientation(LinearLayout.VERTICAL);
    labels.addView(text(title, 16, ink, false));
    if (detail != null && !detail.isEmpty()) {
      TextView secondary = text(detail, 12, muted, false);
      secondary.setPadding(0, dp(5), dp(8), 0);
      labels.addView(secondary);
    }
    row.addView(labels, new LinearLayout.LayoutParams(0, -2, 1));
    if (value != null && !value.isEmpty()) {
      TextView reading = text(value, 13, muted, false);
      reading.setPadding(dp(8), 0, dp(9), 0);
      row.addView(reading);
    }
    TextView indicator =
        text(
            selected ? "✓" : action == null ? "" : "›",
            selected ? 20 : 24,
            selected ? accent : muted,
            true);
    indicator.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
    row.addView(indicator);
    row.setBackground(ripple(background(Color.TRANSPARENT, 0)));
    if (action != null) {
      row.setOnClickListener(
          v -> {
            navigate(action);
          });
      row.setFocusable(true);
    }
    row.setAccessibilityDelegate(
        new View.AccessibilityDelegate() {
          @Override
          public void onInitializeAccessibilityNodeInfo(
              View host, android.view.accessibility.AccessibilityNodeInfo info) {
            super.onInitializeAccessibilityNodeInfo(host, info);
            info.setSelected(selected);
          }
        });
    group.addView(row, new LinearLayout.LayoutParams(-1, -2));
    return this;
  }

  WeatherSheet choice(String title, String detail, boolean selected, Runnable action) {
    row(title, detail, null, selected, action);
    LinearLayout row = (LinearLayout) group.getChildAt(group.getChildCount() - 1);
    ((TextView) row.getChildAt(row.getChildCount() - 1)).setText(selected ? "✓" : "");
    return this;
  }

  WeatherSheet message(String value) {
    TextView message = text(value, 14, muted, false);
    message.setLineSpacing(dp(3), 1f);
    message.setPadding(dp(4), dp(12), dp(4), dp(14));
    body.addView(message);
    group = null;
    return this;
  }

  WeatherSheet custom(View view) {
    body.addView(view, new LinearLayout.LayoutParams(-1, -2));
    group = null;
    return this;
  }

  EditText input(String hint) {
    EditText field = new EditText(activity);
    field.setHint(hint);
    field.setTextColor(ink);
    field.setHintTextColor(muted);
    field.setTextSize(17);
    field.setSingleLine(true);
    field.setPadding(dp(16), dp(14), dp(16), dp(14));
    field.setBackground(background(groupColor, 18));
    body.addView(field, new LinearLayout.LayoutParams(-1, -2));
    group = null;
    return field;
  }

  WeatherSheet primary(String title, Runnable action) {
    TextView button = text(title, 16, dark ? 0xff101820 : Color.WHITE, true);
    button.setGravity(Gravity.CENTER);
    button.setMinimumHeight(dp(50));
    button.setBackground(ripple(background(accent, 25)));
    button.setOnClickListener(v -> action.run());
    button.setFocusable(true);
    LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
    lp.topMargin = dp(14);
    body.addView(button, lp);
    group = null;
    return this;
  }

  void show() {
    if (activity.isFinishing() || activity.isDestroyed()) return;
    dialog.show();
    Window window = dialog.getWindow();
    if (window == null) return;
    window.setBackgroundDrawable(background(dark ? 0xf01b222b : 0xf0f2f5f9, 30));
    boolean blurEnabled =
        Build.VERSION.SDK_INT >= 31
            && activity.getSystemService(WindowManager.class).isCrossWindowBlurEnabled();
    glass.setColor(
        blurEnabled ? (dark ? 0xf51b222b : 0xf5f2f5f9) : (dark ? 0xff1b222b : 0xfff2f5f9));
    window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
    window.setDimAmount(.32f);
    window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
    window.setGravity(Gravity.BOTTOM);
    int width = Math.min(activity.getResources().getDisplayMetrics().widthPixels - dp(24), dp(560));
    window.setLayout(width, WindowManager.LayoutParams.WRAP_CONTENT);
    WindowManager.LayoutParams params = window.getAttributes();
    params.y = dp(12);
    window.setAttributes(params);
    window.setWindowAnimations(R.style.WeatherSheetAnimation);
    if (blurEnabled) window.setBackgroundBlurRadius(dp(28));
  }

  private void navigate(Runnable action) {
    // Remove the previous sheet immediately; the next sheet owns its entrance transition.
    Window window = dialog.getWindow();
    if (window != null) window.setWindowAnimations(0);
    dismiss();
    action.run();
  }

  void dismiss() {
    dialog.dismiss();
  }
}
