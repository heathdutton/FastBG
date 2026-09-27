import CoreVideo
import Foundation
import simd

/// Which screen to key. `any` takes whichever green or blue screen it finds, and holds out for a saturated one, so
/// a green wall or a plant doesn't count.
enum ScreenColor: String, Codable, Sendable, CaseIterable {
    case any, green, blue, off
}

/// The measured key: which colour the screen is and how far from it a pixel has to be to count as foreground.
struct Key: Equatable, Sendable {
    /// BT.709 chroma of the screen, centred on zero, the same convention as the composite shader.
    var cb: Float
    var cr: Float
    /// Chroma distance from the key: below `near` a pixel is screen (alpha 0), above `far` it's foreground.
    var near: Float
    var far: Float
    /// The screen's colour in gamma-encoded RGB, 0...1, taken back out of edge pixels.
    var rgb: SIMD3<Float>
    /// Which channel the despill clamps: 0 none, 1 green, 2 blue.
    var spill: UInt32
    /// Share of the pixels Vision calls background that key out.
    var coverage: Double
    /// Where the screen is behind the person. The key decides the edge there, and Vision's own edge everywhere else.
    var screen: ScreenMap?
    /// The screen's colour spot by spot, which edges are keyed and unmixed against.
    var plate: ScreenPlate?
    /// Where the person is, 0...1 across and down the frame. The screen right around them counts most.
    var center = SIMD2<Float>(0.5, 0.5)

    /// The screen fills the background, so the key alone decides and Vision can stop.
    var fillsBackground: Bool { coverage >= GreenScreen.fullCoverage }
}

/// A coarse, soft-edged map of the screen over the camera frame: 255 where it's behind the person, 0 where the room
/// is. The camera doesn't move during a call, so one measurement holds till the next calibration.
struct ScreenMap: Equatable, Sendable {
    static let width = 120, height = 68
    var values: [UInt8]

    /// Share of the frame the screen covers.
    var share: Double { Double(values.reduce(0) { $0 + Int($1) }) / Double(values.count * 255) }
}

/// The screen's own colour across the frame, coarse. Light falls off across a screen, and its dim side has weaker
/// chroma, so against one colour for the whole screen the edges there come out half keyed.
struct ScreenPlate: Equatable, Sendable {
    static let width = 32, height = 18
    var rgb: [SIMD3<Float>]

    static func cell(_ x: Int, _ y: Int, width w: Int, height h: Int) -> Int {
        (y * height / h) * width + x * width / w
    }

    /// Averages each cell's screen samples. A cell with none in view, behind the person or past the screen's
    /// edge, keeps what `previous` had there, or else takes its neighbours' colour.
    init(samples: [(cell: Int, rgb: SIMD3<Float>)], previous: ScreenPlate?, fallback: SIMD3<Float>) {
        let w = Self.width, h = Self.height
        var sum = [SIMD3<Float>](repeating: .zero, count: w * h)
        var count = [Int](repeating: 0, count: w * h)
        for s in samples {
            sum[s.cell] += s.rgb
            count[s.cell] += 1
        }
        var rgb: [SIMD3<Float>?] = (0..<(w * h)).map { count[$0] >= 4 ? sum[$0] / Float(count[$0]) : previous?.rgb[$0] }
        var missing = rgb.indices.filter { rgb[$0] == nil }
        guard missing.count < rgb.count else {
            self.rgb = Array(repeating: fallback, count: w * h)
            return
        }
        // Grows outward from the measured cells one ring at a time.
        while !missing.isEmpty {
            var next = rgb
            missing = missing.filter { i in
                let x = i % w, y = i / w
                var acc = SIMD3<Float>.zero, n: Float = 0
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)]
                where (0..<w).contains(x + dx) && (0..<h).contains(y + dy) {
                    if let v = rgb[(y + dy) * w + x + dx] {
                        acc += v
                        n += 1
                    }
                }
                guard n > 0 else { return true }
                next[i] = acc / n
                return false
            }
            rgb = next
        }
        self.rgb = rgb.map { $0 ?? fallback }
    }

    /// Eases `t` of the way to `other`, so a re-measured plate never jumps.
    func eased(to other: ScreenPlate, _ t: Float) -> ScreenPlate {
        var out = self
        for i in rgb.indices { out.rgb[i] += (other.rgb[i] - rgb[i]) * t }
        return out
    }
}

enum GreenScreen {
    static let fullCoverage = 0.97

