#!/bin/zsh
# Build NotchIsland.app dari Sources/ → build/NotchIsland.app
#
#   ./build.sh                          # arsitektur Mac ini saja (cepat, untuk pengembangan)
#   ARCHS="arm64 x86_64" ./build.sh     # universal (Apple Silicon + Intel), dipakai release.sh
#   VERSION=1.2.0 ./build.sh            # nomor versi di Info.plist
set -e
cd "$(dirname "$0")"

fail() { print -u2 -- "\n✗ $1\n"; exit 1; }

# --- Cek prasyarat (pesan jelas untuk yang baru pertama build) ---
xcode-select -p >/dev/null 2>&1 && command -v swiftc >/dev/null \
  || fail "Xcode Command Line Tools belum terpasang. Jalankan: xcode-select --install  (lalu ulangi ./build.sh)"

ARCHS=(${=ARCHS:-$(uname -m)})
VERSION="${VERSION:-1.0.0}"
MIN_MACOS=14.0
APP="build/NotchIsland.app"
OBJ="build/obj"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
echo "→ Mengompilasi NotchIsland $VERSION untuk ${ARCHS[*]} (±1 menit per arsitektur)…"

# Decoder zstd (untuk membaca cache Claude Desktop) dari source di ThirdParty/zstd — tanpa Homebrew.
ZSTD="ThirdParty/zstd/lib"
ZSTD_SRC=($ZSTD/common/*.c $ZSTD/decompress/*.c)

BINARIES=()
for arch in $ARCHS; do
  mkdir -p "$OBJ/$arch"
  objs=()
  for src in $ZSTD_SRC; do
    o="$OBJ/$arch/${src:t:r}.o"
    clang -c -O2 -arch "$arch" -mmacosx-version-min=$MIN_MACOS -DZSTD_DISABLE_ASM -DZSTD_MULTITHREAD=0 \
      -I "$ZSTD" -I "$ZSTD/common" "$src" -o "$o"
    objs+=("$o")
  done
  rm -f "$OBJ/$arch/libzstd.a"
  ar rcs "$OBJ/$arch/libzstd.a" $objs

  swiftc -O -swift-version 5 -target "$arch-apple-macos$MIN_MACOS" \
    -framework AppKit -framework SwiftUI -framework IOKit -framework CoreAudio -framework AudioToolbox \
    -import-objc-header zstd-bridge.h -Xcc -I"$ZSTD" -Xlinker "$OBJ/$arch/libzstd.a" \
    Sources/*.swift -o "$OBJ/$arch/NotchIsland"
  BINARIES+=("$OBJ/$arch/NotchIsland")
done
lipo -create $BINARIES -output "$APP/Contents/MacOS/NotchIsland"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NotchIsland</string>
  <key>CFBundleDisplayName</key><string>NotchIsland</string>
  <key>CFBundleIdentifier</key><string>local.notchisland</string>
  <key>CFBundleExecutable</key><string>NotchIsland</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>NotchIsland membaca lagu yang sedang diputar di Music dan Spotify untuk ditampilkan di Dynamic Island.</string>
</dict>
</plist>
PLIST

# Jembatan Now Playing sistem: dylib yang dimuat ke /usr/bin/perl (lihat NowPlayingBridge/).
ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(-arch "$arch"); done
clang -dynamiclib -fobjc-arc -O2 $ARCH_FLAGS -mmacosx-version-min=$MIN_MACOS \
  -framework Foundation -framework AppKit \
  NowPlayingBridge/NowPlayingBridge.m -o "$APP/Contents/Resources/NowPlayingBridge.dylib"
cp NowPlayingBridge/nowplaying.pl "$APP/Contents/Resources/nowplaying.pl"
cp hooks/notch-terminal.zsh "$APP/Contents/Resources/notch-terminal.zsh"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # dibuat oleh assets/make-icon.swift
codesign --force --sign - "$APP/Contents/Resources/NowPlayingBridge.dylib"

codesign --force --sign - "$APP"
touch "$APP"   # supaya Finder memuat ulang ikon
echo "Built: $PWD/$APP ($(lipo -archs "$APP/Contents/MacOS/NotchIsland"))"
echo "✓ Selesai. Jalankan dengan: open build/NotchIsland.app"
