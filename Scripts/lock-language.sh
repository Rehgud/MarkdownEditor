#!/bin/sh
# `./install.sh --lang ko|en` builds with APP_LANGUAGE set. Every other translation leaves the bundle,
# so the app, its Finder menu and Quick Look all show that language whatever the Mac's is.
# Unset, the Mac's language picks between them.
set -eu
[ -n "${APP_LANGUAGE:-}" ] || exit 0
for dir in "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"/*.lproj; do
  if [ -e "$dir" ] && [ "$(basename "$dir" .lproj)" != "$APP_LANGUAGE" ]; then rm -rf "$dir"; fi
done
plist="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
/usr/libexec/PlistBuddy -c "Delete :CFBundleLocalizations" "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations array" -c "Add :CFBundleLocalizations:0 string $APP_LANGUAGE" \
  -c "Set :CFBundleDevelopmentRegion $APP_LANGUAGE" "$plist"
