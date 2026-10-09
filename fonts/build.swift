// Builds a tiny OTF with the status line's icons: four model families and
// Codex, each whole and at 26 fill levels that show what is left of a limit.
//
// Runs with the Swift that comes with the Command Line Tools — the same
// package /usr/bin/git needs — so it asks for nothing else to be installed:
//   swift fonts/build.swift [out.otf]
// The path operations are CoreGraphics' (macOS 14 or later); the font file is
// written here, as CFF outlines in an OpenType wrapper.
//
// Metrics follow JetBrains Mono (Ghostty's built-in face): 1000 UPM, 600
// advance, ascent 1020, descent 300. Each glyph advances one cell but is drawn
// two cells wide, overflowing into the space that follows it in the line.
//
// A model glyph is a whole tile: a rounded square with the icon's linework cut
// out of it, so the terminal background shows through as the lines. The tile
// is the glyph's bounding box, which keeps the icon centred on it however
// Ghostty scales or places the glyph in its cells.
//
// The pictures are not part of this repository. The model icons are
// Anthropic's illustrations from its model docs (Fable, Opus, Sonnet, Haiku in
// the docs' column order), the Codex mark is OpenAI's; the build downloads
// them from the URLs in `sources` into svg/ (not committed) and refuses a file
// whose SHA-256 is not the one recorded, so a picture changed at its source
// fails the build instead of drawing a different glyph.
//
// Codex is its own mark, a cloud with ">_" already cut out (even-odd fill), so
// it needs no tile. Scaled to the tile's size so it stands as tall as the
// model icons. Its SVG comes from @lobehub/icons-static-svg, pinned.
//
// Fill levels: what is left of a limit, from the bottom up, in steps of
// levelStep percent. Below the level the glyph is as above; above it the spent
// part is drawn inverted, as the outline of the tile or cloud with the icon's
// lines inside, so the icon stays readable at any level. The step is the
// screen's resolution: the tile is 28 device pixels tall on the built-in
// Retina display, one pixel is 3.6%, and a finer step would draw neighbouring
// levels alike.
//
// Code points:
//   U+E900..E904                whole glyphs: Fable, Opus, Sonnet, Haiku, Codex
//   U+E910 + 0x20*i + level/4   icon i (same order) with level% left, 0..100
//
// The family name carries a version (family below). A running Ghostty keeps a
// face it has loaded, and a config reload does not re-read the file; a new
// name makes it look the font up again. Bump it on every change to the glyphs
// and update font-codepoint-map in the Ghostty config to match. Install under
// a new file name too: a file replaced in place keeps its old family name in
// the running process, the new name is not found, and fallback draws whatever
// CJK glyph another font keeps at that private-use code point. A running cmux
// sees the new face only after a restart. install.sh does the installing.

import CoreGraphics
import CryptoKit
import Foundation

// (source SVG, kind): a tile with the icon cut out, or a mark drawn as it is.
let icons: [(name: String, kind: String)] = [
    ("head", "tile"), ("cursor", "tile"), ("bubble", "tile"), ("bird", "tile"), ("codex", "mark"),
]
let docs = "https://platform.claude.com/images/dashboard-discovery"
let sources: [String: (url: String, sha256: String)] = [
    "head":   ("\(docs)/head.svg",   "b2a60c83032039bf7733bf1e38cc2666cf8b25ca96ea90237958c496cf54e495"),
    "cursor": ("\(docs)/cursor.svg", "46531fef8f60a0be522ba2c4a8f31f4d048672428414a7b05551c35f7730e2f7"),
    "bubble": ("\(docs)/bubble.svg", "d2cea40178d51f7de0c82e0e1c56f8f7e1150339642b0592fccc727edf298c23"),
    "bird":   ("\(docs)/bird.svg",   "e2e98510a98cdd48b7517ad05013f5ddb33a0993a5209434dd606f71f0e72489"),
    "codex":  ("https://unpkg.com/@lobehub/icons-static-svg@1.95.1/icons/codex.svg",
               "d08b4e824cd6727e89617f59e4737273ff53e44c1da849d016dd64dfd08b33e1"),
]
let wholeBase = 0xE900
let levelBase = 0xE910, levelStride = 0x20, levelStep = 4
let adv = 600.0, asc = 1020.0, desc = 300.0
let family = "Statusline Icons 6"
let cx = adv, cy = (asc - desc) / 2   // centre on the boundary between the two cells
let tile = 1080.0, radius = 200.0     // rounded square, two cells wide minus a margin
let icon = tile * 24 / 40             // the SVG viewBox height inside the tile: the docs
                                      // draw it h-6 (24px) on a size-10 (40px) tile
