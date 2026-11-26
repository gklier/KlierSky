package com.klier.kliersky;

import android.content.Context;
import android.graphics.*;
import android.view.*;

/**
 * Actual timestamp spacing, visible missing-data gaps and a scrubbed sample, never invented
 * precision.
 */
final class MetricChart extends View {
  interface Selection {
    void selected(int index);
  }

  final long[] times;
  final double[] values;
  final int ink, color, grid;
  final Selection selection;
  final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
  final Path path = new Path();
  int selected = -1;

  MetricChart(
      Context context,
      long[] times,
      double[] values,
      int ink,
      int color,
      int grid,
      Selection selection) {
    super(context);
    this.times = times;
    this.values = values;
    this.ink = ink;
    this.color = color;
    this.grid = grid;
    this.selection = selection;
    setContentDescription("Hourly forecast chart. Drag to inspect actual forecast samples.");
    setFocusable(true);
  }

  float dp(float v) {
    return v * getResources().getDisplayMetrics().density;
  }

  @Override
  protected void onDraw(Canvas c) {
    super.onDraw(c);
    if (times.length == 0) return;
    double minimum = Double.POSITIVE_INFINITY, maximum = Double.NEGATIVE_INFINITY;
    for (double v : values)
      if (Double.isFinite(v)) {
        minimum = Math.min(minimum, v);
        maximum = Math.max(maximum, v);
      }
    if (!Double.isFinite(minimum)) {
      paint.setColor(ink);
      paint.setTextSize(dp(14));
      c.drawText("No values available", dp(8), getHeight() / 2f, paint);
      return;
    }
    double range = Math.max(1, maximum - minimum);
    float left = dp(42), right = getWidth() - dp(8), top = dp(16), bottom = getHeight() - dp(28);
    long span = Math.max(1, times[times.length - 1] - times[0]);
    paint.setStyle(Paint.Style.STROKE);
    paint.setStrokeWidth(dp(1));
    paint.setColor(grid);
    for (int i = 0; i < 3; i++) {
      float y = top + (bottom - top) * i / 2;
      c.drawLine(left, y, right, y, paint);
      paint.setStyle(Paint.Style.FILL);
      paint.setColor(ink);
      paint.setTextSize(dp(10));
      c.drawText(
          String.format(java.util.Locale.getDefault(), "%.0f", maximum - range * i / 2),
          0,
          y + dp(4),
          paint);
      paint.setStyle(Paint.Style.STROKE);
      paint.setColor(grid);
    }
    path.reset();
    boolean drawing = false;
    for (int i = 0; i < values.length; i++) {
      if (!Double.isFinite(values[i])) {
        drawing = false;
        continue;
      }
      float x = left + (right - left) * (times[i] - times[0]) / span,
          y = bottom - (float) ((values[i] - minimum) / range) * (bottom - top);
      if (!drawing) {
        path.moveTo(x, y);
        drawing = true;
      } else path.lineTo(x, y);
    }
    paint.setColor(color);
    paint.setStrokeWidth(dp(2.2f));
    c.drawPath(path, paint);
    if (selected >= 0 && selected < times.length) {
      float x = left + (right - left) * (times[selected] - times[0]) / span;
      paint.setStrokeWidth(dp(1));
      c.drawLine(x, top, x, bottom, paint);
      if (Double.isFinite(values[selected])) {
        float y = bottom - (float) ((values[selected] - minimum) / range) * (bottom - top);
        paint.setStyle(Paint.Style.FILL);
        c.drawCircle(x, y, dp(4), paint);
      }
    }
    paint.setStyle(Paint.Style.FILL);
    paint.setColor(ink);
    paint.setTextSize(dp(10));
    c.drawText("Now", left, getHeight() - dp(5), paint);
    String end = "+" + ((times[times.length - 1] - times[0]) / 3600) + " h";
    paint.setTextAlign(Paint.Align.RIGHT);
    c.drawText(end, right, getHeight() - dp(5), paint);
    paint.setTextAlign(Paint.Align.LEFT);
  }

  @Override
  public boolean onTouchEvent(MotionEvent event) {
    if (times.length == 0) return false;
    if (event.getAction() == MotionEvent.ACTION_DOWN
        || event.getAction() == MotionEvent.ACTION_MOVE) {
      getParent().requestDisallowInterceptTouchEvent(true);
      double fraction =
          Math.max(0, Math.min(1, (event.getX() - dp(42)) / Math.max(1, getWidth() - dp(50))));
      long target = times[0] + (long) ((times[times.length - 1] - times[0]) * fraction);
      int best = 0;
      for (int i = 1; i < times.length; i++)
        if (Math.abs(times[i] - target) < Math.abs(times[best] - target)) best = i;
      selected = best;
      selection.selected(best);
      invalidate();
      return true;
    }
    if (event.getAction() == MotionEvent.ACTION_UP) {
      performClick();
      getParent().requestDisallowInterceptTouchEvent(false);
      return true;
    }
    return true;
  }

  @Override
  public boolean performClick() {
    super.performClick();
    return true;
  }
}
