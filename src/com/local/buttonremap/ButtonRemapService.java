package com.local.buttonremap;

import android.accessibilityservice.AccessibilityService;
import android.content.ActivityNotFoundException;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.SystemClock;
import android.util.Log;
import android.util.SparseArray;
import android.view.KeyEvent;
import android.view.accessibility.AccessibilityEvent;

/**
 * Minimal key-filtering accessibility service that remaps configured Android TV
 * remote buttons (defined in res/values/config.xml) to target apps or activities.
 */
public class ButtonRemapService extends AccessibilityService {

    private static final String TAG = "ButtonRemap";
    private static final long DEBOUNCE_MS = 300L;

    private final SparseArray<String> mappings = new SparseArray<>();
    private long lastLaunchTime = 0L;
    private int lastLaunchKey = -1;

    @Override
    protected void onServiceConnected() {
        super.onServiceConnected();
        loadMappings();
        Log.i(TAG, "ButtonRemapService connected with " + mappings.size() + " mapping(s)");
    }

    private void loadMappings() {
        mappings.clear();
        String[] entries = getResources().getStringArray(R.array.button_mappings);
        for (String raw : entries) {
            if (raw == null) {
                continue;
            }
            String entry = raw.trim();
            if (entry.isEmpty()) {
                continue;
            }
            int sep = entry.indexOf(':');
            if (sep <= 0 || sep >= entry.length() - 1) {
                Log.w(TAG, "Skipping malformed mapping entry: " + entry);
                continue;
            }
            String keyPart = entry.substring(0, sep).trim();
            String target = entry.substring(sep + 1).trim();
            if (target.isEmpty()) {
                Log.w(TAG, "Skipping mapping with empty target: " + entry);
                continue;
            }
            try {
                int keyCode = Integer.parseInt(keyPart);
                mappings.put(keyCode, target);
            } catch (NumberFormatException e) {
                Log.w(TAG, "Skipping mapping with invalid keycode: " + entry);
            }
        }
    }

    @Override
    protected boolean onKeyEvent(KeyEvent event) {
        int keyCode = event.getKeyCode();
        String target = mappings.get(keyCode);
        if (target == null) {
            return false;
        }

        if (event.getAction() == KeyEvent.ACTION_DOWN && event.getRepeatCount() == 0) {
            long now = SystemClock.uptimeMillis();
            if (keyCode != lastLaunchKey || (now - lastLaunchTime) >= DEBOUNCE_MS) {
                lastLaunchKey = keyCode;
                lastLaunchTime = now;
                launchTarget(target, keyCode);
            }
        }
        return true;
    }

    private void launchTarget(String target, int keyCode) {
        Intent intent = null;
        if (target.indexOf('/') > 0) {
            ComponentName cn = ComponentName.unflattenFromString(target);
            if (cn != null) {
                intent = new Intent().setComponent(cn);
            } else {
                Log.w(TAG, "Invalid component target: " + target);
                return;
            }
        } else {
            PackageManager pm = getPackageManager();
            intent = pm.getLeanbackLaunchIntentForPackage(target);
            if (intent == null) {
                intent = pm.getLaunchIntentForPackage(target);
            }
            if (intent == null) {
                Log.w(TAG, "No launch intent for " + target);
                return;
            }
        }

        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
        try {
            Log.i(TAG, "Key " + keyCode + " -> launching " + target);
            startActivity(intent);
        } catch (ActivityNotFoundException | SecurityException e) {
            Log.e(TAG, "Failed to launch " + target, e);
        }
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
    }

    @Override
    public void onInterrupt() {
    }
}
