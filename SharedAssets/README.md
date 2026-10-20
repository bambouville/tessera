# SharedAssets

Binary assets that iOS and Android ship from **one copy on disk**. Nothing here
is generated; edits are deliberate and both platforms see them at the same time.

## `fonts/`

An Android **resource root**, so it may only contain resource-legal directories
— today just `font/`. License texts and this README live outside it for that
reason (`SharedAssets/font-licenses/`), because AGP rejects unknown folders and
loose files inside a `res` root.

How each platform consumes it:

- **Android** — `android/design` and `android/terminal` add
  `res.directories.add(rootProject.file("../SharedAssets/fonts").path)`, so
  every file becomes `R.font.<filename>`. That is why the filenames are
  lowercase `[a-z0-9_]`: Android resource names have no other legal form.
- **iOS** — each `.ttf` is a file reference in `Tessera.xcodeproj` on the app
  target's *Copy Bundle Resources* phase, which flattens them into the bundle
  root where `registerEmbeddedFonts()` (`Tessera/Design/Typography.swift`)
  registers them with CoreText at launch. iOS resolves a face by its
  **PostScript name**, baked into the file, so the Android-shaped filenames
  cost nothing there.

## `font-licenses/`

The license text for every family in `fonts/font/`. Both platforms ship these:
iOS reproduces them in `Tessera/Resources/ThirdPartyNotices.txt` (a bundle
resource), and `android/app` packs this directory itself as an assets source
directory, so the APK carries the licenses the OFL and the Ubuntu Font Licence
require to travel with the font. A new family's license lands in the APK the
moment its file lands here — there is no second list to update.

## Adding a family

Drop the static regular `.ttf` in `fonts/font/`, add its license to
`font-licenses/`, append the notice to `Tessera/Resources/ThirdPartyNotices.txt`,
append a row to the table below, then add the entry to **both** catalogs —
`Tessera/Design/TerminalFontCatalog.swift` and
`android/design/.../TerminalFontCatalog.kt` — and add the `.ttf` to the app
target's *Copy Bundle Resources* phase in `Tessera.xcodeproj`. The unit tests on
each side pin the id list against the same literal, so a half-finished addition
fails rather than shipping a font one platform cannot select.

### Terminal font families

Regular weight only, matching what the terminal has always shipped: SwiftTerm
derives bold/italic through font-descriptor traits and the Termux renderer
through `Paint` faux-bold/skew, so neither needs a second file. Every face below
is fixed-pitch and carries U+2500 box drawing, which is what makes a font usable
for a TUI.

| File | Family | PostScript name | Version | License | Upstream |
| --- | --- | --- | --- | --- | --- |
| `jetbrains_mono.ttf` | JetBrains Mono | `JetBrainsMono-Regular` | 2.304 | OFL 1.1 | <https://github.com/JetBrains/JetBrainsMono> |
| `fira_code.ttf` | Fira Code | `FiraCode-Regular` | 6.002 | OFL 1.1 | <https://github.com/tonsky/FiraCode> |
| `hack.ttf` | Hack | `Hack-Regular` | 3.003 | MIT + Bitstream Vera | <https://github.com/source-foundry/Hack> |
| `cascadia_mono.ttf` | Cascadia Mono | `CascadiaMono-Regular` | 2407.024 | OFL 1.1 | <https://github.com/microsoft/cascadia-code> |
| `ibm_plex_mono.ttf` | IBM Plex Mono | `IBMPlexMono-Regular` | 2.3 | OFL 1.1 | <https://github.com/IBM/plex> |
| `source_code_pro.ttf` | Source Code Pro | `SourceCodePro-Regular` | 2.042 | OFL 1.1 | <https://github.com/adobe-fonts/source-code-pro> |
| `inconsolata.ttf` | Inconsolata | `Inconsolata-Regular` | 3.000 | OFL 1.1 | <https://github.com/googlefonts/Inconsolata> |
| `ubuntu_mono.ttf` | Ubuntu Mono | `UbuntuMono-Regular` | 0.80 | Ubuntu Font Licence 1.0 | <https://design.ubuntu.com/font> |
| `dejavu_sans_mono.ttf` | DejaVu Sans Mono | `DejaVuSansMono` | 2.37 | Bitstream Vera + Public Domain | <https://github.com/dejavu-fonts/dejavu-fonts> |
| `geist_mono.ttf` | Geist Mono | `GeistMono-Regular` | 1.700 | OFL 1.1 | <https://github.com/vercel/geist-font> |

All ten permit embedding and redistribution inside an application. None require
attribution in the UI, but all of them require the license text to accompany the
font, which is what `ThirdPartyNotices.txt` (iOS) and the packed
`font-licenses/` assets (Android) satisfy.

The picker also offers **System** — `UIFont.monospacedSystemFont` (SF Mono) on
iOS, `Typeface.MONOSPACE` on Android. It bundles nothing and follows whatever
the OS ships.