    /// Measures the key from one frame and Vision's `.accurate` mask of it. Nil means there's no screen to key.
    ///
    /// The key is the densest cluster of saturated background chroma. The median would be the wall's whenever a
    /// pop-up screen covers less of the room than the wall does. Samples near the person count more, since their
    /// edges key against them.
    static func calibrate(frame: CVPixelBuffer, mask: CVPixelBuffer, want: ScreenColor = .any) -> Key? {
        guard want != .off else { return nil }
        guard CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(mask, .readOnly)
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        }
        guard let fBase = CVPixelBufferGetBaseAddress(frame), let mBase = CVPixelBufferGetBaseAddress(mask)
        else { return nil }
        let fw = CVPixelBufferGetWidth(frame), fh = CVPixelBufferGetHeight(frame)
        let fRow = CVPixelBufferGetBytesPerRow(frame)
        let mw = CVPixelBufferGetWidth(mask), mh = CVPixelBufferGetHeight(mask)
        let mRow = CVPixelBufferGetBytesPerRow(mask)
        let pixels = fBase.assumingMemoryBound(to: UInt8.self)
        let alpha = mBase.assumingMemoryBound(to: UInt8.self)

        var sum = SIMD2<Float>.zero, count: Float = 0
        for my in stride(from: 0, to: mh, by: 4) {
            for mx in stride(from: 0, to: mw, by: 4) where alpha[my * mRow + mx] >= 128 {
                sum += SIMD2(Float(mx) / Float(mw), Float(my) / Float(mh))
                count += 1
            }
        }
        let center = count > 0 ? sum / count : SIMD2<Float>(0.5, 0.5)

        struct Sample { var cb: Float, cr: Float, rgb: SIMD3<Float>, cell: Int, plateCell: Int, weight: Float }
        var background: [Sample] = []
        background.reserveCapacity(fw * fh / 16)
        let step = 4
        for y in stride(from: step / 2, to: fh, by: step) {
            let my = min(mh - 1, y * mh / fh)
            for x in stride(from: step / 2, to: fw, by: step) {
                guard alpha[my * mRow + min(mw - 1, x * mw / fw)] < 128 else { continue }
                let p = pixels + y * fRow + x * 4
                let rgb = SIMD3<Float>(Float(p[2]), Float(p[1]), Float(p[0])) / 255
                let cell = (y * ScreenMap.height / fh) * ScreenMap.width + x * ScreenMap.width / fw
                background.append(Sample(cb: dot(rgb, cbWeights), cr: dot(rgb, crWeights), rgb: rgb, cell: cell,
                                         plateCell: ScreenPlate.cell(x, y, width: fw, height: fh),
                                         weight: weight(x, y, fw, fh, center)))
            }
        }
        guard background.count >= 1000 else { return nil }

        // Densest cell of a 64x64 chroma histogram over the saturated samples, smoothed over its neighbours.
        let saturated = background.filter {
            $0.cb * $0.cb + $0.cr * $0.cr > minChroma * minChroma && matches($0.rgb, want)
        }
        guard !saturated.isEmpty else { return nil }
        let bins = 64
        func bin(_ v: Float) -> Int { max(0, min(bins - 1, Int((v + 0.5) * Float(bins)))) }
        var histogram = [Float](repeating: 0, count: bins * bins)
        for s in saturated { histogram[bin(s.cr) * bins + bin(s.cb)] += s.weight }
        var peak = (count: Float(0), cb: 0, cr: 0)
        for r in 1..<(bins - 1) {
            for b in 1..<(bins - 1) {
                var sum: Float = 0
                for dr in -1...1 { for db in -1...1 { sum += histogram[(r + dr) * bins + b + db] } }
                if sum > peak.count { peak = (sum, b, r) }
            }
        }
        let peakCb = (Float(peak.cb) + 0.5) / Float(bins) - 0.5
        let peakCr = (Float(peak.cr) + 0.5) / Float(bins) - 0.5

        let cluster = saturated.filter { hypot($0.cb - peakCb, $0.cr - peakCr) < clusterRadius }
        guard Double(cluster.count) >= Double(background.count) * minShare else { return nil }
        let weights = cluster.map(\.weight)
        let cb = percentile(cluster.map(\.cb), weights, 0.5), cr = percentile(cluster.map(\.cr), weights, 0.5)
        guard hypot(cb, cr) > (want == .any ? screenChroma : minChroma) else { return nil }

