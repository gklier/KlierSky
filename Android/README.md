# KlierSky Android alpha

A native Android preview with system typography and the KlierSky name, built from the same provider contracts as the iPhone app. The application ID is `com.klier.kliersky`, version `0.1.0-alpha`.

Includes current conditions, feels-like temperature, compact hourly and daily forecasts, UV/humidity forecast readings, current-location permission with a saved-city fallback, city search, persistent favorites, saved-place map selection, light/dark/system appearance, units, and a MapLibre observed-radar timeline. Foreca is used through the existing HTTPS gateway when this device has owner-approved read-only access. The Foreca credential stays on the server. The encrypted device credential is backed by Android Keystore. Open-Meteo supplies the labeled fallback.

The iOS weighted blend, model futurecast, historical comparison, personal-station setup, rain reminders and widgets still need Android ports. This alpha has build, lint, signature and bundle-format checks. Physical Android rendering, gestures, location permission and live service enrollment need on-device testing.

## Build

Requires JDK 17, Android SDK platform 36 and build tools 36.0.0. Set `sdk.dir` in an untracked `local.properties`, or use `ANDROID_HOME`.

```
./gradlew :app:bundleDebug :app:assembleDebug
```

For a signed release, set `KLIERSKY_KEYSTORE_PATH`, `KLIERSKY_STORE_PASSWORD` and `KLIERSKY_KEY_PASSWORD` in the build environment. The upload-key alias is `kliersky-upload`. Keep the keystore and credentials in private storage outside this checkout.

```
./gradlew :app:bundleRelease :app:assembleRelease :app:lintRelease
```

The AAB is a publishing bundle. Use the companion APK for direct installation on an Android phone. Google Play listing, enrollment, app signing configuration and review remain separate owner steps.

## Data and attribution

Foreca service access uses the owner's existing entitlement. Open-Meteo's free endpoint is for non-commercial use. RainViewer supplies observed radar frames. OpenFreeMap uses OpenMapTiles and OpenStreetMap data. Native MapLibre retains its attribution control. See the repository's provider notes and the respective provider terms before distributing beyond personal testing.