let dilate = 50.0                     // stroke width added to the lines: at 13pt the docs'
                                      // hairlines are under a pixel and a cut-out that thin
                                      // closes up under font smoothing
let ring = 60.0                       // outline of the spent part, about 1.5 device pixels

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let out = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : here.appendingPathComponent("StatuslineIcons.otf")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - Sources

/// The SVG's text, from svg/ or downloaded into it, checked against `sources`.
func source(_ name: String) -> String {
    let (url, digest) = sources[name]!
    let path = here.appendingPathComponent("svg/\(name).svg")
    if !FileManager.default.fileExists(atPath: path.path) {
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The docs' server answers some default User-Agents with 403.
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 30)
        request.setValue("plimsoll-build", forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        var body: Data?, problem = ""
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let data, status == 200 { body = data } else { problem = error?.localizedDescription ?? "HTTP \(status)" }
            done.signal()
        }.resume()
        done.wait()
        guard let body else { fail("\(url): \(problem)") }
        try! body.write(to: path)
    }
    let data = try! Data(contentsOf: path)
    let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    if got != digest {
        fail("""
            \(path.path): SHA-256 \(got), expected \(digest).
            The picture at \(url) has changed; delete the file to fetch it again,
            and check the new glyph before recording its hash in `sources`.
            """)
    }
    return String(decoding: data, as: UTF8.self)
}

func matches(_ pattern: String, in text: String) -> [[String]] {
    let regex = try! NSRegularExpression(pattern: pattern)
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
        (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }
}

