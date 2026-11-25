#!/bin/bash
# The App Store gate for the tvOS app: inspects a built Release archive (.xcarchive),
# an exported .ipa, or an .app and fails on anything an App Review reader should not
# find in it. It is the tvOS counterpart of the iOS app's `make apple-store-check`
# and reads the same word lists.
#
#   STORE_CHECK_WORDS=<words file> scripts/store-check.sh [--hard-only] [PATH]
#
#   PATH           .xcarchive | .ipa | .app (default: build/Antresol.xcarchive)
#   --hard-only    skip the soft words (for an app whose code legitimately has many
#                  identifiers with them; the iOS app, say)
#
# The words are not in this repository: they are the private list of the project that
# builds the apps (STORE_CHECK_WORDS names its file; lines `kind: regex`, kinds hard,
# hard-ru, soft, allow and symbols, as described there). A tool that names them would
# otherwise trip the public-tree scan.
#
# What it checks, on the app and every extension (PlugIns/*.appex):
#   1. Info.plist: ITSAppUsesNonExemptEncryption is false, no Apple Music access
#      description, no background task ids, audio is the only background mode.
#   2. The privacy manifest: present, valid, no tracking, no collected data types, and
#      the required-reason entries for the APIs the app uses (UserDefaults, file
#      timestamps, system boot time).
#   3. No fixtures or mock data in the bundle (no media samples, json fixtures, mock
#      servers).
#   4. The music library is not used (MPMedia library classes, MusicKit) and none of the
#      web-only feature types (the `symbols` list) is in the binaries; an archive's
#      Swift symbols are read from its dSYMs.
#   5. Words, in every file of the bundle (string tables and plists are converted to
#      text first; binaries are searched as bytes, so Swift string literals are seen):
#        hard words (`hard`, `hard-ru`) fail wherever they are;
#        soft words (`soft`) fail in resources and strings; in a binary they also name
#          ordinary code, so the identifiers that contain them are listed and each must
#          match an `allow` line.
#   6. The store texts under fastlane/metadata, with the same word lists.
#
# Exit status 0: clean. 1: something found (printed). 2: bad usage or a missing tool.
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
hard_only=0
target=
for arg in "$@"; do
	case $arg in
		--hard-only) hard_only=1 ;;
		-*) echo "store-check: unknown option $arg" >&2; exit 2 ;;
		*) target=$arg ;;
	esac
done
target=${target:-$here/build/Antresol.xcarchive}

words_file=${STORE_CHECK_WORDS:-}
[ -n "$words_file" ] && [ -f "$words_file" ] || {
	echo "store-check: STORE_CHECK_WORDS must name the words file (see the header of this script)" >&2
	exit 2
}
# The regexes of one kind, joined into one alternation.
kind() { sed -n "s/^$1: *//p" "$words_file" | paste -sd'|' -; }
HARD_WORDS=$(kind hard)
HARD_WORDS_RU=$(kind hard-ru)
SOFT_WORDS=$(kind soft)
WEB_ONLY_SYMBOLS=$(kind symbols)
[ -n "$HARD_WORDS" ] || { echo "store-check: $words_file has no hard words" >&2; exit 2; }
[ $hard_only -eq 0 ] || SOFT_WORDS=
# The music library (ITMS-90683): symbols are demangled first. MediaPlayer's library
# classes (not MPMediaItemProperty*/MPMediaItemArtwork, which now playing uses) and
# anything of MusicKit.
MUSIC_LIBRARY_SYMBOLS='MPMedia(Query|Library|Playlist|ItemCollection|PropertyPredicate)|MusicKit\.|MusicLibraryRequest|MusicAuthorization'

failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
note() { echo "ok:   $*"; }

for tool in plutil xcrun grep find file unzip; do
	command -v "$tool" >/dev/null 2>&1 || { echo "store-check: $tool not found" >&2; exit 2; }
