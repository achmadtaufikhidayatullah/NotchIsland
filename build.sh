#!/bin/zsh
# Build NotchIsland.app dari Sources/ → build/NotchIsland.app
set -e
cd "$(dirname "$0")"

fail() { print -u2 -- "\n✗ $1\n"; exit 1; }

# --- Cek prasyarat (pesan jelas untuk yang baru pertama build) ---
[[ "$(uname -m)" == "arm64" ]] || fail "NotchIsland saat ini hanya untuk Mac Apple Silicon (M1 ke atas)."
xcode-select -p >/dev/null 2>&1 && command -v swiftc >/dev/null \
  || fail "Xcode Command Line Tools belum terpasang. Jalankan: xcode-select --install  (lalu ulangi ./build.sh)"
command -v brew >/dev/null \
  || fail "Homebrew belum terpasang. Lihat https://brew.sh lalu jalankan: brew install zstd"

# zstd (untuk cache Claude Desktop) di-link statis: hanya perlu saat build.
ZSTD_PREFIX="$(brew --prefix zstd 2>/dev/null || echo /opt/homebrew)"
[[ -f "$ZSTD_PREFIX/lib/libzstd.a" ]] || fail "Library zstd belum terpasang. Jalankan: brew install zstd"

APP="build/NotchIsland.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
echo "→ Mengompilasi NotchIsland (±1 menit)…"

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -framework AppKit -framework SwiftUI -framework IOKit -framework CoreAudio -framework AudioToolbox \
  -import-objc-header zstd-bridge.h -Xcc -I"$ZSTD_PREFIX/include" -Xlinker "$ZSTD_PREFIX/lib/libzstd.a" \
  Sources/*.swift -o "$APP/Contents/MacOS/NotchIsland"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NotchIsland</string>
  <key>CFBundleIdentifier</key><string>local.notchisland</string>
  <key>CFBundleExecutable</key><string>NotchIsland</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>NotchIsland membaca lagu yang sedang diputar di Music dan Spotify untuk ditampilkan di Dynamic Island.</string>
</dict>
</plist>
PLIST

# Jembatan Now Playing sistem: dylib yang dimuat ke /usr/bin/perl (lihat NowPlayingBridge/).
mkdir -p "$APP/Contents/Resources"
clang -dynamiclib -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=14.0 \
  -framework Foundation -framework AppKit \
  NowPlayingBridge/NowPlayingBridge.m -o "$APP/Contents/Resources/NowPlayingBridge.dylib"
cp NowPlayingBridge/nowplaying.pl "$APP/Contents/Resources/nowplaying.pl"
cp hooks/notch-terminal.zsh "$APP/Contents/Resources/notch-terminal.zsh"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # dibuat oleh assets/make-icon.swift
codesign --force --sign - "$APP/Contents/Resources/NowPlayingBridge.dylib"

codesign --force --sign - "$APP"
touch "$APP"   # supaya Finder memuat ulang ikon
echo "Built: $PWD/$APP"
echo "✓ Selesai. Jalankan dengan: open build/NotchIsland.app"
