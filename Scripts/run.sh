#!/usr/bin/env bash
# Extract products from the HAR files into output/products.json, then verify it.
#   ./run.sh                     # uses ../milk.har and ../others.har
#   ./run.sh path/to/a.har ...   # any HAR files
set -euo pipefail
cd "$(dirname "$0")"

hars=("$@")
[ ${#hars[@]} -eq 0 ] && hars=(../milk.har ../others.har)

python3 extract_har.py "${hars[@]}" -o output/products.json

mkdir -p .build
swift_flags=(-parse-as-library)
# Command Line Tools 16.x ship a duplicate SwiftBridging modulemap that breaks
# `import Foundation`; hide it with a VFS overlay (no system files are modified).
clt=/Library/Developer/CommandLineTools/usr/include/swift
if [ "$(xcode-select -p)" = /Library/Developer/CommandLineTools ] && [ -f "$clt/module.modulemap" ] && [ -f "$clt/bridging.modulemap" ]; then
    : > .build/empty.modulemap
    cat > .build/overlay.yaml <<EOF
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "directory", "name": "$clt",
  "contents": [ { "type": "file", "name": "module.modulemap", "external-contents": "$PWD/.build/empty.modulemap" } ] } ] }
EOF
    swift_flags+=(-vfsoverlay .build/overlay.yaml -Xcc -ivfsoverlay -Xcc .build/overlay.yaml -module-cache-path .build/module-cache)
fi

if xcrun --find xcodebuild >/dev/null 2>&1 && [ "$(xcode-select -p)" != /Library/Developer/CommandLineTools ]; then
    echo "Verifying SwiftData import (in-memory store)..."
    swiftc "${swift_flags[@]}" ../UI/ShellApp/ShellApp/Catalog/*.swift verify_import.swift -o .build/verify_import
    .build/verify_import output/products.json
else
    echo "Full Xcode not selected; SwiftData macros unavailable. Verifying JSON decoding only..."
    swiftc "${swift_flags[@]}" ../UI/ShellApp/ShellApp/Catalog/ProductDTO.swift verify_decode.swift -o .build/verify_decode
    .build/verify_decode output/products.json
fi
