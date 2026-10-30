#!/bin/zsh
# Membuat DMG rilis: build universal (Apple Silicon + Intel) → dist/NotchIsland-<versi>.dmg
#
#   ./release.sh 1.0.0
#
# Hasil:
#   dist/NotchIsland.dmg               — SATU-SATUNYA file yang diunggah ke GitHub Releases
#                                        (link "download versi terbaru" memakai nama ini)
#   dist/arsip/NotchIsland-1.0.0.dmg   — arsip per versi, tidak perlu diunggah
set -e
cd "$(dirname "$0")"

VERSION="${1:?Pemakaian: ./release.sh <versi>   (contoh: ./release.sh 1.0.0)}"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Versi harus berbentuk X.Y.Z (contoh 1.0.0)" >&2; exit 1; }

ARCHS="arm64 x86_64" VERSION="$VERSION" ./build.sh

STAGE="build/dmg"
rm -rf "$STAGE" && mkdir -p "$STAGE" dist/arsip
cp -R build/NotchIsland.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Cara membuka.txt" <<'TXT'
NotchIsland — cara memasang

1. Seret NotchIsland ke folder Applications.
2. Buka NotchIsland dari folder Applications.

Karena app ini belum dinotarisasi Apple, macOS akan menolak saat pertama dibuka:
  • Buka Pengaturan Sistem › Privasi & Keamanan, gulir ke bawah,
    lalu klik "Tetap Buka" (Open Anyway) di samping NotchIsland.
  • Atau jalankan di Terminal:
      xattr -dr com.apple.quarantine /Applications/NotchIsland.app

Setelah terbuka, ikon kapsul muncul di menu bar.
Hubungkan Claude Code lewat: ikon kapsul › Pengaturan… › Integrasi.

Source & panduan lengkap: https://github.com/achmadtaufikhidayatullah/NotchIsland
TXT

DMG="dist/arsip/NotchIsland-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "NotchIsland $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
cp "$DMG" dist/NotchIsland.dmg
rm -rf "$STAGE"

echo ""
echo "✓ $DMG ($(du -h "$DMG" | cut -f1)) — arsitektur: $(lipo -archs build/NotchIsland.app/Contents/MacOS/NotchIsland)"
echo "  Unggah dist/NotchIsland.dmg (bukan file di dist/arsip/) ke GitHub Releases dengan tag v$VERSION."
