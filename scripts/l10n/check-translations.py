#!/usr/bin/env python3
"""Validate l10n/ against the extracted corpus before the catalog is rebuilt.

Three classes of mistake are silent at build time but visible (or crashing) at
runtime, so they are checked here instead:

  * format specifiers that drift from the English source — a translation that
    drops %@ or turns %lld into %@ reads garbage or traps in String(format:);
  * translations for keys that no longer exist in the app — dead weight that
    hides a rename;
  * empty values and plural categories a language does not have (ja/zh have
    only `other` in CLDR, so a `one` variation there is never selected).
"""
import json
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from importlib import import_module

build = import_module("build-catalog")

# %[argnum$][flags][width][.precision]conversion — plus the %#@name@ token the
# String Catalog uses for substitutions, which is not a printf specifier.
SPEC = re.compile(r"%(?:(\d+)\$)?[-+ #0]*[\d*]*(?:\.\d+)?(@|lld|ld|d|lu|u|f|%)")
SUB_TOKEN = re.compile(r"%#@[A-Za-z_][A-Za-z0-9_]*@")
CLDR_OTHER_ONLY = {"ja", "zh-Hans", "zh-Hant"}


def specs(text):
    """Multiset of conversion types, positions ignored. %% is a literal."""
    return Counter(m.group(2) for m in SPEC.finditer(SUB_TOKEN.sub("", text))
                   if m.group(2) != "%")


def positions(text):
    return [int(m.group(1)) for m in SPEC.finditer(text) if m.group(1)]


def main():
    keys = build.extracted()
    simple = build.load("strings")
    plurals = build.load("plurals")
    subs = build.load("subs")
    problems = []

    for kind, table in (("strings", simple), ("plurals", plurals), ("subs", subs)):
        for key in table:
            if key not in keys:
                problems.append(f"[stale] {kind}: {key!r} is no longer in the app")

    def compare(key, lang, where, text):
        want, got = specs(key), specs(text)
        if want != got:
            problems.append(
                f"[format] {key!r} / {lang}{where}: source {dict(want)} != {dict(got)}")
        # More than one specifier reorders in translation, so every one of them
        # must be positional or none of them can be trusted to line up.
        used = positions(text)
        if sum(want.values()) > 1 and used and sorted(used) != list(range(1, sum(want.values()) + 1)):
            problems.append(
                f"[position] {key!r} / {lang}{where}: indices {sorted(used)} "
                f"do not cover 1…{sum(want.values())}")
        if not text.strip():
            problems.append(f"[empty] {key!r} / {lang}{where}")

    for key, by_lang in simple.items():
        for lang, text in by_lang.items():
            compare(key, lang, "", text)

    for key, by_lang in plurals.items():
        for lang, variations in by_lang.items():
            if lang in CLDR_OTHER_ONLY and set(variations) != {"other"}:
                problems.append(
                    f"[plural] {key!r} / {lang}: {sorted(variations)} — "
                    f"{lang} has only `other` in CLDR")
            if "other" not in variations:
                problems.append(f"[plural] {key!r} / {lang}: missing `other`")
            for category, text in variations.items():
                compare(key, lang, f" ({category})", text)

    for key, by_lang in subs.items():
        for lang, spec in by_lang.items():
            names = set(SUB_TOKEN.findall(spec["value"]))
            declared = {f"%#@{name}@" for name in spec["subs"]}
            if names != declared:
                problems.append(
                    f"[subs] {key!r} / {lang}: value uses {sorted(names)}, "
                    f"declares {sorted(declared)}")
            # Each substitution stands in for one %lld, so the whole rendered
            # string is the value plus one variation from every substitution.
            for body in spec["subs"].values():
                if lang in CLDR_OTHER_ONLY and set(body) - {"argNum"} != {"other"}:
                    problems.append(
                        f"[subs] {key!r} / {lang}: {sorted(set(body) - {'argNum'})} — "
                        f"{lang} has only `other` in CLDR")
            # A substitution's own %lld is bound by its argNum, not by a
            # positional index, so the rendered string can't be checked as one
            # format string — the value and the variations are validated apart.
            want = specs(key)
            got = specs(spec["value"]) + Counter(
                {"lld": len(spec["subs"])} if spec["subs"] else {})
            if want != got:
                problems.append(
                    f"[format] {key!r} / {lang}: source {dict(want)} != {dict(got)}")
            used = set(positions(spec["value"]))
            used |= {body["argNum"] for body in spec["subs"].values()}
            if used != set(range(1, sum(want.values()) + 1)):
                problems.append(
                    f"[position] {key!r} / {lang}: args {sorted(used)} "
                    f"do not cover 1…{sum(want.values())}")
            for name, body in spec["subs"].items():
                for category, text in body.items():
                    if category == "argNum":
                        continue
                    if specs(text) != Counter({"lld": 1}):
                        problems.append(
                            f"[subs] {key!r} / {lang} / {name} ({category}): "
                            f"expected exactly one %lld, got {dict(specs(text))}")
                    if not text.strip():
                        problems.append(f"[empty] {key!r} / {lang} / {name} ({category})")

    for problem in problems:
        print(problem)
    print(f"\n{len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