func viewBox(_ svg: String) -> CGRect {
    let v = matches(#"viewBox="([^"]+)""#, in: svg)[0][1]
        .split(whereSeparator: { $0 == " " || $0 == "," }).map { Double($0)! }
    return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
}

// MARK: - SVG path data

/// Appends SVG path data to `path`: M L H V C S Q T A Z, absolute and relative.
func parsePath(_ d: String, into path: CGMutablePath, transform t: CGAffineTransform) {
    let chars = Array(d.utf8)
    var i = 0
    func skip() { while i < chars.count, chars[i] == 32 || chars[i] == 44 || (9...13).contains(chars[i]) { i += 1 } }
    func number() -> Double {
        skip()
        let start = i
        if i < chars.count, chars[i] == 43 || chars[i] == 45 { i += 1 }
        var dot = false
        while i < chars.count {
            let c = chars[i]
            if c >= 48 && c <= 57 { i += 1 }
            else if c == 46 && !dot { dot = true; i += 1 }
            else if (c == 101 || c == 69) {
                i += 1
                if i < chars.count, chars[i] == 43 || chars[i] == 45 { i += 1 }
            } else { break }
        }
        return Double(String(decoding: chars[start..<i], as: UTF8.self))!
    }
    func flag() -> Bool { skip(); defer { i += 1 }; return chars[i] == 49 }
    func hasNumber() -> Bool {
        skip()
        guard i < chars.count else { return false }
        let c = chars[i]
        return (c >= 48 && c <= 57) || c == 45 || c == 43 || c == 46
    }

    var cur = CGPoint.zero, start = CGPoint.zero
    var lastControl: CGPoint? = nil, lastQuad: CGPoint? = nil
    var command: UInt8 = 0
    func line(_ p: CGPoint) { path.addLine(to: p, transform: t); cur = p }
    while true {
        skip()
        if i >= chars.count { break }
        if !hasNumber() { command = chars[i]; i += 1 }
        let rel = command >= 97
        let base = rel ? cur : .zero
        func pt() -> CGPoint { let x = number(), y = number(); return CGPoint(x: base.x + x, y: base.y + y) }
        var control: CGPoint? = nil, quad: CGPoint? = nil
        switch command | 0x20 {   // lowercase
        case 109: // m
            cur = pt(); start = cur
            path.move(to: cur, transform: t)
            command = rel ? 108 : 76   // further pairs are lineto
        case 108: line(pt())
        case 104: line(CGPoint(x: (rel ? cur.x : 0) + number(), y: cur.y))
        case 118: line(CGPoint(x: cur.x, y: (rel ? cur.y : 0) + number()))
        case 99:
            let c1 = pt(), c2 = pt(), p = pt()
            path.addCurve(to: p, control1: c1, control2: c2, transform: t); cur = p; control = c2
        case 115:
            let c1 = lastControl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
            let c2 = pt(), p = pt()
            path.addCurve(to: p, control1: c1, control2: c2, transform: t); cur = p; control = c2
        case 113:
            let q = pt(), p = pt()
            path.addQuadCurve(to: p, control: q, transform: t); cur = p; quad = q
        case 116:
            let q = lastQuad.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
            let p = pt()
            path.addQuadCurve(to: p, control: q, transform: t); cur = p; quad = q
        case 97:
            let rx = number(), ry = number(), rotation = number()
            let large = flag(), sweep = flag()
            let p = pt()
            arc(from: cur, to: p, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep, into: path, transform: t)
            cur = p
        case 122:
            path.closeSubpath(); cur = start
        default:
            fail("unsupported path command \(Character(UnicodeScalar(command)))")
        }
        lastControl = control; lastQuad = quad
    }
}

/// An SVG elliptical arc as cubic Béziers of at most a quarter turn each
/// (SVG 1.1, appendix F.6: endpoint to centre parameterisation).
func arc(from p0: CGPoint, to p1: CGPoint, rx rx0: Double, ry ry0: Double, rotation: Double,
         large: Bool, sweep: Bool, into path: CGMutablePath, transform t: CGAffineTransform) {
    if p0 == p1 { return }
    var rx = abs(rx0), ry = abs(ry0)
    if rx == 0 || ry == 0 { path.addLine(to: p1, transform: t); return }
    let phi = rotation * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
    let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
    let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
    let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
    if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
    let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
    var coef = (max(0, num / den)).squareRoot()
    if large == sweep { coef = -coef }
    let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
    let ccx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
    let ccy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2
    func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
        let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a
    }
    let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
    var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
    if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
    let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
    let step = delta / Double(segments)
    let k = 4.0 / 3.0 * tan(step / 4)
    func point(_ a: Double) -> CGPoint {
        CGPoint(x: ccx + rx * cos(a) * cosPhi - ry * sin(a) * sinPhi,
                y: ccy + rx * cos(a) * sinPhi + ry * sin(a) * cosPhi)
    }
    func derivative(_ a: Double) -> CGPoint {
        CGPoint(x: -rx * sin(a) * cosPhi - ry * cos(a) * sinPhi,
                y: -rx * sin(a) * sinPhi + ry * cos(a) * cosPhi)
    }
    var a = theta1
    for n in 0..<segments {
        let b = a + step
        let pa = point(a), pb = n == segments - 1 ? p1 : point(b)
        let da = derivative(a), db = derivative(b)
        path.addCurve(to: pb,
                      control1: CGPoint(x: pa.x + k * da.x, y: pa.y + k * da.y),
                      control2: CGPoint(x: pb.x - k * db.x, y: pb.y - k * db.y),
                      transform: t)
        a = b
    }
}

// MARK: - Shapes

func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> CGPath {
    CGPath(rect: CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0)), transform: nil)
}

