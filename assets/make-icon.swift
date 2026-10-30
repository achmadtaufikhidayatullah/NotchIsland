// Menggambar ikon NotchIsland (1024×1024) lalu menyimpannya sebagai PNG.
// Pemakaian: swift assets/make-icon.swift assets/AppIcon-1024.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// Superellipse (n≈5) — mendekati bentuk ikon macOS.
func squircle(_ r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let a = r.width / 2, b = r.height / 2
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = r.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = r.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

func radialGlow(_ center: CGPoint, _ radius: CGFloat, _ color: UInt32, _ alpha: CGFloat) {
    let g = CGGradient(colorsSpace: space, colors: [rgb(color, alpha), rgb(color, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

// --- Bentuk ikon + bayangan (grid ikon macOS: 824 pt di tengah kanvas 1024) ---
let iconRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let iconPath = squircle(iconRect)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(0x000000, 0.45))
ctx.addPath(iconPath)
ctx.setFillColor(rgb(0x0B0C12))
ctx.fillPath()
ctx.restoreGState()

// --- Latar: gradasi malam + cahaya aurora di bawah pulau ---
ctx.saveGState()
ctx.addPath(iconPath)
ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [rgb(0x262A40), rgb(0x0E1018), rgb(0x05060A)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
radialGlow(CGPoint(x: 400, y: 560), 420, 0x6C5CFF, 0.55)
radialGlow(CGPoint(x: 660, y: 520), 330, 0xFF7A45, 0.45)
radialGlow(CGPoint(x: 520, y: 330), 380, 0x2EC5FF, 0.22)
// Kilau tipis di tepi atas
let shine = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 700), options: [])
ctx.restoreGState()

// Garis tepi halus
ctx.saveGState()
ctx.addPath(iconPath)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.08))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// --- Pulau (Dynamic Island) ---
let pill = CGRect(x: 512 - 290, y: 640, width: 580, height: 164)
let pillPath = CGPath(roundedRect: pill, cornerWidth: 82, cornerHeight: 82, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 70, color: rgb(0x7A5CFF, 0.75))
ctx.addPath(pillPath)
ctx.setFillColor(rgb(0x000000))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(pillPath)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.14))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// Equalizer (kiri)
let bars: [CGFloat] = [52, 96, 70, 112, 60]
let barW: CGFloat = 18, gap: CGFloat = 13
var x = pill.minX + 72
let eq = CGGradient(colorsSpace: space, colors: [rgb(0x9AD8FF), rgb(0xFFFFFF)] as CFArray, locations: [0, 1])!
for h in bars {
    let r = CGRect(x: x, y: pill.midY - h / 2, width: barW, height: h)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(eq, start: CGPoint(x: x, y: r.minY), end: CGPoint(x: x, y: r.maxY), options: [])
    ctx.restoreGState()
    x += barW + gap
}

// Kamera (tengah) — anggukan ke notch fisik
let cam = CGPoint(x: pill.midX + 12, y: pill.midY)
ctx.setFillColor(rgb(0x14162A))
ctx.fillEllipse(in: CGRect(x: cam.x - 22, y: cam.y - 22, width: 44, height: 44))
ctx.setFillColor(rgb(0x2B3A8C, 0.9))
ctx.fillEllipse(in: CGRect(x: cam.x - 11, y: cam.y - 11, width: 22, height: 22))
ctx.setFillColor(rgb(0xFFFFFF, 0.55))
ctx.fillEllipse(in: CGRect(x: cam.x - 2, y: cam.y + 3, width: 7, height: 7))

// Ring usage (kanan): track + arc gradasi hijau → kuning → oranye
let ringC = CGPoint(x: pill.maxX - 96, y: pill.midY)
let ringR: CGFloat = 46, ringW: CGFloat = 17
ctx.setStrokeColor(rgb(0xFFFFFF, 0.14))
ctx.setLineWidth(ringW)
ctx.strokeEllipse(in: CGRect(x: ringC.x - ringR, y: ringC.y - ringR, width: ringR * 2, height: ringR * 2))
// Arc digambar per potongan kecil dengan warna yang diinterpolasi (hijau → kuning → oranye).
func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> CGColor {
    func ch(_ v: UInt32, _ s: UInt32) -> CGFloat { CGFloat(v >> s & 0xff) / 255 }
    return CGColor(srgbRed: ch(a, 16) + (ch(b, 16) - ch(a, 16)) * t, green: ch(a, 8) + (ch(b, 8) - ch(a, 8)) * t,
                   blue: ch(a, 0) + (ch(b, 0) - ch(a, 0)) * t, alpha: 1)
}
let sweep: CGFloat = 0.72 * 2 * .pi
let steps = 140
ctx.setLineWidth(ringW)
for i in 0..<steps {
    let t0 = CGFloat(i) / CGFloat(steps), t1 = CGFloat(i + 1) / CGFloat(steps)
    let seg = CGMutablePath()
    // sedikit tumpang-tindih supaya tidak ada celah antar potongan
    seg.addArc(center: ringC, radius: ringR, startAngle: .pi / 2 - sweep * t0 + 0.004,
               endAngle: .pi / 2 - sweep * t1 - 0.004, clockwise: true)
    ctx.addPath(seg)
    ctx.setLineCap(i == 0 || i == steps - 1 ? .round : .butt)
    ctx.setStrokeColor(t0 < 0.55 ? mix(0x34D74A, 0xFFD60A, t0 / 0.55) : mix(0xFFD60A, 0xFF5A1F, (t0 - 0.55) / 0.45))
    ctx.strokePath()
}

// --- Simpan ---
let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Ikon disimpan: \(out)")
