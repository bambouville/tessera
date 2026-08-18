# Localization

Tessera ships English plus French, German, Spanish, Japanese, Simplified
Chinese, and Traditional Chinese. There is no in-app language picker: iOS
matches the device language against the app's declared localizations and falls
back to English when nothing matches. Users override per app in
**Settings → Tessera → Language**, which iOS offers for free once the
localizations are declared.

Regional variants resolve through Apple's own language matching, so declaring
the base language is enough — Quebec French (`fr-CA`) gets `fr`, Austrian
German (`de-AT`) gets `de`, Mexican Spanish (`es-MX`) gets `es`. Chinese is the
exception: script matters more than region, so `zh-Hans` and `zh-Hant` are
declared separately and Hong Kong (`zh-HK`) resolves to `zh-Hant`. These are
not transliterations of each other — they use different vocabulary
(终端/终端機, 密钥/金鑰, 端口/埠).

## Layout

- `Tessera/Localizable.xcstrings` — the generated String Catalog. **Do not edit
  by hand**; it is rebuilt from the sources below.
- `Tessera/InfoPlist.xcstrings` — permission prompts. Hand-maintained, since
  those strings come from build settings rather than Swift.
- `l10n/translations.json` — simple strings, keyed by the English source.
- `l10n/plurals.json` — strings that vary by one count.
- `l10n/subs.json` — strings that vary by more than one count independently.

All three keep every language side by side under one English key, so a key can
never drift out of sync between languages.

## Regenerating the catalog

Extraction happens during a build. `xcodebuild` writes the extracted corpus to
per-file `.stringsdata` but never syncs it back into `.xcstrings` — only the
Xcode IDE does that — so the catalog is rebuilt from that output:

```sh
xcodebuild -project Tessera.xcodeproj -scheme Tessera \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DD build
python3 scripts/l10n/build-catalog.py            # rebuild the catalog
python3 scripts/l10n/build-catalog.py --missing  # list untranslated keys
```

A string with no translation for a language is simply omitted for that
language, so the app falls back to English rather than rendering blank.

## Adding user-facing copy

Literals reach the catalog only through a localizable type. In Swift that means
`Text("…")`, or `String(localized:)` when a `String` has to come back out.

The shared components in `Tessera/Design/Components/` take `LocalizedStringKey`
for exactly this reason — a component that took `String` and rendered
`Text(someString)` would silently opt every one of its call sites out of
translation, because `Text(String)` does not localize.

Anything that is **not** prose must say so explicitly, or it lands in the
catalog as a key a translator can only copy back unchanged:

- `Text(verbatim:)` for glyphs, separators, and strings that only join
  already-localized pieces.
- `Tag(verbatim:)` for data — key algorithms, key names, host addresses.
- `showToast(verbatim:)` for text that is already resolved, such as a thrown
  error's `localizedDescription`.

Debug harnesses and `#Preview` blocks use `Text(verbatim:)` throughout: that
copy is sample terminal output and instrument readouts, it never ships, and
translating it would be meaningless.

## Conventions

- **Technical terms stay English.** Protocol and tool names (SSH, mosh, tmux,
  Tessera) are never translated, and neither is the terminal jargon developers
  actually use in each language — host, port, key, fingerprint. Surrounding
  prose is fully translated.
- **Case follows each language, not the English styling.** Tessera's English UI
  is deliberately lowercase. French and Spanish keep that look, and CJK has no
  case, but German capitalizes nouns as its orthography requires — lowercase
  German reads as a typo, not as a style.
- **Never assemble a sentence from fragments.** Fragments inflect with tense,
  gender, and word order, and verb-final languages have nowhere to put a stem.
  Spell out each variant as a whole string and let the catalog vary it.
- **Diagnostics stay English.** The diagnostics log is written to be sent to
  the developer, so translating it would make reports harder to read.