        // The screen's own spread sets the tolerance, so an unevenly lit screen still keys out whole.
        let spread = percentile(cluster.map { hypot($0.cb - cb, $0.cr - cr) }, weights, 0.95)
        let near = min(max(spread * 1.25, 0.04), 0.12)
        let far = near + 0.10
        var screenHits = [Int](repeating: 0, count: ScreenMap.width * ScreenMap.height)
        var roomHits = screenHits
        for s in background {
            if hypot(s.cb - cb, s.cr - cr) < (near + far) / 2 {
                screenHits[s.cell] += 1
            } else {
                roomHits[s.cell] += 1
            }
        }
        let keyed = screenHits.reduce(0, +)
        let rgb = SIMD3<Float>(percentile(cluster.map(\.rgb.x), weights, 0.5),
                               percentile(cluster.map(\.rgb.y), weights, 0.5),
                               percentile(cluster.map(\.rgb.z), weights, 0.5))
        let spill: UInt32 = rgb.y >= max(rgb.x, rgb.z) ? 1 : rgb.z >= max(rgb.x, rgb.y) ? 2 : 0
        let onScreen = background.filter { hypot($0.cb - cb, $0.cr - cr) < far }.map { ($0.plateCell, $0.rgb) }
        return Key(cb: cb, cr: cr, near: near, far: far, rgb: rgb, spill: spill,
                   coverage: Double(keyed) / Double(background.count),
                   screen: screenMap(screen: screenHits, room: roomHits),
                   plate: ScreenPlate(samples: onScreen, previous: nil, fallback: rgb), center: center)
    }

    /// The screen is seen around the person but not behind them. A screen is a flat panel, so the convex hull of
    /// where it's seen covers where it's hidden too, minus any room seen inside that hull. The edge is then softened
    /// so the switch between the key's edge and Vision's never shows as a line.
    static func screenMap(screen: [Int], room: [Int]) -> ScreenMap {
        let w = ScreenMap.width, h = ScreenMap.height
        var seen: [SIMD2<Int>] = []
        for y in 0..<h {
            for x in 0..<w where screen[y * w + x] >= 2 && screen[y * w + x] > room[y * w + x] {
                seen.append(SIMD2(x, y))
            }
        }
        let hull = convexHull(seen)
        var map = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let roomSeen = room[i] >= 2 && room[i] > screen[i]
                if !roomSeen, inside(SIMD2(x, y), hull) || screen[i] > room[i] { map[i] = 1 }
            }
        }
        for _ in 0..<2 {
            var blurred = map
            for y in 0..<h {
                for x in 0..<w {
                    var sum: Float = 0, n: Float = 0
                    for dy in -1...1 {
                        for dx in -1...1 where (0..<w).contains(x + dx) && (0..<h).contains(y + dy) {
                            sum += map[(y + dy) * w + x + dx]
                            n += 1
                        }
                    }
                    blurred[y * w + x] = sum / n
                }
            }
            map = blurred
        }
        return ScreenMap(values: map.map { UInt8(($0 * 255).rounded()) })
    }

    /// Andrew's monotone chain: the hull's corners, counterclockwise.
    static func convexHull(_ points: [SIMD2<Int>]) -> [SIMD2<Int>] {
        let p = Array(Set(points.map { [$0.x, $0.y] })).map { SIMD2($0[0], $0[1]) }
            .sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard p.count >= 3 else { return p }
        func turn(_ o: SIMD2<Int>, _ a: SIMD2<Int>, _ b: SIMD2<Int>) -> Int {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Int>] = [], upper: [SIMD2<Int>] = []
        for q in p {
            while lower.count >= 2, turn(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        for q in p.reversed() {
            while upper.count >= 2, turn(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    private static func inside(_ q: SIMD2<Int>, _ hull: [SIMD2<Int>]) -> Bool {
        guard hull.count >= 3 else { return false }
        for i in hull.indices {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            if (b.x - a.x) * (q.y - a.y) - (b.y - a.y) * (q.x - a.x) < 0 { return false }
        }
        return true
    }

    /// Re-measures the screen's colour as the light changes, from the most saturated colour where the screen is.
    /// No Vision: the map from calibration already says where the screen is, and the person in front of it isn't the
    /// dominant saturated colour there. Nil keeps the current key, when too little screen is in view to trust.
    static func rebalance(frame: CVPixelBuffer, key: Key) -> Key? {
        guard CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(frame)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let fw = CVPixelBufferGetWidth(frame), fh = CVPixelBufferGetHeight(frame)
        let row = CVPixelBufferGetBytesPerRow(frame)
        var inScreen = 0
        var saturated: [(cb: Float, cr: Float, rgb: SIMD3<Float>, cell: Int, weight: Float)] = []
        let step = 8
        for y in stride(from: step / 2, to: fh, by: step) {
            for x in stride(from: step / 2, to: fw, by: step) {
                if let map = key.screen {
                    let cell = (y * ScreenMap.height / fh) * ScreenMap.width + x * ScreenMap.width / fw
                    guard map.values[cell] > 200 else { continue }
                }
                inScreen += 1
                let p = base + y * row + x * 4
                let rgb = SIMD3<Float>(Float(p[2]), Float(p[1]), Float(p[0])) / 255
                let cb = dot(rgb, cbWeights), cr = dot(rgb, crWeights)
                if cb * cb + cr * cr > minChroma * minChroma {
                    saturated.append((cb, cr, rgb, ScreenPlate.cell(x, y, width: fw, height: fh),
                                      weight(x, y, fw, fh, key.center)))
                }
            }
        }
        guard inScreen >= 500, !saturated.isEmpty else { return nil }
        // The densest saturated chroma, searched only near the current key so a green shirt can't take over.
        let bins = 64
        func bin(_ v: Float) -> Int { max(0, min(bins - 1, Int((v + 0.5) * Float(bins)))) }
        var histogram = [Float](repeating: 0, count: bins * bins)
        for s in saturated where hypot(s.cb - key.cb, s.cr - key.cr) < 0.2 {
            histogram[bin(s.cr) * bins + bin(s.cb)] += s.weight
        }
        guard let peak = histogram.indices.max(by: { histogram[$0] < histogram[$1] }), histogram[peak] > 0 else {
            return nil
        }
        let peakCb = (Float(peak % bins) + 0.5) / Float(bins) - 0.5
        let peakCr = (Float(peak / bins) + 0.5) / Float(bins) - 0.5
        let cluster = saturated.filter { hypot($0.cb - peakCb, $0.cr - peakCr) < clusterRadius }
        // Mostly hidden behind the person, or the lights went out: not enough screen to re-measure from.
        guard cluster.count * 4 >= inScreen else { return nil }
        let weights = cluster.map(\.weight)
        let cb = percentile(cluster.map(\.cb), weights, 0.5), cr = percentile(cluster.map(\.cr), weights, 0.5)
        let spread = percentile(cluster.map { hypot($0.cb - cb, $0.cr - cr) }, weights, 0.95)
        let near = min(max(spread * 1.25, 0.04), 0.12)
        let rgb = SIMD3<Float>(percentile(cluster.map(\.rgb.x), weights, 0.5),
                               percentile(cluster.map(\.rgb.y), weights, 0.5),
                               percentile(cluster.map(\.rgb.z), weights, 0.5))
        var balanced = key
        (balanced.cb, balanced.cr, balanced.near, balanced.far, balanced.rgb) = (cb, cr, near, near + 0.10, rgb)
        let onScreen = saturated.filter { hypot($0.cb - cb, $0.cr - cr) < near + 0.10 }.map { ($0.cell, $0.rgb) }
        balanced.plate = ScreenPlate(samples: onScreen, previous: key.plate, fallback: rgb)
        return balanced
    }

    /// BT.709 Cb and Cr from gamma-encoded RGB, matching the composite shader.
    static let cbWeights = SIMD3<Float>(-0.1146, -0.3854, 0.5)
    static let crWeights = SIMD3<Float>(0.5, -0.4542, -0.0458)
    /// Below this chroma a colour reads as a neutral wall, not a screen.
    static let minChroma: Float = 0.1
    /// What `any` holds out for. Keying fabric and paint sit around 0.2 to 0.3, a green wall or a plant well under.
    static let screenChroma: Float = 0.15
    static let clusterRadius: Float = 0.1
    /// A screen smaller than this share of the background is more likely a plant or a poster.
    static let minShare = 0.08

    /// A colour of the kind asked for: green where green leads, blue where blue does.
    private static func matches(_ rgb: SIMD3<Float>, _ want: ScreenColor) -> Bool {
        switch want {
        case .green: return rgb.y >= max(rgb.x, rgb.z)
        case .blue: return rgb.z >= max(rgb.x, rgb.y)
        case .any: return rgb.y >= max(rgb.x, rgb.z) || rgb.z >= max(rgb.x, rgb.y)
        case .off: return false
        }
    }

    /// Falls off with distance from the person, to half at a quarter of the frame's height away. The far screen
    /// has far more pixels, so anything gentler lets the corners pick the shade.
    private static func weight(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ center: SIMD2<Float>) -> Float {
        let dx = (Float(x) / Float(w) - center.x) * Float(w) / Float(h), dy = Float(y) / Float(h) - center.y
        return 1 / (1 + (dx * dx + dy * dy) / 0.06)
    }

    /// The value with `p` of the total weight at or under it.
    private static func percentile(_ values: [Float], _ weights: [Float], _ p: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        let order = values.indices.sorted { values[$0] < values[$1] }
        let target = weights.reduce(0, +) * p
        var total: Float = 0
        for i in order {
            total += weights[i]
            if total >= target { return values[i] }
        }
        return values[order[order.count - 1]]
    }
}
