# tv-button-remap

A minimal, zero-UI Android TV / Google TV `AccessibilityService` APK (`com.local.buttonremap`) that remaps dedicated remote app buttons over ADB without replacing the stock launcher or installing a heavy remapper app.

Inspired by [`Gathin23/cleanyourtv`](https://github.com/Gathin23/cleanyourtv)'s `InputKeyService` (`capabilities=8`, zero `accessibilityEventTypes`, no launcher icon, no background polling).

## Why this exists

On devices like the **Google TV Streamer 4K (`kirkwood`)**, if you keep the stock Google TV launcher (`com.google.android.apps.tv.launcherx`) and Google Cast enabled, hardware shortcut buttons (YouTube, Netflix, Star) are intercepted by `launcherx`'s `GlobalKeyListener_Receiver` and `chromecastservice`'s `GlobalKeyReceiver`:

- Passive `getevent` watchers cannot consume the Netflix button press, causing Netflix (or the Play Store prompt) to launch alongside your target app.
- A minimal key-filtering `AccessibilityService` runs ahead of global key dispatch and consumes both `ACTION_DOWN` and `ACTION_UP` for mapped keycodes, cleanly launching only your chosen app.

## Verified Hardware

Tested on:
- **Device:** Google TV Streamer 4K (`kirkwood`)
- **OS / Build:** Google TV 14, build `UTTK.260317.003` (with stock `launcherx` enabled)
- **Remote layout:** `/system/usr/keylayout/Vendor_18d1_Product_9451.kl`

| Physical Button | Android Keycode | Numeric Code | HID Usage |
|---|---|---|---|
| YouTube | `KEYCODE_BUTTON_3` | `190` | `0x000c0077` |
| Netflix | `KEYCODE_BUTTON_4` | `191` | `0x000c0078` |
| Star (customizable) | `KEYCODE_MACRO_1` | `313` | `0x000c0186` |

## Configuration

Edit [`res/values/config.xml`](res/values/config.xml) and list `<keycode>:<target>` entries in `button_mappings`:

```xml
<string-array name="button_mappings">
    <item>190:org.smarttube.stable</item>
    <item>191:com.nuvio.tv</item>
</string-array>
```

`<target>` can be a package name (e.g. `org.smarttube.stable`) or an explicit component (e.g. `com.example.app/.MainActivity`).

To find installed package names and your remote's keycodes on another TV:

```sh
adb shell pm list packages -3
adb shell dumpsys input | grep -i KeyLayoutFile
```

## Build & Install

Requires **JDK 17+** and **`adb`** (`platform-tools`). No Android Studio or Gradle is needed — the script downloads Android SDK Build-Tools 34 and Platform 34 from Google's official repository on first run, compiles with `aapt2`/`javac`/`d8`, signs with a local keystore (`local-remap.jks`), installs, grants `ACCESS_RESTRICTED_SETTINGS`, and enables the accessibility service.

### Windows (PowerShell)

```powershell
.\build-and-install.ps1 -TvHost 192.168.1.50:5555
```

### macOS / Linux

```bash
chmod +x build-and-install.sh restore.sh
./build-and-install.sh 192.168.1.50:5555
```

*(Pass `-BuildOnly` on Windows or `--build-only` on macOS/Linux to build and sign `build/button-remap.apk` without connecting to a TV.)*

## Verification

1. Confirm the service is bound with `capabilities=8`:

   ```sh
   adb shell dumpsys accessibility | grep -E "Bound services|Enabled services"
   ```

2. Press the physical **YouTube** and **Netflix** buttons on your remote.
   > **Note:** On Android 14, `adb shell input keyevent` bypasses `AccessibilityInputFilter`, so injected key events hit the stock handlers instead of `onKeyEvent`. Always test with the physical remote.

## Known Trade-off

On Google TV Streamer (`UTTK.260317.003`), having any key-filtering accessibility service bound (`flagRequestFilterKeyEvents`) can cause held **Volume Up/Down** over Bluetooth to stop repeating after ~6 steps (documented in [`cleanyourtv#796`](https://github.com/Gathin23/cleanyourtv/issues/796)). If your remote controls your TV or soundbar volume via **IR or HDMI-CEC**, volume repeat is unaffected.

## Uninstall / Restore

To disable the accessibility service and uninstall `com.local.buttonremap`:

```powershell
# Windows
.\restore.ps1 -TvHost 192.168.1.50:5555
```

```bash
# macOS / Linux
./restore.sh 192.168.1.50:5555
```

Once everything works, you can switch off **Wireless debugging** / **USB debugging** in Developer options — the service stays enabled across reboots without ADB.
