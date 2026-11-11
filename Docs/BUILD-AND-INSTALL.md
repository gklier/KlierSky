# Build and install your own KlierSky

This guide matches the code on `main` (version 0.3.1). On the development branch (0.4.0, unbuilt) two things differ and are noted below; update this line when that branch is merged. It needs a Mac. KlierSky is a native iPhone app, so there is no Android or Windows version yet.

You do not need a paid Apple Developer account, a weather key or a server. Without them the app shows Open-Meteo forecasts and RainViewer radar, and says so on screen.

## What you need

- A Mac with a recent Xcode (development used Xcode 27.2) and an iPhone or the iOS Simulator. The app targets iOS 17 and later.
- An Apple ID, to sign the app for your own iPhone. A free Apple ID works; its apps expire after seven days and must be refreshed (see "Staying installed").
- Internet access for Xcode to fetch the pinned MapLibre package.

## Option 1: run it from Xcode

```sh
git clone https://github.com/gklier/KlierSky.git
cd KlierSky
open KlierSky.xcodeproj
```

1. Wait for Xcode to resolve the MapLibre package.
2. Click the **KlierSky** project, then each target (**KlierSky** and **KlierSkyWidgets**) → **Signing & Capabilities**. Choose your own **Team** on both.
3. Change the bundle identifiers so they are unique to you, on both targets, keeping the widget's as the app's plus `.widgets`. For example `com.yourname.KlierSky` and `com.yourname.KlierSky.widgets`. (The shipped identifiers belong to the original author's account and will not sign for anyone else.)
4. Pick the **KlierSky** scheme and your iPhone or a simulator, then press Run.
5. On a real iPhone, trust your developer certificate when asked: **Settings → General → VPN & Device Management**.

If signing fails on the widget target, it almost always means the two identifiers do not match the pattern in step 3 or the two teams differ.

## Option 2: install through SideStore

SideStore re-signs an app with your own Apple ID and refreshes it for you. It needs an `.ipa` file. The app is not distributed pre-built, so you make one:

```sh
xcodebuild -project KlierSky.xcodeproj -scheme KlierSky -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" -derivedDataPath build build
mkdir -p Payload && rm -rf Payload/KlierSky.app
cp -R build/Build/Products/Release-iphoneos/KlierSky.app Payload/
zip -qr KlierSky.ipa Payload
```

Then import `KlierSky.ipa` in SideStore. This is a standard technique for unsigned builds; it has not been run in this repository's cloud sessions (no Xcode there), so treat it as a starting point and tell us if a step needs fixing. SideStore's own instructions: <https://docs.sidestore.io/docs/installation/install>.

## Staying installed

Free signing lasts seven days and allows only a few apps and App IDs at a time. SideStore (or reinstalling from Xcode) renews it. Keep an existing installation when updating: deleting the app deletes its saved places and settings.

## Optional: Foreca through your own gateway

Foreca is a commercial service and its key is never put in the app. To use it you run the small gateway in `Gateway/` on your own HTTPS server, which holds the key. Then give the app the gateway's address under **Settings → Weather Lab**. Setup: [Gateway/README.md](../Gateway/README.md). The repository contains no server address, key or token.

*Development branch only:* the address comes from the `KLIERSKY_GATEWAY_URL` build setting (copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig` and pass it with `-xcconfig`), so family devices need no typing. Without it the app uses the free sources.

## Optional: widgets

Widgets work out of the box and fetch Open-Meteo themselves. Sharing data between the app and widgets needs an App Group under your own team: set `KlierSkyAppGroup` in both `Info.plist` files to your group identifier, after creating it in Signing & Capabilities for both targets.

## Run the checks

```sh
sh Tests/run.sh
```

Needs macOS with Xcode's command-line tools (on the development branch, any Swift 6 toolchain including Linux) and Python 3. It decodes recorded sample responses, checks the adaptive-verification safeguards and runs the gateway's tests. It does not need the network or any key.

## What you may and may not do

KlierSky is licensed under the [PolyForm Noncommercial License](../LICENSE.md): you may build, run, modify and share it for personal and noncommercial use. Selling it or building a business on it needs the author's written permission. See [NOTICE.md](../NOTICE.md) for the plain-words summary.

Weather and map data come from third parties with their own terms (Open-Meteo is free for non-commercial use only; RainViewer's free API is for personal use). Those terms apply to your build too.
