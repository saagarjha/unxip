#!/bin/sh

set -x

swiftc -O -whole-module-optimization -parse-as-library -target x86_64-apple-macosx12.0 unxip.swift -o unxip-x86_64
swiftc -O -whole-module-optimization -parse-as-library -target arm64-apple-macosx12.0 unxip.swift -o unxip-arm64
lipo -create unxip-arm64 unxip-x86_64 -output unxip
codesign -s "Developer ID" --options=runtime --timestamp unxip
zip unxip.zip unxip
xcrun notarytool submit unxip.zip --keychain-profile "AC_PASSWORD" --wait
