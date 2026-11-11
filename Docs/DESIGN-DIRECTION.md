# KlierSky design direction

Recorded 2026-11-11 from the owner's brief, for the Mac sessions where the interface can actually be seen. Nothing here has been evaluated on a screen from the cloud.

## The look

Modern, Liquid Glass, Dark Sky-minimal, enhanced. In practice:

- **Content first, chrome last.** Dark Sky's strength was a dense page with almost no boxes: one temperature, one sentence, one graph, rows. Keep sections separated by space and type weight, not cards.
- **Glass only where something floats.** Header controls, the map panel, the map's close button. Never glass behind forecast content; it costs contrast and reads as decoration. Liquid Glass on iOS 26 and later, system material before.
- **Apple system type only.** Large rounded-off numerals for temperature, monospaced digits wherever numbers line up, no custom fonts.
- **One accent, semantic colours.** Blue accent; rain, wind, warm and snow colours mean the same thing everywhere. Clouds stay readable in light and dark.
- **Motion that explains.** Expanding a day, switching the graph metric, moving along the map timeline. Nothing loops by itself; Reduce Motion is honoured.
- **Honest density.** The source line stays under every section. It is small, not hidden.

## Screen by screen, for the Mac pass

1. **Top of the main screen:** check that the blend line ("Blend of N sources") fits on one line at default text size and wraps cleanly at large sizes.
2. **Map preview:** consider letting the preview show the first model frame boundary too, so the main screen hints at what is coming.
3. **Map:** the combined timeline is new. Check the scrubber with about 45 frames, the "now" mark, the colour change between radar and model palettes, and whether the panel is too tall on small phones. A slimmer, Dark Sky-like panel (time, play, scrubber; details on tap) is the likely next step.
4. **Hourly rows:** verify the temperature pill track still reads well when blended temperatures differ by a degree or less across hours.
5. **Footer:** the blend's member list is long; it may deserve its own sheet.
6. **Widgets:** large hourly and daily widgets are first drafts written without a preview. Check row heights, truncation of condition text and the footer at each size.

## Not decided

A lighter, more graphic map style; an app-wide redesign of Settings; per-source colour coding in the comparison chart.