/// Rounded square centred on (cx, cy), drawn with cubic quarter-arcs.
func tilePath() -> CGPath {
    let p = CGMutablePath()
    let h = tile / 2, r = radius, k = radius * 0.5523
    let x0 = cx - h, y0 = cy - h, x1 = cx + h, y1 = cy + h
    p.move(to: CGPoint(x: x0 + r, y: y0))
    p.addLine(to: CGPoint(x: x1 - r, y: y0))
    p.addCurve(to: CGPoint(x: x1, y: y0 + r), control1: CGPoint(x: x1 - r + k, y: y0), control2: CGPoint(x: x1, y: y0 + r - k))
    p.addLine(to: CGPoint(x: x1, y: y1 - r))
    p.addCurve(to: CGPoint(x: x1 - r, y: y1), control1: CGPoint(x: x1, y: y1 - r + k), control2: CGPoint(x: x1 - r + k, y: y1))
    p.addLine(to: CGPoint(x: x0 + r, y: y1))
    p.addCurve(to: CGPoint(x: x0, y: y1 - r), control1: CGPoint(x: x0 + r - k, y: y1), control2: CGPoint(x: x0, y: y1 - r + k))
    p.addLine(to: CGPoint(x: x0, y: y0 + r))
    p.addCurve(to: CGPoint(x: x0 + r, y: y0), control1: CGPoint(x: x0, y: y0 + r - k), control2: CGPoint(x: x0 + r - k, y: y0))
    p.closeSubpath()
    return p
}

/// SVG paths scaled so the viewBox is `height` tall, centred on (cx, cy).
/// SVG is y-down; flip.
func placed(_ data: [String], _ vb: CGRect, _ height: Double) -> CGMutablePath {
    let s = height / vb.height
    let t = CGAffineTransform(a: s, b: 0, c: 0, d: -s,
                              tx: cx - s * (vb.minX + vb.width / 2), ty: cy + s * (vb.minY + vb.height / 2))
    let p = CGMutablePath()
    for d in data { parsePath(d, into: p, transform: t) }
    return p
}

/// Each closed subpath of `path` as a path of its own.
func subpaths(_ path: CGPath) -> [CGPath] {
    var parts: [CGMutablePath] = []
    path.applyWithBlock { e in
        let p = e.pointee.points
        switch e.pointee.type {
        case .moveToPoint: let m = CGMutablePath(); m.move(to: p[0]); parts.append(m)
        case .addLineToPoint: parts.last!.addLine(to: p[0])
        case .addQuadCurveToPoint: parts.last!.addQuadCurve(to: p[1], control: p[0])
        case .addCurveToPoint: parts.last!.addCurve(to: p[2], control1: p[0], control2: p[1])
        case .closeSubpath: parts.last!.closeSubpath()
        @unknown default: break
        }
    }
    return parts
}

