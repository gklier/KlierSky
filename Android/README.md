# KlierSky for Android

KlierSky 0.2.0 beta runs on Android 8 and later. Use the [release APK](https://github.com/gklier/KlierSky/releases/download/android-v0.2.0-beta/KlierSky-Android-0.2.0-beta.apk) to install or update your phone. Install over the previous signed release to keep your data. The [AAB](https://github.com/gklier/KlierSky/releases/download/android-v0.2.0-beta/KlierSky-Android-0.2.0-beta.aab) is for publishing. [Release notes and checksums](https://github.com/gklier/KlierSky/releases/tag/android-v0.2.0-beta)

- Compact current conditions, a 12-hour outlook, six hourly rows expandable to 24, and detailed daily and 48-hour statistics. Choose a theme, units, and which details appear.
- Search for cities, use current location, and pick persistent favorites from a map.
- Browse observed RainViewer radar and run-pinned NOAA HRRR model futurecast on one timeline. The horizon reflects the available model run. An ambient cache and directional preloading help when scrubbing backward.
- Compare forecast providers or let the app blend available sources. Optional local verification scores temperatures against independent observations. Starting weights and measured weights are labeled separately.
- View US National Weather Service alerts, historical temperatures from ERA5, air quality, and timestamped observations from your configured Tempest or Weather Underground station.
- Enable rain alerts with a lead time and chance threshold. Alerts use hourly predictions and Android's best-effort scheduling.
- Pin current, hourly or daily weather widgets with their own location and units. Lock Screen availability depends on the Android widget host.
- Manage gateway devices and server credentials under Administration. Approved family devices use read-only Foreca access. No vendor key is required on those devices.

See [parity and validation notes](../Docs/ANDROID-PARITY.md) and [data and attribution](../Docs/PROVIDERS.md). Screenshots are live emulator captures in [Screenshots/parity](Screenshots/parity).

## Build

Use JDK 17, Android SDK platform 36 and build tools 36.0.0. Set `ANDROID_HOME` or `sdk.dir` in an untracked `local.properties`.

```sh
./gradlew :app:assembleDebug :app:assembleDebugAndroidTest :app:lintDebug
```

For a signed release, set `KLIERSKY_KEYSTORE_PATH`, `KLIERSKY_STORE_PASSWORD` and `KLIERSKY_KEY_PASSWORD` outside the checkout. The release alias is `kliersky-upload`.

```sh
./gradlew :app:assembleRelease :app:bundleRelease :app:lintRelease
```

The application ID is `com.klier.kliersky`. Android uses system typography and original adaptive launcher artwork.
