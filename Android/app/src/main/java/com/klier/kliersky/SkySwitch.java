package com.klier.kliersky;

import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.*;
import android.view.*;
import android.widget.*;

/** One accessible, animated preference switch across the Android settings screens. */
final class SkySwitch extends CompoundButton {
  final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
  final boolean dark;
  float position;
  boolean ready;
  ValueAnimator animation;

  SkySwitch(Context context, boolean dark) {
    super(context);
    this.dark = dark;
    setButtonDrawable((android.graphics.drawable.Drawable) null);
    setClickable(true);
    setBackground(null);
    setFocusable(true);
    ready = true;
  }

  int dp(int value) {
    return Math.round(value * getResources().getDisplayMetrics().density);
  }

  @Override
  protected void onMeasure(int width, int height) {
    setMeasuredDimension(dp(55), dp(44));
  }

  @Override
  public CharSequence getAccessibilityClassName() {
    return Switch.class.getName();
  }

  @Override
  public void setChecked(boolean checked) {
    super.setChecked(checked);
    if (!ready) {
      position = checked ? 1 : 0;
      return;
    }
    if (animation != null) animation.cancel();
    if (!isShown() || !ValueAnimator.areAnimatorsEnabled()) {
      position = checked ? 1 : 0;
      invalidate();
      return;
    }
    animation = ValueAnimator.ofFloat(position, checked ? 1 : 0);
    animation.setDuration(180);
    animation.addUpdateListener(
        value -> {
          position = (float) value.getAnimatedValue();
          invalidate();
        });
    animation.start();
  }

  @Override
  protected void onDraw(Canvas c) {
    float left = dp(2), top = (getHeight() - dp(31)) / 2f;
    paint.setColor(isChecked() ? 0xff34c759 : dark ? 0xff636366 : 0xffe9e9eb);
    c.drawRoundRect(left, top, left + dp(51), top + dp(31), dp(16), dp(16), paint);
    paint.setColor(Color.WHITE);
    c.drawCircle(left + dp(15) + dp(21) * position, top + dp(15) + dp(1) / 2f, dp(13), paint);
  }

  @Override
  protected void onDetachedFromWindow() {
    if (animation != null) animation.cancel();
    super.onDetachedFromWindow();
  }
}
