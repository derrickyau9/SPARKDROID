package dev.sparkdroid.frameprobe;

import android.app.Activity;
import android.os.Bundle;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.view.View;
import android.view.WindowManager;
import android.util.Log;

public final class FrameActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        WindowManager.LayoutParams params=getWindow().getAttributes();
        params.preferredRefreshRate=getDisplay().getRefreshRate();
        getWindow().setAttributes(params);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        setContentView(new MovingView());
    }
    final class MovingView extends View {
        final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
        long start=System.nanoTime(), last=start;
        int draws=0, total=0;
        float observed=0;
        MovingView() {super(FrameActivity.this);}
        @Override protected void onAttachedToWindow() {
            super.onAttachedToWindow();
            if(android.os.Build.VERSION.SDK_INT>=35)setRequestedFrameRate(getDisplay().getRefreshRate());
        }
        @Override protected void onDraw(Canvas canvas) {
            long now=System.nanoTime();draws++;total++;
            if(now-last>=1_000_000_000L){observed=draws*1_000_000_000f/(now-last);Log.i("SPARKDROID_FRAME_TEST","drawCallbacksPerSecond="+observed+" displayHz="+getDisplay().getRefreshRate()+" total="+total);last=now;draws=0;}
            canvas.drawColor(Color.rgb(12,23,38));
            paint.setColor(Color.WHITE);paint.setTextSize(32);
            canvas.drawText(String.format(java.util.Locale.ROOT,"SPARKDROID / display %.1f Hz",getDisplay().getRefreshRate()),22,65,paint);
            canvas.drawText(String.format(java.util.Locale.ROOT,"Draw callbacks: %.1f/s",observed),22,115,paint);
            canvas.drawText("Client FPS is measured separately",22,160,paint);
            float phase=((now-start)%2_000_000_000L)/2_000_000_000f;
            float x=20+(getWidth()-110)*phase;
            for(int i=0;i<8;i++){paint.setColor(Color.rgb(35+i*22,190-i*14,240));canvas.drawRect(x,210+i*95,x+80,275+i*95,paint);}
            postInvalidateOnAnimation();
        }
    }
}
