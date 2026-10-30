<p align="center"><img src="assets/AppIcon-1024.png" width="160" alt="Logo NotchIsland"></p>

<h1 align="center">NotchIsland</h1>

<p align="center"><a href="https://achmadtaufikhidayatullah.github.io/NotchIsland/">Situs</a> · <a href="https://github.com/achmadtaufikhidayatullah/NotchIsland/releases/latest/download/NotchIsland.dmg">Download</a> · <a href="#instalasi">Instalasi</a></p>

Dynamic Island untuk Mac. App ini mengubah notch MacBook menjadi pulau hidup yang menampilkan aktivitas **Claude Code**, **Antigravity**, media yang sedang diputar, peringatan limit, dan command terminal yang selesai.

App otomatis mendeteksi device dan ukuran notch, jadi posisinya presisi. Di layar tanpa notch (MacBook Air/Pro M1, Mac Intel, monitor eksternal), island **tidak terlihat saat diam**. Island hanya muncul saat ada live activity atau saat kursor berhenti sebentar di tengah atas layar, dan disembunyikan saat app full-screen, supaya tidak menutupi tab browser atau judul jendela.

> NotchIsland tidak berafiliasi dengan Anthropic, Google, maupun Apple.

---

## Fitur

### Live activity (notch melebar sementara)

| Kejadian | Tampilan | Bunyi |
|---|---|---|
| Claude / Antigravity sedang bekerja | logo berputar/berdenyut + % limit + ring | – |
| Agent menunggu izin | logo oranye · apa yang diminta, mis. `Bash` · `npm install axios` ✋ | – |
| Prompt selesai | ✓ hijau "Selesai" (4 dtk) | Glass |
| Limit melewati 80% / 95% | nama jendela · "habis ±15.20" · % + ring | Ping / Sosumi |
| Limit reset | "Limit reset" ↻ hijau | Hero |
| Command terminal ≥30 dtk selesai | ✓ / ✗ · command · durasi (klik → buka terminal) | Tink / Basso |
| Media mulai diputar / berganti | thumbnail + equalizer (4 dtk) | – |
| Charger dicolok | ⚡ "Mengisi Daya" + baterai | – |

**Klik** sisi kiri/kanan notch saat live activity agent atau terminal tampil untuk langsung membuka app-nya (Claude Desktop / terminal tempat Claude berjalan, Antigravity, atau terminal command). Arahkan kursor ke notch untuk membuka island.

Saat tidak ada kejadian, notch kembali hitam polos seperti bawaan Mac.

### Shelf & AirDrop

Seret file dari Finder/desktop ke arah notch: island terbuka di tab **Shelf** dengan dua zona.

- **Shelf** — file "dititip" di notch (hanya rujukannya; file asli tetap di tempatnya). Seret keluar ke app atau folder mana pun, klik dua kali untuk membuka. Isi shelf diingat setelah restart; file yang dipindah/dihapus otomatis hilang dari shelf.
- **AirDrop** — lepas file di sini untuk langsung membuka pemilih perangkat AirDrop, atau klik untuk mengirim semua isi shelf.

Di MacBook ber-notch, area notch fisik (yang memang tertutup kamera) menjadi penangkap seretan, jadi island selalu terbuka saat file diseret ke sana.

### Mode sisi layar (opsional)

Pengaturan › Tampilan › Posisi › **Sisi kanan / kiri layar**: island menjadi tab vertikal yang menempel di tepi layar, cocok untuk Mac tanpa notch atau bila tidak ingin ada apa pun di tengah atas.

- Satu ring per agent (Claude, Antigravity): logo di tengah, persen limit di bawah. Arc berputar saat bekerja, oranye berdenyut saat menunggu, ✓ saat selesai.
- **Hover** tab → kartu detail di sampingnya (limit, sesi aktif, kuota Antigravity, musik). **Klik** ring → buka app-nya.
- Notifikasi (terminal, limit, charger, agent selesai/minta izin, lagu baru) muncul sebagai kartu kecil di samping tab dan bisa diklik.
- **⌥ Option + seret** tab untuk menggesernya naik-turun; posisinya diingat.
- **Mode mini**: tab mengecil menjadi garis tipis selama tidak ada aktivitas.

### Island terbuka (arahkan kursor ke notch)

Tab widget ada di kiri notch. Jam dan baterai ada di kanan.

