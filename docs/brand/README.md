# Tessel brand

The Tessel name and logo are not covered by the MIT license that applies to
the code.

| File | Use |
|---|---|
| `tessel-lockup.svg`, `tessel-lockup-dark.svg` | The mark and the name, for light and dark backgrounds. The name is Inter Display SemiBold (SIL Open Font License), converted to outlines. |
| `tessel-mark.svg`, `tessel-mark-dark.svg` | The mark alone. |
| `favicon-16.png`, `favicon-32.png` | Marks hinted to whole pixels, for the web only. The app icon never uses them. |
| `social-preview.png` | The 1280×640 social preview. GitHub accepts it only through the repository settings. |

The mark is Tessel's rails map: five rails clipped by the edges, the outer
pair at half strength, and a screen pane on the current rail whose focused
window is the only color.

The app icon is compiled by `scripts/build` from two Icon Composer sources:
`Sources/App/Tessel.icon` for the daily build and `Sources/App/TesselDev.icon`
for the development build, which sits on a graphite body so the two are told
apart in System Settings. An Icon Composer icon has no art per size: macOS
scales the 1024 master down. The rails sit on a 64-unit grid of that master,
so they land on whole pixels at 16 and 32 px; keep new shapes on it. macOS
derives the dark, clear and tinted icon styles from the default appearance.
