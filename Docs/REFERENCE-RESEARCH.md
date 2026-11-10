# Product references and provider boundaries

Dark Sky's APK was examined statically for compact hierarchy, hourly/daily drill-down and weather detail organization. KlierSky uses original SwiftUI code, Apple system typography and original art. No APK assets or implementation are redistributed.

[CARROT](https://www.meetcarrot.com/weather/) supports configurable layouts and weather details: KlierSky adopts configurable visibility, units and explicit source inspection, rather than its personality or branding. [Acme Weather](https://acmeweather.com/app) emphasizes alternative predictions and uncertainty: KlierSky offers real provider comparison, labels disagreement rather than claiming confidence, and displays actual Foreca ensemble ranges only when returned. Alerts and community reports remain future work.

[Foreca point forecasts](https://developer.foreca.com/docs/point-forecasts) support hourly/daily products; nulls are preserved as missing. [Foreca weather maps](https://developer.foreca.com/docs/weather-maps) require separate access. The current account has point access only. [Foreca resources](https://developer.foreca.com/resources) define weather symbol semantics, which are mapped to native system symbols without copying artwork.

[Open-Meteo documentation](https://open-meteo.com/en/docs) defines the comparison/fallback metrics. App labels identify the actual selected source. Widgets currently use their own Open-Meteo requests, not Foreca.

[External TestFlight](https://developer.apple.com/testflight/) is suitable for remote family beta testing without a public store listing. [Apple Developer membership](https://developer.apple.com/programs/whats-included/) and external beta review are prerequisites. No family invitations or paid enrollment were performed.