| Widget | Isi |
|---|---|
| **Claude** | Kartu *Claude Usage* (limit sesi/mingguan resmi + waktu reset + perkiraan habis), kartu sesi (prompt, tool aktif, progress task list, ukuran konteks) |
| **Antigravity** | Kuota per model (Gemini, Claude & GPT × 5 jam/mingguan), status agent |
| **Sedang Diputar** | Artwork besar dengan ikon app sumber, judul, artis/channel, progress, ⏮ ⏯ ⏭. Warna aksen (artis, progress, pendaran latar) diambil dari artwork. Mendukung semua pemutar, termasuk YouTube di browser |
| **Kalender** | Bulan & strip 7 hari (hari ini ditandai), acara hari yang dipilih dengan warna kalendernya, dan tombol **Gabung** untuk link Zoom/Meet/Teams. Membaca Kalender macOS (termasuk akun Google/iCloud yang tersinkron); izin diminta saat menekan *Izinkan akses* |
| **Shelf & AirDrop** | Seret file ke notch untuk dititip sementara, lalu seret keluar ke app/folder lain; lepas file di zona AirDrop untuk langsung mengirimnya. Klik kanan item untuk *Tampilkan di Finder*, *Kirim via AirDrop*, *Hapus dari shelf* |
| **Jam & Kontrol** | Jam, tanggal, slider volume & brightness (nonaktif secara default) |
| **Folder** | Shortcut Home, Desktop, Dokumen, Unduhan, Aplikasi (nonaktif secara default) |

---

## Instalasi

Ada dua cara: **unduh DMG** (paling mudah, tanpa terminal) atau **build sendiri dari source**.

### A. Unduh DMG (disarankan)

