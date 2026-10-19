package com.overalls.androidfixture;

import android.app.Activity;
import android.os.Bundle;
import android.graphics.Color;
import android.view.View;
import android.widget.TextView;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

/** Small deterministic fixture used only by the Android software-emulator test. */
public final class MainActivity extends Activity {
    private static final String MARKER = "overalls-android-fixture-v1";

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        persistMarker();
        TextView view = new TextView(this);
        view.setText(MARKER);
        view.setTextColor(Color.BLACK);
        view.setBackgroundColor(Color.WHITE);
        view.setTextSize(20.0f);
        setContentView(view);
    }

    private void persistMarker() {
        try (FileOutputStream output = openFileOutput("marker", MODE_PRIVATE)) {
            output.write(MARKER.getBytes(StandardCharsets.UTF_8));
        } catch (IOException error) {
            throw new IllegalStateException("fixture marker write failed", error);
        }
    }
}
