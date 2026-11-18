#!/bin/zsh
# Build Release, install to /Applications, and register the Finder extension.
#   ./install.sh                  asks for the language (Enter follows the Mac)
#   ./install.sh --lang ko|en     shows that language everywhere, whatever the Mac's is
#   ./install.sh --lang auto      follows the Mac's language
set -euo pipefail
cd "$(dirname "$0")"

lang=auto
if [[ "${1:-}" == --lang ]]; then
  lang="${2:-}"
elif [[ -t 0 ]]; then
  print "언어 / Language\n  1) Mac 설정을 따름 / Follow macOS (Enter)\n  2) 한국어\n  3) English"
  read "choice?> "
  case "$choice" in 2) lang=ko ;; 3) lang=en ;; esac
fi
case "$lang" in
  ko|en) ;;
  auto) lang="" ;;
  *) echo "Unknown language '$lang': use ko, en or auto." >&2; exit 1 ;;
esac

xcodegen generate --quiet
# Fresh products: Xcode doesn't re-embed an extension whose folder looks unchanged, which would
# keep the previous build's language in it.
rm -rf .build/dd/Build/Products
xcodebuild -quiet -project MarkdownEditor.xcodeproj -scheme MarkdownEditor -configuration Release \
  -derivedDataPath .build/dd -clonedSourcePackagesDirPath .build/spm APP_LANGUAGE="$lang" build

app=/Applications/MarkdownEditor.app
# The installed copy's own ID, which an older build may have had differently.
if installed=$(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null); then
  osascript -e "quit app id \"$installed\"" 2>/dev/null || true
fi
for _ in {1..50}; do pgrep -qf "$app/Contents/MacOS/" || break; sleep 0.2; done
if pgrep -qf "$app/Contents/MacOS/"; then
  echo "MarkdownEditor is still running (unsaved changes?). Quit it and rerun." >&2
  exit 1
fi
built="$PWD/.build/dd/Build/Products/Release/MarkdownEditor.app"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for ext in "$app"/Contents/PlugIns/*.appex(N); do pluginkit -r "$ext" 2>/dev/null || true; done
[[ -d "$app" ]] && "$lsregister" -u "$app" 2>/dev/null || true
rm -rf "$app"
ditto "$built" "$app"
# Xcode registers the build product too; drop it so Open With and Finder see one app.
for ext in "$built"/Contents/PlugIns/*.appex; do pluginkit -r "$ext" 2>/dev/null || true; done
"$lsregister" -u "$built" 2>/dev/null || true
rm -rf "$built"
"$lsregister" -f "$app"
for ext in "$app"/Contents/PlugIns/*.appex; do pluginkit -a "$ext"; done
pluginkit -e use -i "$(defaults read "$app/Contents/PlugIns/NewMarkdownFinder.appex/Contents/Info" CFBundleIdentifier)"
qlmanage -r >/dev/null 2>&1
echo "Installed $app (language: ${lang:-follows macOS})"
