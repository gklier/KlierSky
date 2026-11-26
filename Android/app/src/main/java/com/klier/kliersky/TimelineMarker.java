package com.klier.kliersky;

import android.content.Context;
import android.graphics.*;
import android.view.View;

final class TimelineMarker extends View {
  final float fraction;
  final int color;
  final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);

  TimelineMarker(Context context, float fraction, int color) {
    super(context);
    this.fraction = fraction;
    this.color = color;
    setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
  }

  @Override
  protected void onDraw(Canvas canvas) {
    float density = getResources().getDisplayMetrics().density;
    float x = 16 * density + (getWidth() - 32 * density) * fraction;
    paint.setColor(color);
    paint.setStrokeWidth(density);
    canvas.drawLine(x, 0, x, getHeight(), paint);
    paint.setTextSize(8 * getResources().getDisplayMetrics().scaledDensity);
    paint.setTextAlign(Paint.Align.CENTER);
    canvas.drawText("NOW", x, getHeight() - 2 * density, paint);
  }
}
