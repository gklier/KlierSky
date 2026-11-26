package com.klier.kliersky;

import android.content.Context;
import android.graphics.*;
import android.view.*;
import java.util.*;

/** Temperature forecasts on a common actual-time axis; disagreement is not a confidence band. */
final class SourceComparisonChart extends View {
  record Line(String name, long[] times, double[] values, int color) {}

  final List<Line> lines;
  final int ink, grid;
  final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
  final Path path = new Path();

  SourceComparisonChart(Context context, List<Line> lines, int ink, int grid) {
    super(context);
    this.lines = lines;
    this.ink = ink;
    this.grid = grid;
    setContentDescription(
        "One temperature line per forecast over the next 24 hours. Source disagreement is not a"
            + " confidence interval.");
  }

  float dp(float v) {
    return v * getResources().getDisplayMetrics().density;
  }

  @Override
  protected void onDraw(Canvas canvas) {
    double min = Double.POSITIVE_INFINITY, max = Double.NEGATIVE_INFINITY;
    long first = Long.MAX_VALUE, last = 0;
    for (Line line : lines)
      for (int i = 0; i < line.times().length; i++)
        if (Double.isFinite(line.values()[i])) {
          min = Math.min(min, line.values()[i]);
          max = Math.max(max, line.values()[i]);
          first = Math.min(first, line.times()[i]);
          last = Math.max(last, line.times()[i]);
        }
    if (!Double.isFinite(min) || last <= first) return;
    float left = dp(38), right = getWidth() - dp(6), top = dp(15), bottom = getHeight() - dp(23);
    double range = Math.max(1, max - min);
    paint.setStrokeWidth(dp(1));
    paint.setTextSize(dp(10));
    for (int i = 0; i < 3; i++) {
      float y = top + (bottom - top) * i / 2;
      paint.setColor(grid);
      canvas.drawLine(left, y, right, y, paint);
      paint.setColor(ink);
      canvas.drawText(
          String.format(java.util.Locale.getDefault(), "%.0f", max - range * i / 2),
          0,
          y + dp(4),
          paint);
    }
    for (Line line : lines) {
      path.reset();
      boolean started = false;
      for (int i = 0; i < line.times().length; i++) {
        if (!Double.isFinite(line.values()[i])) {
          started = false;
          continue;
        }
        float x = left + (right - left) * (line.times()[i] - first) / (last - first),
            y = bottom - (float) ((line.values()[i] - min) / range) * (bottom - top);
        if (!started) {
          path.moveTo(x, y);
          started = true;
        } else path.lineTo(x, y);
      }
      paint.setStyle(Paint.Style.STROKE);
      paint.setColor(line.color());
      paint.setStrokeWidth(dp(line.name().equals("Blend") ? 3 : 1.7f));
      canvas.drawPath(path, paint);
    }
    paint.setStyle(Paint.Style.FILL);
    paint.setColor(ink);
    canvas.drawText("Now", left, getHeight() - dp(4), paint);
    paint.setTextAlign(Paint.Align.RIGHT);
    canvas.drawText("+24 h", right, getHeight() - dp(4), paint);
    paint.setTextAlign(Paint.Align.LEFT);
  }
}
