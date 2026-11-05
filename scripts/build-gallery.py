#!/usr/bin/env python3
"""Turns the attachments exported from the UI test result bundle into a screenshot gallery.

Usage: build-gallery.py <export-dir> <gallery-dir> <commit-sha> <test-outcome>

<export-dir> is the output of `xcrun xcresulttool export attachments` (PNG files plus
manifest.json). Every screenshot is saved as `<name>.png` (the attachment name given in
ScreenshotTests, scaled to at most 1920 pt wide with `sips`) and README.md lists them per test.
macOS only (uses `sips`).
"""
import json
import pathlib
import re
import subprocess
import sys

export_dir, gallery_dir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
sha, outcome = sys.argv[3], sys.argv[4]
gallery_dir.mkdir(parents=True, exist_ok=True)

tests = {}
for test in json.loads((export_dir / "manifest.json").read_text()):
    # "ScreenshotTests/test02OnboardingAndHome()" -> "test02OnboardingAndHome"
    test_name = re.sub(r"\(\)$", "", test["testIdentifier"].split("/")[-1])
    for item in test["attachments"]:
        if not item["exportedFileName"].endswith(".png"):
            continue
        # Attachment names come back as "<name>_<index>_<UUID>.png".
        name = item["suggestedHumanReadableName"].split("_")[0]
        subprocess.run(
            ["sips", "-Z", "1920", str(export_dir / item["exportedFileName"]),
             "--out", str(gallery_dir / f"{name}.png")],
            check=True, capture_output=True,
        )
        tests.setdefault(test_name, []).append(name)

if not tests:
    sys.exit("no screenshots in the result bundle")

lines = [
    "# Antresol for Apple TV: UI screenshots",
    "",
    f"Taken by the `ui-screenshots` CI job (AntresolTVUITests against `scripts/mock-server.py`) "
    f"for commit {sha} on main. UI tests: **{outcome}**.",
    "",
    "This branch is rewritten on every push to main; it always holds the latest set.",
    "",
]
for test_name in sorted(tests):
    lines += [f"## {test_name}", ""]
    for name in sorted(tests[test_name]):
        lines += [f"### {name}", "", f"![{name}]({name}.png)", ""]
(gallery_dir / "README.md").write_text("\n".join(lines))
print(f"{sum(map(len, tests.values()))} screenshots from {len(tests)} tests")