done
[ -e "$target" ] || { echo "store-check: $target does not exist (archive first, see README: Ship to TestFlight)" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/store-check.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT

# --- the bundle ------------------------------------------------------------------------
app=
case $target in
	*.xcarchive) app=$(ls -d "$target"/Products/Applications/*.app 2>/dev/null | head -n 1) ;;
	*.ipa)
		unzip -q "$target" -d "$work/ipa" || { echo "store-check: cannot unzip $target" >&2; exit 2; }
		app=$(ls -d "$work"/ipa/Payload/*.app 2>/dev/null | head -n 1)
		;;
	*.app) app=${target%/} ;;
	*) echo "store-check: $target is not an .xcarchive, .ipa or .app" >&2; exit 2 ;;
esac
[ -n "$app" ] && [ -d "$app" ] || { echo "store-check: no .app inside $target" >&2; exit 2; }
echo "store-check: $app"

bundles=("$app")
for ext in "$app"/PlugIns/*.appex; do [ -d "$ext" ] && bundles+=("$ext"); done

# A plist key's value; empty when the key is missing.
plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

# --- 1. Info.plist ---------------------------------------------------------------------
for b in "${bundles[@]}"; do
	p=$b/Info.plist
	name=$(basename "$b")
	[ -f "$p" ] || { fail "$name: no Info.plist"; continue; }
	if [ "$b" = "$app" ] && [ "$(plist_get "$p" ITSAppUsesNonExemptEncryption)" != false ]; then
		fail "$name: ITSAppUsesNonExemptEncryption is not NO"
	fi
	[ -n "$(plist_get "$p" CFBundleIdentifier)" ] || fail "$name: no bundle id"
	for key in NSAppleMusicUsageDescription BGTaskSchedulerPermittedIdentifiers; do
		plist_get "$p" "$key" >/dev/null && fail "$name: Info.plist has $key"
	done
	if [ "$b" = "$app" ]; then
		modes=$(plist_get "$p" UIBackgroundModes | sed -n 's/^ *//p' | grep -v '[{}]' | tr '\n' ' ')
		[ "$modes" = "audio " ] || fail "$name: background modes are '$modes', expected only audio"
	fi
done
[ $failures -eq 0 ] && note "Info.plist: encryption flag, no Apple Music or background tasks, audio only"

# --- 2. privacy manifests --------------------------------------------------------------
before=$failures
for b in "${bundles[@]}"; do
	m=$b/PrivacyInfo.xcprivacy
	name=$(basename "$b")
	if [ ! -f "$m" ]; then fail "$name: PrivacyInfo.xcprivacy missing"; continue; fi
	plutil -lint "$m" >/dev/null 2>&1 || { fail "$name: PrivacyInfo.xcprivacy is not a valid plist"; continue; }
	[ "$(plist_get "$m" NSPrivacyTracking)" = false ] || fail "$name: NSPrivacyTracking is not false"
	[ -z "$(plist_get "$m" NSPrivacyTrackingDomains | grep -v '^[{}]\|Array' )" ] || fail "$name: tracking domains listed"
	[ -z "$(plist_get "$m" NSPrivacyCollectedDataTypes | grep -v '^[{}]\|Array')" ] || fail "$name: collected data types listed"
	if [ "$b" = "$app" ]; then
		for c in UserDefaults FileTimestamp SystemBootTime; do
			plutil -p "$m" | grep -q "NSPrivacyAccessedAPICategory$c" || fail "$name: no $c required-reason entry"
		done
	fi
done
[ $failures -eq $before ] && note "privacy manifests: valid, no tracking, no collected data, required reasons declared"

# --- 3. fixtures and mock data ---------------------------------------------------------
before=$failures
found=$(find "${bundles[@]}" -type f \( -iname '*fixture*' -o -iname '*mock*' -o -iname '*.mp4' -o -iname '*.m4a' \
	-o -iname '*.m4v' -o -iname '*.aac' -o -iname '*.mov' -o -iname '*.json' -o -iname 'demo*' \) 2>/dev/null | head -n 10)
[ -z "$found" ] || fail "fixtures or sample media in the bundle:
$found"
[ $failures -eq $before ] && note "no fixtures, mock data or sample media in the bundle"

# --- 4. binaries: music library and web-only symbols -----------------------------------
# An archive's app is stripped (its Swift symbols are gone), so the type names are read
# from the archive's dSYM, which keeps the full symbol table. Without one (an .ipa or an
# .app that was stripped) only the imports are checked, and it says so.
before=$failures
main=$(plist_get "$app/Info.plist" CFBundleExecutable)
syms_from=()
if [ -d "$target/dSYMs" ]; then
	while IFS= read -r f; do syms_from+=("$f"); done < <(find "$target/dSYMs" -path '*/Contents/Resources/DWARF/*' -type f)
fi
bins=()
while IFS= read -r f; do
	file -b "$f" | grep -q 'Mach-O' && bins+=("$f")
done < <(find "${bundles[@]}" -type f ! -name '*.car' 2>/dev/null)
[ ${#bins[@]} -gt 0 ] || fail "no Mach-O binaries found in the bundle"
[ ${#syms_from[@]} -gt 0 ] || syms_from=(${bins[@]+"${bins[@]}"})
for bin in ${bins[@]+"${bins[@]}"}; do
	undef=$(xcrun nm -u "$bin" 2>/dev/null)
	if [ -z "$undef" ]; then
		[ "$bin" = "$app/$main" ] && fail "$main: nm -u listed nothing"
		continue
	fi
	syms=$(printf '%s\n' "$undef" | xcrun swift-demangle | grep -E "$MUSIC_LIBRARY_SYMBOLS" | head -n 5)
	[ -z "$syms" ] || fail "${bin#"$app"/} uses the music library:
$syms"
done
seen_app=0
for bin in ${syms_from[@]+"${syms_from[@]}"}; do
	names=$(xcrun nm "$bin" 2>/dev/null | xcrun swift-demangle)
	grep -q 'AntresolTV\.AntresolTVApp' <<< "$names" && seen_app=1
	if [ -n "$WEB_ONLY_SYMBOLS" ]; then
		syms=$(grep -E "$WEB_ONLY_SYMBOLS" <<< "$names" | head -n 5)
		[ -z "$syms" ] || fail "$(basename "$bin") carries a web-only feature:
$syms"
	fi
done
if [ $seen_app -eq 1 ]; then
	[ $failures -eq $before ] && note "binaries: no music library, no web-only feature types (symbols read from ${#syms_from[@]} file(s))"
else
	echo "warn: no AntresolTV.AntresolTVApp symbol in the binaries (stripped, no dSYM): the type-name check saw nothing; run it on the .xcarchive"
fi

# --- 5. words --------------------------------------------------------------------------
# Every file of the bundle as text: binary plists (compiled string tables, Info.plist) are
# converted, everything else is read as it is.
before=$failures
dump=$work/dump
mkdir -p "$dump"
n=0
while IFS= read -r f; do
	n=$((n + 1))
	rel=${f#"$app"/}
	if [ "$(head -c 6 "$f" 2>/dev/null)" = bplist ]; then
		plutil -convert xml1 -o "$dump/$n.txt" "$f" 2>/dev/null || cp "$f" "$dump/$n.txt"
	else
		cp "$f" "$dump/$n.txt"
	fi
	printf '%s\n' "$rel" > "$dump/$n.name"
	file -b "$f" | grep -q 'Mach-O' && : > "$dump/$n.bin"
done < <(find "${bundles[@]}" -type f)
[ $n -gt 0 ] || fail "no files in the bundle to scan"

allow=$work/allow
sed -n 's/^allow: *//p' "$words_file" > "$allow"
[ -s "$allow" ] || echo '^$^' > "$allow" # matches nothing

for t in "$dump"/*.txt; do
	[ -e "$t" ] || continue
	id=${t%.txt}
	rel=$(cat "$id.name")
	hits=$({ LC_ALL=C grep -a -o -i -E "$HARD_WORDS" "$t"; [ -z "$HARD_WORDS_RU" ] || LC_ALL=C grep -a -o -E "$HARD_WORDS_RU" "$t"; } | sort -u | head -n 5)
	[ -z "$hits" ] || fail "$rel carries banned words:
$hits"
	[ -n "$SOFT_WORDS" ] || continue
	if [ -e "$id.bin" ]; then
		# a binary: the identifiers that contain a soft word, minus the allowed ones
		hits=$(LC_ALL=C grep -a -o -i -E "[A-Za-z0-9_\$.]*($SOFT_WORDS)[A-Za-z0-9_\$.]*" "$t" | sort -u | grep -v -E -f "$allow" | head -n 8)
		[ -z "$hits" ] || fail "$rel: identifiers with a soft word that no allow line of the words file covers:
$hits"
	else
		hits=$(LC_ALL=C grep -a -o -i -E "(^|[^A-Za-z])($SOFT_WORDS)([^A-Za-z]|\$)" "$t" | sort -u | head -n 5)
		[ -z "$hits" ] || fail "$rel (a resource) has a soft word:
$hits"
	fi
done
[ $failures -eq $before ] && note "words: $n files scanned (bundle, extension, string tables), none of the banned words"

# --- 6. the store texts ----------------------------------------------------------------
before=$failures
if [ -d "$here/fastlane/metadata" ]; then
	meta=$work/metadata.txt
	find "$here/fastlane/metadata" -type f -exec cat {} + > "$meta"
	hits=$({ LC_ALL=C grep -a -o -i -E "$HARD_WORDS${SOFT_WORDS:+|$SOFT_WORDS}" "$meta"; [ -z "$HARD_WORDS_RU" ] || LC_ALL=C grep -a -o -E "$HARD_WORDS_RU" "$meta"; } | sort -u | head -n 5)
	[ -z "$hits" ] || fail "fastlane/metadata carries banned words:
$hits"
	[ $failures -eq $before ] && note "store texts (fastlane/metadata): clean"
fi

echo
if [ $failures -eq 0 ]; then
	echo "store-check: OK ($(basename "$app"))"
	exit 0
fi
echo "store-check: $failures problem(s)"
exit 1