/// (body, lines) for a model icon: the tile, and the icon's dark linework.
/// Light fills are dropped, the tile colour shows through where they were.
/// The whole viewBox is placed, as the docs do, not the linework's bounds: the
/// dropped fills are part of the picture (cursor's sit top-left), and centring
/// the dark lines alone blew the cursor up and moved it to the middle.
func tileParts(_ name: String) -> (CGPath, CGPath) {
    let svg = source(name)
    let dark = matches(#"<path([^>]*)\sd="([^"]+)"([^>]*)>"#, in: svg)
        .filter { m in !matches(#"fill="var\(--fill-0, (black|#141413)\)""#, in: m[1] + m[3]).isEmpty }
        .map { $0[2] }
    var lines: CGPath = placed(dark, viewBox(svg), icon).normalized()
    let halo = lines.copy(strokingWithWidth: dilate, lineCap: .round, lineJoin: .round, miterLimit: 4)
    lines = lines.union(halo)
    return (tilePath(), lines.intersection(tilePath()))
}

/// (body, lines) for a mark with its lines already cut out: the outermost
/// contour is the body, every other contour a line.
func markParts(_ name: String) -> (CGPath, CGPath) {
    let svg = source(name)
    let vb = viewBox(svg)
    let data = matches(#"<path[^>]*\sd="([^"]+)""#, in: svg).map { $0[1] }
    let mark = placed(data, vb, tile * vb.height / max(vb.width, vb.height)).normalized(using: .evenOdd)
    let contours = subpaths(mark).sorted { a, b in
        a.boundingBoxOfPath.width * a.boundingBoxOfPath.height < b.boundingBoxOfPath.width * b.boundingBoxOfPath.height
    }
    let body = contours.last!.normalized()
    var lines: CGPath = CGMutablePath()
    for c in contours.dropLast() { lines = lines.union(c.normalized()) }
    return (body, lines)
}

/// The inner `ring` of a shape's edge.
func ringOf(_ body: CGPath) -> CGPath {
    body.intersection(body.copy(strokingWithWidth: 2 * ring, lineCap: .butt, lineJoin: .round, miterLimit: 4))
}

/// `left`% of the height kept whole from the bottom, the rest inverted.
func levelGlyph(_ body: CGPath, _ lines: CGPath, _ whole: CGPath, _ left: Int) -> CGPath {
    let b = body.boundingBoxOfPath
    let cut = b.minY + b.height * Double(left) / 100
    let kept = whole.intersection(rect(b.minX - 1, b.minY - 1, b.maxX + 1, cut))
    let spent = ringOf(body).union(lines).intersection(rect(b.minX - 1, cut, b.maxX + 1, b.maxY + 1))
    return kept.union(spent)
}

// MARK: - CFF charstrings

/// A Type 2 charstring: the advance width, then the outline in integer units.
func charstring(_ path: CGPath?) -> (bytes: [UInt8], bounds: (Int, Int, Int, Int)?) {
    var out: [UInt8] = []
    var widthPending = true
    var x = 0, y = 0
    // The outline as written, in integer units: its bounds are the curves'
    // extremes, which is what hmtx and the CFF FontBBox have to match, not the
    // control points.
    let written = CGMutablePath()
    func num(_ v: Int) {
        switch v {
        case -107...107: out.append(UInt8(v + 139))
        case 108...1131: let w = v - 108; out += [UInt8(w / 256 + 247), UInt8(w % 256)]
        case -1131 ... -108: let w = -v - 108; out += [UInt8(w / 256 + 251), UInt8(w % 256)]
        default: out += [28, UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        }
    }
    func width() { if widthPending { num(Int(adv)); widthPending = false } }
    func to(_ p: CGPoint) -> (Int, Int) {
        let px = Int(p.x.rounded()), py = Int(p.y.rounded())
        defer { x = px; y = py }
        return (px - x, py - y)
    }
    func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x.rounded(), y: p.y.rounded()) }
    var current = CGPoint.zero
    path?.applyWithBlock { e in
        let p = e.pointee.points
        switch e.pointee.type {
        case .moveToPoint:
            width(); let (dx, dy) = to(p[0]); num(dx); num(dy); out.append(21); current = p[0]
            written.move(to: point(p[0]))
        case .addLineToPoint:
            let (dx, dy) = to(p[0]); num(dx); num(dy); out.append(5); current = p[0]
            written.addLine(to: point(p[0]))
        case .addQuadCurveToPoint:
            let c1 = CGPoint(x: current.x + 2 / 3 * (p[0].x - current.x), y: current.y + 2 / 3 * (p[0].y - current.y))
            let c2 = CGPoint(x: p[1].x + 2 / 3 * (p[0].x - p[1].x), y: p[1].y + 2 / 3 * (p[0].y - p[1].y))
            for q in [c1, c2, p[1]] { let (dx, dy) = to(q); num(dx); num(dy) }
            out.append(8); current = p[1]
            written.addCurve(to: point(p[1]), control1: point(c1), control2: point(c2))
        case .addCurveToPoint:
            for q in [p[0], p[1], p[2]] { let (dx, dy) = to(q); num(dx); num(dy) }
            out.append(8); current = p[2]
            written.addCurve(to: point(p[2]), control1: point(p[0]), control2: point(p[1]))
        case .closeSubpath: break   // implicit in CFF
        @unknown default: break
        }
    }
    width()
    out.append(14)   // endchar
    if written.isEmpty { return (out, nil) }
    let b = written.boundingBoxOfPath
    return (out, (Int(b.minX.rounded(.down)), Int(b.minY.rounded(.down)),
                  Int(b.maxX.rounded(.up)), Int(b.maxY.rounded(.up))))
}

// MARK: - Glyphs

var glyphNames = [".notdef"]
var glyphPaths: [CGPath?] = [nil]
var cmap: [Int: Int] = [:]
for (i, ic) in icons.enumerated() {
    let (body, lines) = ic.kind == "tile" ? tileParts(ic.name) : markParts(ic.name)
    let whole = body.subtracting(lines)
    cmap[wholeBase + i] = glyphNames.count
    glyphNames.append(ic.name); glyphPaths.append(whole.normalized())
    for left in stride(from: 0, through: 100, by: levelStep) {
        cmap[levelBase + levelStride * i + left / levelStep] = glyphNames.count
        glyphNames.append("\(ic.name).\(left)")
        glyphPaths.append(levelGlyph(body, lines, whole, left).normalized())
    }
}
let glyphs = glyphPaths.map(charstring)
let n = glyphs.count

// MARK: - Binary writing

struct Bytes {
    var data: [UInt8] = []
    mutating func u8(_ v: Int) { data.append(UInt8(truncatingIfNeeded: v)) }
    mutating func u16(_ v: Int) { u8(v >> 8); u8(v) }
    mutating func i16(_ v: Int) { u16(v & 0xFFFF) }
    mutating func u32(_ v: UInt32) { u16(Int(v >> 16)); u16(Int(v & 0xFFFF)) }
    mutating func i64(_ v: Int64) { u32(UInt32(truncatingIfNeeded: v >> 32)); u32(UInt32(truncatingIfNeeded: v)) }
    mutating func tag(_ s: String) { data += Array(s.utf8) }
    mutating func bytes(_ b: [UInt8]) { data += b }
}

func cffIndex(_ items: [[UInt8]]) -> [UInt8] {
    var b = Bytes()
    b.u16(items.count)
    if items.isEmpty { return b.data }
    let total = items.reduce(0) { $0 + $1.count } + 1
    let offSize = total < 0x100 ? 1 : total < 0x10000 ? 2 : total < 0x1000000 ? 3 : 4
    b.u8(offSize)
    var offset = 1
    func put(_ v: Int) { for k in stride(from: offSize - 1, through: 0, by: -1) { b.u8(v >> (8 * k)) } }
    put(offset)
    for item in items { offset += item.count; put(offset) }
    for item in items { b.bytes(item) }
    return b.data
}

/// A DICT operand: always the 5-byte form, so sizes do not depend on values.
func dictInt(_ v: Int) -> [UInt8] {
    let u = UInt32(bitPattern: Int32(v))
    return [29, UInt8(u >> 24), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)]
}

let psName = family.replacingOccurrences(of: " ", with: "") + "-Regular"
let bounds = glyphs.compactMap(\.bounds)
let fontBox = (bounds.map(\.0).min()!, bounds.map(\.1).min()!, bounds.map(\.2).max()!, bounds.map(\.3).max()!)

func cffTable() -> [UInt8] {
    // Custom strings start at SID 391; .notdef is standard SID 0.
    var strings = [family]
    let familySID = 391
    var glyphSIDs: [Int] = []
    for name in glyphNames.dropFirst() { glyphSIDs.append(391 + strings.count); strings.append(name) }
    let header: [UInt8] = [1, 0, 4, 4]
    let nameIndex = cffIndex([Array(psName.utf8)])
    let stringIndex = cffIndex(strings.map { Array($0.utf8) })
    let globalSubrs = cffIndex([])
    var charset: [UInt8] = [0]
    for sid in glyphSIDs { charset += [UInt8(sid >> 8), UInt8(sid & 0xFF)] }
    let charStrings = cffIndex(glyphs.map(\.bytes))
    let privateDict: [UInt8] = dictInt(0) + [20] + dictInt(0) + [21]   // defaultWidthX, nominalWidthX

    func topDict(charsetAt: Int, charStringsAt: Int, privateAt: Int) -> [UInt8] {
        var d: [UInt8] = []
        d += dictInt(familySID) + [2]   // FullName
        d += dictInt(familySID) + [3]   // FamilyName
        d += dictInt(fontBox.0) + dictInt(fontBox.1) + dictInt(fontBox.2) + dictInt(fontBox.3) + [5]
        d += dictInt(charsetAt) + [15]
        d += dictInt(charStringsAt) + [17]
        d += dictInt(privateDict.count) + dictInt(privateAt) + [18]
        return d
    }
    let topSize = cffIndex([topDict(charsetAt: 0, charStringsAt: 0, privateAt: 0)]).count
    let charsetAt = header.count + nameIndex.count + topSize + stringIndex.count + globalSubrs.count
    let charStringsAt = charsetAt + charset.count
    let privateAt = charStringsAt + charStrings.count
    let top = cffIndex([topDict(charsetAt: charsetAt, charStringsAt: charStringsAt, privateAt: privateAt)])
    return header + nameIndex + top + stringIndex + globalSubrs + charset + charStrings + privateDict
}

func headTable() -> [UInt8] {
    var b = Bytes()
    b.u32(0x00010000); b.u32(0x00010000)
    b.u32(0)               // checkSumAdjustment, filled in last
    b.u32(0x5F0F3CF5)
    b.u16(3)               // baseline at y=0, lsb at x=0
    b.u16(1000)
    b.i64(3874262400); b.i64(3874262400)   // created, modified: 2026-10-08, fixed so the build is reproducible
    b.i16(fontBox.0); b.i16(fontBox.1); b.i16(fontBox.2); b.i16(fontBox.3)
    b.u16(0); b.u16(3); b.i16(2); b.i16(0); b.i16(0)
    return b.data
}

func hheaTable() -> [UInt8] {
    var b = Bytes()
    b.u32(0x00010000)
    b.i16(Int(asc)); b.i16(-Int(desc)); b.i16(0)
    b.u16(Int(adv))
    // Over glyphs with contours only: the empty .notdef has no bearings.
    b.i16(bounds.map(\.0).min()!); b.i16(bounds.map { Int(adv) - $0.2 }.min()!); b.i16(bounds.map(\.2).max()!)
    b.i16(1); b.i16(0); b.i16(0)
    for _ in 0..<4 { b.i16(0) }
    b.i16(0)
    b.u16(n)
    return b.data
}

func hmtxTable() -> [UInt8] {
    var b = Bytes()
    for g in glyphs { b.u16(Int(adv)); b.i16(g.bounds?.0 ?? 0) }
    return b.data
}

func maxpTable() -> [UInt8] { var b = Bytes(); b.u32(0x00005000); b.u16(n); return b.data }

func os2Table() -> [UInt8] {
    var b = Bytes()
    b.u16(4)
    b.i16(Int(adv))        // xAvgCharWidth
    b.u16(400); b.u16(5); b.u16(0)
    for v in [650, 600, 0, 75, 650, 600, 0, 350, 50, 300] { b.i16(v) }   // sub/superscript, strikeout
    b.i16(0)
    for _ in 0..<10 { b.u8(0) }                    // panose
    b.u32(0); b.u32(1 << 28); b.u32(0); b.u32(0)    // ulUnicodeRange2 bit 60: Private Use Area
    b.tag("NONE")
    b.u16(0x40)            // REGULAR
    b.u16(cmap.keys.min()!); b.u16(cmap.keys.max()!)
    b.i16(Int(asc)); b.i16(-Int(desc)); b.i16(0)
    b.u16(Int(asc)); b.u16(Int(desc))
    b.u32(1); b.u32(0)     // code page: Latin 1
    b.i16(550); b.i16(730)
    b.u16(0); b.u16(32); b.u16(0)
    return b.data
}

func cmapTable() -> [UInt8] {
    // Format 4: one segment per run of consecutive code points that map to
    // consecutive glyphs, each with its own delta.
    var segments: [(start: Int, end: Int, delta: Int)] = []
    for code in cmap.keys.sorted() {
        let gid = cmap[code]!
        if let last = segments.last, last.end == code - 1, cmap[last.end]! == gid - 1 {
            segments[segments.count - 1].end = code
        } else {
            segments.append((code, code, gid - code))
        }
    }
    segments.append((0xFFFF, 0xFFFF, 1))
    let segX2 = segments.count * 2
    var power = 1, log = 0
    while power * 2 <= segments.count { power *= 2; log += 1 }
    var sub = Bytes()
    sub.u16(4); sub.u16(16 + 8 * segments.count); sub.u16(0)
    sub.u16(segX2); sub.u16(2 * power); sub.u16(log); sub.u16(segX2 - 2 * power)
    for s in segments { sub.u16(s.end) }
    sub.u16(0)
    for s in segments { sub.u16(s.start) }
    for s in segments { sub.i16(s.delta) }
    for _ in segments { sub.u16(0) }
    var b = Bytes()
    b.u16(0); b.u16(2)
    let at: UInt32 = 4 + 8 * 2      // after the header and its two records
    b.u16(0); b.u16(3); b.u32(at)    // Unicode BMP
    b.u16(3); b.u16(1); b.u32(at)    // Windows Unicode BMP, same subtable
    b.bytes(sub.data)
    return b.data
}

func nameTable() -> [UInt8] {
    let names: [(Int, String)] = [
        (1, family), (2, "Regular"), (3, "\(psName);plimsoll"), (4, family),
        (5, "Version 1.000"), (6, psName),
    ]
    var records: [(platform: Int, encoding: Int, language: Int, id: Int, bytes: [UInt8])] = []
    for (id, s) in names { records.append((1, 0, 0, id, Array(s.utf8))) }   // Mac Roman: ASCII here
    for (id, s) in names {
        var u: [UInt8] = []
        for c in s.utf16 { u += [UInt8(c >> 8), UInt8(c & 0xFF)] }
        records.append((3, 1, 0x409, id, u))
    }
    var b = Bytes()
    b.u16(0); b.u16(records.count); b.u16(6 + 12 * records.count)
    var offset = 0
    for r in records {
        b.u16(r.platform); b.u16(r.encoding); b.u16(r.language); b.u16(r.id)
        b.u16(r.bytes.count); b.u16(offset); offset += r.bytes.count
    }
    for r in records { b.bytes(r.bytes) }
    return b.data
}

func postTable() -> [UInt8] {
    var b = Bytes()
    b.u32(0x00030000); b.u32(0)
    b.i16(-100); b.i16(50)
    b.u32(1)               // isFixedPitch
    for _ in 0..<4 { b.u32(0) }
    return b.data
}

func checksum(_ data: [UInt8]) -> UInt32 {
    var sum: UInt32 = 0
    var i = 0
    while i < data.count {
        var word: UInt32 = 0
        for k in 0..<4 { word = word << 8 | UInt32(i + k < data.count ? data[i + k] : 0) }
        sum = sum &+ word
        i += 4
    }
    return sum
}

let tables: [(String, [UInt8])] = [
    ("CFF ", cffTable()), ("OS/2", os2Table()), ("cmap", cmapTable()), ("head", headTable()),
    ("hhea", hheaTable()), ("hmtx", hmtxTable()), ("maxp", maxpTable()), ("name", nameTable()),
    ("post", postTable()),
].sorted { $0.0 < $1.0 }

var font = Bytes()
font.tag("OTTO")
font.u16(tables.count)
var power = 1, log = 0
while power * 2 <= tables.count { power *= 2; log += 1 }
font.u16(16 * power); font.u16(log); font.u16(16 * tables.count - 16 * power)
var offset = 12 + 16 * tables.count
var headAt = 0
for (tag, data) in tables {
    font.tag(tag); font.u32(checksum(data)); font.u32(UInt32(offset)); font.u32(UInt32(data.count))
    if tag == "head" { headAt = offset }
    offset += (data.count + 3) & ~3
}
for (_, data) in tables {
    font.bytes(data)
    while font.data.count % 4 != 0 { font.u8(0) }
}
let adjustment = UInt32(0xB1B0AFBA) &- checksum(font.data)
for k in 0..<4 { font.data[headAt + 8 + k] = UInt8((adjustment >> (8 * (3 - UInt32(k)))) & 0xFF) }

try! Data(font.data).write(to: out)
print("wrote \(out.path) \(n - 1) glyphs, last code point 0x\(String(cmap.keys.max()!, radix: 16))")
