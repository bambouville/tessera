#!/usr/bin/env python3
"""Regenerate Localizable.xcstrings from Xcode's extraction plus translations.

`xcodebuild` writes the extracted corpus to per-file .stringsdata but never
syncs it into the .xcstrings source — only the Xcode IDE does that. Rebuilding
the catalog here keeps it reproducible from the source tree, so a new string in
Swift shows up as untranslated rather than silently missing.

Translation input lives in l10n/ and is keyed by the English source string, with
all languages side by side so a key can never drift between files:

  translations.json  {"save": {"fr": "enregistrer", "de": "Sichern", …}}
  plurals.json       {"%lld matches": {"fr": {"one": "…", "other": "…"}, …}}
  subs.json          {"<key>": {"fr": {"value": "…%#@a@…",
                                       "subs": {"a": {"argNum": 1,
                                                      "one": "…", "other": "…"}}}}}

A key with no entry for a language is left out of the catalog for that language,
so the app falls back to English instead of showing an empty string.
"""
import json
import sys
from collections import defaultdict
from pathlib import Path

# Repo root, derived from this file rather than pinned to one checkout: the
# catalog is rebuilt from whichever tree (main or a worktree) is being built.
ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build/DD/Build/Intermediates.noindex/Tessera.build/Debug-iphonesimulator"
CATALOG = ROOT / "Tessera/Localizable.xcstrings"
L10N = ROOT / "l10n"
ARCH = "arm64"
LANGS = ["de", "es", "fr", "ja", "zh-Hans", "zh-Hant"]
# English is the source language, so a simple key needs no entry — the key *is*
# the value. A plural does: without variations the catalog falls back to the key
# for every count, and "+1 more sessions reconnecting" is wrong in the one
# language we wrote the string in. Plural and substitution batches may therefore
# carry an "en" block, which is emitted but never counted as translation
# coverage.
SOURCE_LANG = "en"


def extracted():
    """key -> comment, from every .stringsdata Xcode produced for the app."""
    keys = {}
    for target in ("Tessera.build", "TesseraShareExtension.build"):
        root = BUILD / target / "Objects-normal" / ARCH
        if not root.is_dir():
            continue
        for path in sorted(root.glob("*.stringsdata")):
            try:
                data = json.loads(path.read_text())
            except (json.JSONDecodeError, OSError):
                continue
            for table, entries in data.get("tables", {}).items():
                if table != "Localizable":
                    continue
                for entry in entries:
                    key = entry.get("key")
                    if not key:  # skips the empty key from Toggle("", isOn:)
                        continue
                    comment = entry.get("comment") or ""
                    if key not in keys or (not keys[key] and comment):
                        keys[key] = comment
    return keys


def load(kind):
    """Merge every batch file under l10n/<kind>/.

    Translations are split per feature area so each batch stays reviewable on
    its own; a duplicate key across batches is a mistake worth failing on
    rather than silently resolving by file order.
    """
    merged = {}
    directory = L10N / kind
    if not directory.is_dir():
        return merged
    for path in sorted(directory.glob("*.json")):
        batch = json.loads(path.read_text(encoding="utf-8"))
        for key, value in batch.items():
            if key in merged:
                raise SystemExit(f"duplicate key in {kind}: {key!r} (in {path.name})")
            merged[key] = value
    return merged


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def main():
    keys = extracted()
    simple, plurals, subs = load("strings"), load("plurals"), load("subs")

    strings, stats = {}, defaultdict(int)
    for key in sorted(keys):
        entry = {"extractionState": "extracted_with_value"}
        if keys[key]:
            entry["comment"] = keys[key]

        localizations = {}
        for lang in LANGS + [SOURCE_LANG]:
            if key in subs and lang in subs[key]:
                spec = subs[key][lang]
                localizations[lang] = {
                    "stringUnit": {"state": "translated", "value": spec["value"]},
                    "substitutions": {
                        name: {
                            "argNum": body["argNum"],
                            "formatSpecifier": "lld",
                            "variations": {"plural": {
                                cat: unit(text)
                                for cat, text in body.items() if cat != "argNum"
                            }},
                        }
                        for name, body in spec["subs"].items()
                    },
                }
            elif key in plurals and lang in plurals[key]:
                localizations[lang] = {"variations": {"plural": {
                    cat: unit(text) for cat, text in plurals[key][lang].items()
                }}}
            elif key in simple and lang in simple[key]:
                localizations[lang] = unit(simple[key][lang])
            else:
                continue
            if lang != SOURCE_LANG:
                stats[lang] += 1

        if localizations:
            entry["localizations"] = localizations
        strings[key] = entry

    CATALOG.write_text(
        json.dumps({"sourceLanguage": "en", "strings": strings, "version": "1.0"},
                   indent=2, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    total = len(keys)
    print(f"source keys: {total}")
    for lang in LANGS:
        print(f"  {lang:8s} {stats[lang]:4d}/{total}  ({stats[lang] * 100 // max(total, 1)}%)")

    if "--missing" in sys.argv:
        done = set(simple) | set(plurals) | set(subs)
        missing = sorted(k for k in keys if k not in done)
        print(f"\nuntranslated: {len(missing)}")
        for k in missing:
            print(f"  {k}")


if __name__ == "__main__":
    main()
