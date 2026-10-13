#!/bin/zsh
# builds the .app into ./build; `install` copies it to /Applications, `dmg` makes a release image,
# `debug` builds build/baski-debug with the screenshot/fake-data hooks
set -e
cd "${0:A:h}"
NAME="baski"
APP="build/$NAME.app"
if [[ "$1" == "debug" ]]; then
  mkdir -p build; swiftc -D DEBUG -o build/baski-debug main.swift; echo "built build/baski-debug"; exit 0
fi
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O -target arm64-apple-macos14 -o build/baski-arm64 main.swift
swiftc -O -target x86_64-apple-macos14 -o build/baski-x86_64 main.swift
lipo -create build/baski-arm64 build/baski-x86_64 -output "$APP/Contents/MacOS/baski"
rm build/baski-*
cp Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources"; cp assets/AppIcon.icns "$APP/Contents/Resources/"
xattr -cr "$APP"; codesign -s - --force "$APP"
if [[ "$1" == "install" ]]; then
  rm -rf /Applications/"$NAME.app"; cp -R "$APP" /Applications/; echo "installed /Applications/$NAME.app"
elif [[ "$1" == "dmg" ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
  STAGE=build/dmg; rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
  rm -f "build/$NAME-$VERSION.dmg"
  hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -format UDZO "build/$NAME-$VERSION.dmg"
  rm -rf "$STAGE"; echo "built build/$NAME-$VERSION.dmg"
fi