1. Unduh **[NotchIsland.dmg](https://github.com/achmadtaufikhidayatullah/NotchIsland/releases/latest/download/NotchIsland.dmg)** dari halaman [Releases](https://github.com/achmadtaufikhidayatullah/NotchIsland/releases/latest).
2. Buka file DMG, lalu seret **NotchIsland** ke folder **Applications**.
3. Buka NotchIsland dari folder Applications. App ini belum dinotarisasi Apple, jadi macOS menampilkan *"NotchIsland.app" Not Opened*. Klik **Done** (Selesai). **Jangan klik Move to Trash**, karena tombol itu menghapus app-nya.
   - Buka **Pengaturan Sistem › Privasi & Keamanan**, gulir ke bawah, lalu klik **Open Anyway** (Tetap Buka) di samping NotchIsland. Masukkan password atau Touch ID, lalu klik **Open Anyway** sekali lagi; **atau**
   - jalankan di Terminal: `xattr -dr com.apple.quarantine /Applications/NotchIsland.app`

   Panduan bergambar: [achmadtaufikhidayatullah.github.io/NotchIsland/#pasang](https://achmadtaufikhidayatullah.github.io/NotchIsland/#pasang)
4. Ikon kapsul muncul di menu bar. Lanjutkan ke [langkah 5](#5-jalankan) dan seterusnya untuk mengaktifkan login otomatis dan integrasi.

Mendukung Apple Silicon dan Intel. Di Mac tanpa notch, island hanya muncul saat ada aktivitas (tidak menutupi konten saat diam).

### B. Build dari source — cara cepat (kalau sudah terbiasa dengan terminal)

```bash
xcode-select --install          # sekali saja, kalau belum
git clone https://github.com/achmadtaufikhidayatullah/NotchIsland.git ~/Development/Swift/NotchIsland
cd ~/Development/Swift/NotchIsland
./build.sh && open build/NotchIsland.app
./hooks/install-hooks.sh        # status Claude Code
./hooks/install-zsh-hook.sh     # notifikasi command terminal (opsional)
```

### C. Build dari source — langkah demi langkah (untuk pemula)

Total waktunya sekitar 10–20 menit, kebanyakan untuk mengunduh compiler di langkah 2. Cukup **salin & tempel** perintah di kotak abu-abu ke Terminal, lalu tekan **Enter**.

#### 0. Pastikan Mac-mu cocok

Klik logo  di pojok kiri atas › **Tentang Mac Ini**. Yang dibutuhkan:
- **Chip:** Apple M1 atau lebih baru, atau Intel (di Mac tanpa notch, island hanya muncul saat ada aktivitas)
- **macOS:** 14 (Sonoma) atau lebih baru

#### 1. Buka Terminal

Tekan `⌘ Command` + `Spasi`, ketik **Terminal**, lalu tekan Enter. Semua perintah di bawah dijalankan di jendela ini.

#### 2. Pasang Xcode Command Line Tools (compiler dari Apple, gratis)

```bash
xcode-select --install
```

Akan muncul jendela dialog. Klik **Install**, setujui lisensinya, lalu tunggu sampai selesai (±5–15 menit). Kalau muncul pesan *"already installed"*, berarti sudah terpasang dan kamu bisa langsung ke langkah berikutnya.

#### 3. Unduh kode NotchIsland

```bash
mkdir -p ~/Development/Swift
git clone https://github.com/achmadtaufikhidayatullah/NotchIsland.git ~/Development/Swift/NotchIsland
cd ~/Development/Swift/NotchIsland
```

Kamu boleh memakai folder lain, asalkan perintah `cd` mengarah ke folder tersebut.

#### 4. Build aplikasinya

```bash
./build.sh
```

Proses ini memakan waktu ±1 menit dan selesai dengan pesan **✓ Selesai**. Semua yang dibutuhkan sudah ada di repo (termasuk decoder zstd di `ThirdParty/`), jadi tidak perlu Homebrew. Kalau ada yang kurang, skrip memberi tahu perintah yang perlu dijalankan. Kalau muncul `permission denied`, jalankan `chmod +x build.sh release.sh hooks/*.sh` lalu ulangi.

#### 5. Jalankan

```bash
open build/NotchIsland.app
```

- Tidak ada jendela yang terbuka. Yang muncul adalah **ikon kapsul** di menu bar kanan atas, dan itulah pusat pengaturannya.
- **Arahkan kursor ke notch** untuk membuka island.
- Supaya otomatis jalan setiap Mac dinyalakan: ikon kapsul › **Buka saat login**.

#### 6. Hubungkan Claude Code (opsional, untuk monitoring Claude)

Ikon kapsul › **Pengaturan…** › **Integrasi** › **Claude Code** › **Hubungkan**. (Saat pertama kali dibuka, halaman ini muncul otomatis.)

Lalu **mulai prompt baru** di Claude Code (terminal atau aplikasi Claude Desktop). Island akan menampilkan status kerjanya. Untuk persen limit resmi, cukup buka **aplikasi Claude Desktop** sekali.

#### 7. Notifikasi command terminal (opsional)

Ikon kapsul › **Pengaturan…** › **Integrasi** › **Terminal (zsh)** › **Hubungkan**.

Tutup lalu buka lagi Terminal. Uji dengan `sleep 31`, lalu pindah ke app lain: notch akan menampilkan ✓ saat command selesai.

#### 8. Izin yang mungkin diminta macOS

| Dialog | Kapan | Pilih |
|---|---|---|
| *"NotchIsland ingin mengontrol Music/Spotify"* | Saat Music/Spotify terbuka | **Izinkan**, supaya widget musik bisa membaca lagu |
| *"Item login ditambahkan"* | Saat mengaktifkan Buka saat login | Notifikasi biasa, tidak perlu tindakan |

### Memperbarui ke versi terbaru

```bash
cd ~/Development/Swift/NotchIsland
git pull
./build.sh
pkill -x NotchIsland; open build/NotchIsland.app
```

> Build bersifat ad-hoc signed (tanpa sertifikat Apple Developer). Karena di-build sendiri dari source, macOS tidak memblokirnya. Setelah build ulang, macOS bisa meminta izin Otomatisasi (Music/Spotify) lagi.

---

## Detail hook (referensi)

Hook dibutuhkan untuk status Claude Code dan notifikasi terminal. Cara termudah: ikon kapsul › **Pengaturan…** › **Integrasi** (tombol Hubungkan / Lepas). Skrip di `hooks/` melakukan hal yang sama dari terminal. Semua perubahan hanya menyentuh entri milik NotchIsland, dan file aslinya dibackup lebih dulu.

### 1. Hook Claude Code

Menulis status sesi (bekerja / menunggu / selesai, tool aktif, task list) yang dibaca island.

```bash
./hooks/install-hooks.sh              # pasang
./hooks/install-hooks.sh --uninstall  # lepas
```

- Mengubah `~/.claude/settings.json` (backup: `settings.json.bak-notchisland`)
- Event: `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`, `SessionEnd`
- Hook dijalankan oleh app NotchIsland sendiri (`NotchIsland --claude-hook`, ±10 ms per tool), tanpa Python atau dependensi lain
- Kalau app dipindah (misalnya ke folder Aplikasi) atau masih memakai hook versi lama, path hook otomatis diperbarui saat NotchIsland dibuka
- Berlaku untuk Claude Code di terminal maupun di aplikasi Claude Desktop (tab Code)

### 2. Hook terminal (zsh)

Memberi tahu island saat command yang berjalan ≥30 detik selesai.

```bash
./hooks/install-zsh-hook.sh              # pasang
./hooks/install-zsh-hook.sh --uninstall  # lepas
```

- Menambah satu baris `source …` di `~/.zshrc` (backup: `.zshrc.bak-notchisland`)
- Aktif di tab/jendela terminal **baru**, atau setelah `source ~/.zshrc`
- Ubah ambang: Pengaturan › Notifikasi › Terminal (atau `export NOTCH_MIN_SECONDS=60` di `~/.zshrc`, yang lebih diutamakan)
- Diabaikan: Ctrl-C, dan program interaktif (`vim`, `ssh`, `top`, `tail`, `claude`, REPL `node`/`python`, …)

Antigravity dan widget musik **tidak** memerlukan hook.

---

## Menu & Pengaturan

Ikon kapsul di menu bar berisi: **Pengaturan… (⌘,)**, **Hubungkan Claude Code…** (bila belum terhubung), **Tes notifikasi ›**, **Deteksi ulang layar**, dan **Keluar**.

Jendela **Pengaturan**:

| Bagian | Isi |
|---|---|
| **Tampilan** | Posisi (tengah atas / sisi kanan / sisi kiri, mode mini), layar (otomatis ke layar ber-notch / selalu layar menu bar), info notch terdeteksi, tampilkan island saat diam di layar tanpa notch, selalu tampilkan ring usage Claude |
| **Widget** | Nyala/mati widget (Claude, Antigravity, Sedang Diputar, Jam & Kontrol, Folder), mode live activity musik |
| **Notifikasi** | Bunyi, ambang peringatan limit (default 80% & 95%), peringatan reset, notifikasi command terminal & durasi minimalnya, tombol tes |
| **Integrasi** | Hubungkan/lepas Claude Code dan Terminal (zsh), dengan konfirmasi & backup |
| **Umum** | Buka saat login, versi, cek pembaruan dari GitHub Releases, link situs & source |

Saat pertama kali dibuka, NotchIsland langsung menampilkan **Pengaturan › Integrasi** supaya Claude Code bisa dihubungkan.

---

## Data yang dibaca

NotchIsland **tidak mengirim data ke server mana pun** dan tidak menyimpan prompt atau isi percakapan.

| Sumber | Apa yang dibaca | Catatan |
|---|---|---|
| `~/Library/Application Support/NotchIsland/claude/*.json` | Status sesi dari hook Claude | Ditulis oleh hook sendiri |
| `~/.claude/projects/**/*.jsonl` | Hanya angka `usage` token per pesan | Untuk estimasi & ukuran konteks |
| Cache HTTP Claude Desktop | Response `/api/organizations/<id>/usage` (persen limit resmi) | Dari entry lain hanya URL-nya yang dibaca; tanpa token/keychain |
| `~/.gemini/antigravity*/brain/*/…/transcript.jsonl` | Tipe baris terakhir (status agent) | Hanya bagian akhir file (64 KB) |
| Language server Antigravity (`127.0.0.1`) | Ringkasan kuota | Token CSRF lokal dibaca dari daftar proses, hanya dikirim ke 127.0.0.1, tidak disimpan |
| Now Playing sistem (via `/usr/bin/perl`) | Judul, artis, artwork, progress media | Lihat catatan di bawah |
| Music / Spotify (AppleScript) | Lagu yang diputar | Cadangan bila Now Playing sistem kosong; perlu izin Otomatisasi |
| `~/Library/Application Support/NotchIsland/terminal/*.json` | Command, exit code, durasi, folder | Ditulis hook zsh, langsung dihapus setelah dibaca |

---

## Catatan teknis & risiko

- **Limit resmi Claude** dibaca dari cache internal Claude Desktop, yang formatnya tidak didokumentasikan. Kalau formatnya berubah, island otomatis kembali ke estimasi token lokal.
- **Kuota Antigravity** hanya bisa diambil saat Antigravity terbuka. Angka terakhir tetap ditampilkan beserta umurnya.
- **Now Playing sistem**: sejak macOS 15.4, app pihak ketiga tidak bisa membaca Now Playing. NotchIsland memuat `NowPlayingBridge.dylib` ke dalam `/usr/bin/perl` (binary Apple yang masih diizinkan). Ini celah, bukan API resmi. Kalau Apple menutupnya, widget kembali ke mode Music/Spotify.
- **Slider brightness** memakai framework privat `DisplayServices`. Kalau tidak tersedia, slider disembunyikan.

---

## Troubleshooting

| Masalah | Solusi |
|---|---|
| Status Claude tidak muncul | Pastikan menu › Integrasi › Claude Code tercentang (atau `grep -- --claude-hook ~/.claude/settings.json`). Mulai prompt baru setelah memasang. |
| Persen limit Claude kosong | Buka Claude Desktop sekali (cache-nya perlu ada). |
| Kuota Antigravity "tertutup" | Buka Antigravity IDE. |
| Notif terminal tidak muncul | Buka tab terminal baru, lalu cek `whence -w _notch_precmd` (harus `function`). Uji dengan `sleep 31`. |
| Musik/YouTube tidak terbaca | Cek apakah media muncul di Control Center › Now Playing. Untuk Music/Spotify, izinkan di Pengaturan Sistem › Privasi & Keamanan › Otomatisasi. |
| Posisi notch meleset | Menu › Deteksi ulang layar. |
| Cek data dari terminal | `build/NotchIsland.app/Contents/MacOS/NotchIsland --print-claude` |
| Uji perilaku Mac tanpa notch di Mac ber-notch | `open build/NotchIsland.app --args --simulate-no-notch` |
| Uji logika peringatan limit | `build/NotchIsland.app/Contents/MacOS/NotchIsland --test-limits` |

---

## Membuat rilis (untuk maintainer)

```bash
./release.sh 1.0.0
```

- Build **universal** (Apple Silicon + Intel), lalu membuat **`dist/NotchIsland.dmg`** (plus arsip berversi di `dist/arsip/`).
- Buat rilis baru di GitHub dengan tag `v1.0.0`, lalu unggah **`dist/NotchIsland.dmg`**, persis dengan nama itu. Link download di README dan landing page memakai `releases/latest/download/NotchIsland.dmg`, jadi file dengan nama lain akan menghasilkan 404.
- Untuk pengembangan sehari-hari, `./build.sh` cukup membangun untuk arsitektur Mac-mu saja (lebih cepat). Build universal: `ARCHS="arm64 x86_64" ./build.sh`.
- **Landing page** ada di `docs/index.html` (statis, tanpa build). Aktifkan sekali di GitHub: **Settings › Pages › Build and deployment › Deploy from a branch** → `main` / `/docs`. Situs akan tampil di `https://achmadtaufikhidayatullah.github.io/NotchIsland/`. Tambahkan `?state=0`–`6` di URL untuk membekukan demo notch (berguna untuk screenshot).
- App ditandatangani ad-hoc dan belum dinotarisasi. Supaya bisa dibuka dengan dobel klik tanpa peringatan Gatekeeper, diperlukan sertifikat Developer ID dari Apple Developer Program.

---

## Mencopot sepenuhnya

```bash
./hooks/install-hooks.sh --uninstall
./hooks/install-zsh-hook.sh --uninstall
pkill -x NotchIsland
rm -rf ~/Library/Application\ Support/NotchIsland
defaults delete local.notchisland
```

---

## Struktur proyek

```
NotchIsland/
├── Sources/
│   ├── main.swift          # deteksi notch, model, tampilan, menu
│   ├── Widgets.swift       # daftar widget & tab
│   ├── Claude.swift        # sesi Claude dari hook + estimasi token
│   ├── ClaudeUsage.swift   # limit resmi dari cache Claude Desktop + kartu usage
│   ├── Antigravity.swift   # aktivitas & kuota Antigravity
│   ├── LimitWatch.swift    # peringatan 80/95%, reset, perkiraan habis
│   ├── TerminalWatch.swift # notifikasi command terminal
│   └── Media.swift         # Now Playing sistem + Music/Spotify
├── NowPlayingBridge/       # dylib + loader Perl untuk Now Playing sistem
├── hooks/                  # hook Claude, hook zsh, skrip pasang/lepas
├── assets/                 # ikon app (make-icon.swift → AppIcon.icns)
├── ThirdParty/zstd/        # decoder zstd v1.5.7 (source resmi, BSD)
├── zstd-bridge.h           # header zstd untuk Swift
├── build.sh                # build app (arsitektur Mac ini / universal)
├── release.sh              # build universal + DMG
└── docs/                   # landing page (GitHub Pages)
```

---

## Lisensi

[MIT](LICENSE)

---

## Kredit

- Pendekatan membaca limit dari cache Claude Desktop dan kuota dari language server Antigravity terinspirasi dari [Codenotch](https://github.com/IGedeMiarta/codenotch) (MIT).
- Decoder [zstd](https://github.com/facebook/zstd) v1.5.7 oleh Meta (BSD), disertakan di `ThirdParty/zstd`.
- Jembatan Now Playing ditulis ulang mengikuti pola [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3-Clause).
