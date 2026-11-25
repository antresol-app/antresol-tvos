#!/bin/bash
# Tests scripts/store-check.sh on a small synthetic app bundle (a stub executable built
# with clang, the plists and a string table), so no archive is needed and nothing real is
# touched. The word lists are the test's own invented ones (the real list is private).
#   1. the clean bundle passes;
#   2. a hard word in a compiled string table (a binary plist) fails;
#   3. a Cyrillic hard word in a string table fails;
#   4. a hard word inside the executable fails;
#   5. a soft word in a resource fails;
#   6. an identifier with a soft word in the executable fails, passes with --hard-only,
#      and passes once an allow line names it;
#   7. a second background mode fails;
#   8. a missing privacy manifest fails;
#   9. a fixture file in the bundle fails;
#  10. a web-only type name among the executable's symbols fails;
#  11. a missing words file is a usage error (exit 2), not a pass.
#
#   scripts/store-check_test.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
command -v clang >/dev/null 2>&1 || { echo "store-check_test: clang not found" >&2; exit 2; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/store-check-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
app=$tmp/AntresolTV.app

# A repo-shaped folder (the script finds fastlane/metadata beside scripts/) and the words.
mkrepo() {
	rm -rf "$tmp/repo"
	mkdir -p "$tmp/repo/scripts" "$tmp/repo/fastlane/metadata/en-US"
	cp "$here/scripts/store-check.sh" "$tmp/repo/scripts/"
	echo "A player for your own home media server." > "$tmp/repo/fastlane/metadata/en-US/description.txt"
	cat > "$tmp/words.txt" <<'WORDS'
hard: zzhardword
hard-ru: (з|З)банслово
soft: zzsoft
allow: zzsoftOk
symbols: ZzWebOnlyType
WORDS
}

# $1: the C top level of the executable (it gets stdio.h; keep a puts in main so the
# binary imports something)
mkapp() {
	rm -rf "$app"
	mkdir -p "$app/en.lproj"
	printf '#include <stdio.h>\n%s\n' "$1" > "$tmp/main.c"
	clang -o "$app/AntresolTV" "$tmp/main.c" 2>/dev/null || { echo "store-check_test: clang failed" >&2; exit 2; }
	cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>test.app</string>
<key>CFBundleExecutable</key><string>AntresolTV</string>
<key>ITSAppUsesNonExemptEncryption</key><false/>
<key>UIBackgroundModes</key><array><string>audio</string></array>
</dict></plist>
PLIST
	cat > "$app/PrivacyInfo.xcprivacy" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>NSPrivacyTracking</key><false/>
<key>NSPrivacyTrackingDomains</key><array/>
<key>NSPrivacyCollectedDataTypes</key><array/>
<key>NSPrivacyAccessedAPITypes</key><array>
<dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryUserDefaults</string></dict>
<dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryFileTimestamp</string></dict>
<dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategorySystemBootTime</string></dict>
</array></dict></plist>
PLIST
	strings_table 'Play' 'Продолжить'
}

# A compiled (binary plist) string table with one entry.
strings_table() {
	printf '"%s" = "%s";\n' "$1" "$2" > "$app/en.lproj/Localizable.strings"
	plutil -convert binary1 "$app/en.lproj/Localizable.strings"
}

# expect WANT PATTERN NAME [OPTION]: the exit status of the check, and for 1 a line of its
# output with PATTERN (it must fail for the reason the test plants, not for another)
expect() {
	want=$1; pattern=$2; name=$3; shift 3
	STORE_CHECK_WORDS=$tmp/words.txt "$tmp/repo/scripts/store-check.sh" "$@" "$app" > "$tmp/out" 2>&1
	got=$?
	if [ "$got" != "$want" ] || { [ "$want" = 1 ] && ! grep -q -E "$pattern" "$tmp/out"; }; then
		echo "FAIL: $name (exit $got, expected $want; looked for: $pattern)"
		sed 's/^/    /' "$tmp/out"
		fail=1
	else
		echo "ok: $name"
	fi
}

CLEAN='int main(void) { puts("x"); return 0; }'

mkrepo; mkapp "$CLEAN"
expect 0 "" "a clean bundle passes"

mkrepo; mkapp "$CLEAN"; strings_table 'Zzhardword' 'a zzHardWord here'
expect 1 "carries banned words" "a hard word in a compiled string table fails"

mkrepo; mkapp "$CLEAN"; strings_table 'Plays' 'Это Збанслово'
expect 1 "carries banned words" "a Cyrillic hard word in a compiled string table fails"

mkrepo; mkapp 'const char *w = "has zzhardword in it"; int main(void) { puts(w); return 0; }'
expect 1 "carries banned words" "a hard word inside the executable fails"

mkrepo; mkapp "$CLEAN"; printf 'a ZZSOFT word\n' > "$app/about.txt"
expect 1 "resource.*soft word" "a soft word in a resource fails"

mkrepo; mkapp 'int newzzsoftThing(void) { return 2; } int main(void) { puts("x"); return newzzsoftThing(); }'
expect 1 "no allow line" "an identifier with a soft word that no allow line covers fails"
expect 0 "" "the same bundle passes with --hard-only" --hard-only
echo 'allow: newzzsoftThing' >> "$tmp/words.txt"
expect 0 "" "and passes once an allow line names the identifier"

mkrepo; mkapp "$CLEAN"; /usr/libexec/PlistBuddy -c 'Add :UIBackgroundModes: string fetch' "$app/Info.plist"
expect 1 "background modes are" "a second background mode fails"

mkrepo; mkapp "$CLEAN"; rm "$app/PrivacyInfo.xcprivacy"
expect 1 "PrivacyInfo.xcprivacy missing" "a missing privacy manifest fails"

mkrepo; mkapp "$CLEAN"; echo '{}' > "$app/demo-library.json"
expect 1 "fixtures or sample media" "a fixture file in the bundle fails"

# the symbol check reads demangled names; a plain C symbol with the type's name is the same text
mkrepo; mkapp 'int ZzWebOnlyType_stub(void) { return 1; } int main(void) { puts("x"); return ZzWebOnlyType_stub(); }'
expect 1 "web-only feature" "a web-only type name among the symbols fails"

mkrepo; mkapp "$CLEAN"
STORE_CHECK_WORDS=$tmp/missing.txt "$tmp/repo/scripts/store-check.sh" "$app" > "$tmp/out" 2>&1
got=$?
if [ "$got" = 2 ]; then echo "ok: a missing words file is a usage error"; else echo "FAIL: a missing words file gave exit $got, expected 2"; fail=1; fi

[ $fail -eq 0 ] && echo "store-check_test: all passed" || echo "store-check_test: FAILED"
exit $fail
