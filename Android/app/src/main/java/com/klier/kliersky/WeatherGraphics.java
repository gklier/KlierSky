package com.klier.kliersky;

import android.content.Context;
import android.graphics.*;
import android.view.View;

/** Original weather and chart graphics using Android's system typeface. */
final class WeatherGraphics {
  static class Glyph extends View {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final int code, ink;
    private final boolean dark;

    Glyph(Context context, int code, int ink, boolean dark) {
      super(context);
      this.code = code;
      this.ink = ink;
      this.dark = dark;
      setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
    }

    @Override
    protected void onDraw(Canvas canvas) {
      super.onDraw(canvas);
      canvas.save();
      canvas.scale(getWidth() / 64f, getHeight() / 64f);
      if (code < 0) {
        paint.setColor(ink);
        paint.setTextSize(24);
        paint.setTextAlign(Paint.Align.CENTER);
        canvas.drawText("—", 32, 39, paint);
        canvas.restore();
        return;
      }
      boolean clear = code == 0;
      boolean partly = code == 1 || code == 2;
      if (clear || partly) {
        float x = clear ? 32 : 42, y = clear ? 31 : 22;
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(2.6f);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setColor(Color.rgb(241, 181, 63));
        for (int i = 0; i < 8; i++) {
          double angle = i * Math.PI / 4;
          canvas.drawLine(
              x + (float) Math.cos(angle) * 17,
              y + (float) Math.sin(angle) * 17,
              x + (float) Math.cos(angle) * 22,
              y + (float) Math.sin(angle) * 22,
              paint);
        }
        paint.setStyle(Paint.Style.FILL);
        canvas.drawCircle(x, y, 11, paint);
      }
      if (!clear) {
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(dark ? Color.rgb(219, 228, 237) : Color.rgb(77, 91, 105));
        canvas.drawRoundRect(9, 28, 56, 46, 9, 9, paint);
        canvas.drawCircle(25, 28, 12, paint);
        canvas.drawCircle(39, 31, 10, paint);
        if (code >= 51 && code <= 67 || code >= 80 && code <= 82 || code >= 95) {
          paint.setColor(Color.rgb(78, 167, 222));
          paint.setStyle(Paint.Style.STROKE);
          paint.setStrokeWidth(2.8f);
          paint.setStrokeCap(Paint.Cap.ROUND);
          for (int i = 0; i < 3; i++) canvas.drawLine(20 + 11 * i, 51, 17 + 11 * i, 57, paint);
        }
        if (code >= 71 && code <= 77 || code == 85 || code == 86) {
          paint.setColor(dark ? 0xffc9e9f7 : 0xff5286a0);
          paint.setStyle(Paint.Style.FILL);
          for (int i = 0; i < 3; i++) canvas.drawCircle(20 + 11 * i, 54, 2, paint);
        }
        if (code == 45 || code == 48) {
          paint.setColor(ink);
          paint.setAlpha(100);
          paint.setStrokeWidth(2);
          canvas.drawLine(13, 51, 50, 51, paint);
          paint.setAlpha(255);
        }
      }
      canvas.restore();
    }
  }

  static class Action extends View {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final String kind;
    private final int ink;

    Action(Context context, String kind, int ink) {
      super(context);
      this.kind = kind;
      this.ink = ink;
    }

    @Override
    protected void onDraw(Canvas canvas) {
      super.onDraw(canvas);
      canvas.save();
      canvas.scale(getWidth() / 44f, getHeight() / 44f);
      paint.setColor(ink);
      paint.setStrokeWidth(1.8f);
      paint.setStyle(Paint.Style.STROKE);
      paint.setStrokeCap(Paint.Cap.ROUND);
      if (kind.equals("search")) {
        canvas.drawCircle(20, 20, 6.5f, paint);
        canvas.drawLine(25, 25, 30, 30, paint);
      } else {
        for (int i = 0; i < 3; i++) {
          float y = 15 + i * 7, x = i == 1 ? 27 : 18;
          canvas.drawLine(13, y, x - 3, y, paint);
          canvas.drawLine(x + 3, y, 31, y, paint);
          canvas.drawCircle(x, y, 2.8f, paint);
        }
      }
      canvas.restore();
    }
  }

  static class Range extends View {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final double low, high, minimum, maximum;
    private final int track;

    Range(Context context, double low, double high, double minimum, double maximum, int track) {
      super(context);
      this.low = low;
      this.high = high;
      this.minimum = minimum;
      this.maximum = maximum;
      this.track = track;
      setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
    }

    @Override
    protected void onDraw(Canvas canvas) {
      float height = getResources().getDisplayMetrics().density * 4;
      float y = getHeight() / 2f;
      paint.setColor(track);
      canvas.drawRoundRect(0, y - height / 2, getWidth(), y + height / 2, height, height, paint);
      if (!Double.isFinite(low) || !Double.isFinite(high)) return;
      double span = Math.max(1, maximum - minimum);
      float left = (float) ((low - minimum) / span) * getWidth();
      float right = Math.max(left + height, (float) ((high - minimum) / span) * getWidth());
      paint.setShader(
          new LinearGradient(
              0,
              0,
              getWidth(),
              0,
              Color.rgb(103, 172, 207),
              Color.rgb(236, 182, 92),
              Shader.TileMode.CLAMP));
      canvas.drawRoundRect(left, y - height / 2, right, y + height / 2, height, height, paint);
      paint.setShader(null);
    }
  }

  static class Bars extends View {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final double[] values;
    private final String[] labels;
    private final int ink, color, grid;
    private final double maximum;

    Bars(
        Context context,
        double[] values,
        String[] labels,
        int ink,
        int color,
        int grid,
        double maximum) {
      super(context);
      this.values = values;
      this.labels = labels;
      this.ink = ink;
      this.color = color;
      this.grid = grid;
      this.maximum = maximum;
    }

    @Override
    protected void onDraw(Canvas canvas) {
      super.onDraw(canvas);
      float density = getResources().getDisplayMetrics().density;
      float top = 8 * density, bottom = getHeight() - 25 * density;
      float width = getWidth(), step = width / Math.max(1, values.length);
      paint.setStrokeWidth(density);
      paint.setColor(grid);
      paint.setStyle(Paint.Style.STROKE);
      paint.setPathEffect(new DashPathEffect(new float[] {3 * density, 4 * density}, 0));
      for (int i = 0; i < 3; i++) {
        float y = top + (bottom - top) * i / 2;
        canvas.drawLine(0, y, width, y, paint);
      }
      paint.setPathEffect(null);
      paint.setStyle(Paint.Style.FILL);
      paint.setColor(color);
      for (int i = 0; i < values.length; i++) {
        if (!Double.isFinite(values[i])) continue;
        float height = (float) (Math.max(0, values[i]) / Math.max(0.01, maximum)) * (bottom - top);
        float left = i * step + 2 * density, right = (i + 1) * step - 2 * density;
        canvas.drawRoundRect(left, bottom - height, right, bottom, 2 * density, 2 * density, paint);
      }
      paint.setColor(ink);
      paint.setTypeface(Typeface.DEFAULT);
      paint.setTextSize(10 * getResources().getDisplayMetrics().scaledDensity);
      for (int i = 0; i < labels.length; i += 3) {
        paint.setTextAlign(i == 0 ? Paint.Align.LEFT : Paint.Align.CENTER);
        float x = i == 0 ? 0 : (i + .5f) * step;
        canvas.drawText(labels[i], x, getHeight() - 6 * density, paint);
      }
      paint.setTextAlign(Paint.Align.LEFT);
    }
  }
}
