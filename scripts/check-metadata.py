#!/usr/bin/env python3
"""Checks the App Store metadata under fastlane/metadata against App Store Connect limits."""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / "fastlane" / "metadata"
LOCALES = ["en-US", "ru"]
# File -> (limit, unit). App Store Connect counts keywords in bytes, the rest in characters.
LIMITS = {
    "name.txt": (30, "chars"),
    "subtitle.txt": (30, "chars"),
    "promotional_text.txt": (170, "chars"),
    "description.txt": (4000, "chars"),
    "release_notes.txt": (4000, "chars"),
    "keywords.txt": (100, "bytes"),
}
URLS = ["privacy_url.txt", "support_url.txt", "marketing_url.txt"]

errors = []
for locale in LOCALES:
    folder = ROOT / locale
    for name, (limit, unit) in LIMITS.items():
        path = folder / name
        if not path.is_file():
            errors.append(f"{locale}/{name}: missing")
            continue
        text = path.read_text(encoding="utf-8").strip()
        size = len(text.encode("utf-8")) if unit == "bytes" else len(text)
        if not text:
            errors.append(f"{locale}/{name}: empty")
        elif size > limit:
            errors.append(f"{locale}/{name}: {size} {unit}, limit {limit}")
        if name == "keywords.txt" and any(not k.strip() for k in text.split(",")):
            errors.append(f"{locale}/{name}: empty keyword")
    for name in URLS:
        path = folder / name
        url = path.read_text(encoding="utf-8").strip() if path.is_file() else ""
        if not url.startswith("https://"):
            errors.append(f"{locale}/{name}: not an https URL")

# Copyright is set in App Store Connect only: the rights holder is not named in this repo.
for name in ["primary_category.txt"]:
    if not (ROOT / name).is_file():
        errors.append(f"{name}: missing")

if errors:
    print("\n".join(errors))
    sys.exit(1)
print(f"App Store metadata OK ({', '.join(LOCALES)})")
