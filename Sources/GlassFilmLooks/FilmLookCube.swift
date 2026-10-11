//
//  FilmLookCube.swift
//  GlassFilmLooks
//
//  The static film look as plain math, baked into a 3D LUT:
//
//    1. channel mixer (clamped)          ┐ GlassMeter's base cube
//    2. per-channel curves (0–255 table) │ (line-for-line port of
//    3. saturation around Rec.709 luma   ┘  FilmLUTProcessor)
//    4. print contrast around 0.5, clamped
//    5. push/pull midtone curve
//    6. characteristic curve (toe, midtone slope, shoulder)
//
//  All values are Display P3 *encoded* (sRGB transfer function), 0…1.
//  AGENT_GUIDE.md spells out every step; tools/reference/film_look.py is an
//  independent implementation used to produce profiles/test-vectors.json.
//

import Foundation

public enum FilmLookCube {

    /// GlassMeter's cube size.
    public static let dimension = 64

    /// GlassMeter's print-contrast scale: factor = 1 + 1.85 × film contrast.
    public static let printContrastScale = 1.85

    /// RGBA Float32 cube data for `CIColorCube` (red varies fastest),
    /// or nil when the look is a pure pass-through (digital-neutral, no push).
    public static func data(for film: FilmProfile, pushPullStops: Int = 0, dimension size: Int = dimension) -> Data? {
        if film.isNeutral && pushPullStops == 0 { return nil }
        let look = Look(film: film, pushPullStops: pushPullStops)
        var data = [Float](repeating: 1, count: size * size * size * 4)
        var offset = 0
        let step = Double(size - 1)
        for z in 0..<size {
            for y in 0..<size {
                for x in 0..<size {
                    let rgb = look.apply(Double(x) / step, Double(y) / step, Double(z) / step)
                    data[offset] = Float(rgb.0)
                    data[offset + 1] = Float(rgb.1)
                    data[offset + 2] = Float(rgb.2)
                    offset += 4
                }
            }
        }
        return data.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The look as a per-pixel function, for ports that don't want a LUT.
    public struct Look: Sendable {
        let neutral: Bool
        let blackAndWhite: Bool
        let mixer: [Double]?
        let red: [Double], green: [Double], blue: [Double]
        let saturation: Double
        let contrastFactor: Double
        let pushCurve: MonotoneCurve?
        let characteristic: MonotoneCurve?

        public init(film: FilmProfile, pushPullStops: Int = 0) {
            let look = film.look
            neutral = film.isNeutral
            blackAndWhite = film.process == .blackAndWhite
            mixer = look.channelMixer.flatMap { $0.count == 9 ? $0 : nil }
            let identity: [[Double]] = [[0, 0], [255, 255]]
            red = FilmLookCube.table(look.curves?.red ?? identity)
            green = FilmLookCube.table(look.curves?.green ?? identity)
            blue = FilmLookCube.table(look.curves?.blue ?? identity)
            saturation = look.saturation
            contrastFactor = 1 + FilmLookCube.printContrastScale * look.contrast
            pushCurve = FilmLookCube.pushPullCurvePoints(stops: pushPullStops).map(MonotoneCurve.init)
            characteristic = look.characteristicCurve.map { MonotoneCurve(FilmLookCube.characteristicCurvePoints($0)) }
        }

        public func apply(_ rIn: Double, _ gIn: Double, _ bIn: Double) -> (Double, Double, Double) {
            func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
            func decode(_ v: Double) -> Double { FilmLookCube.decodeSRGB(v) }
            func encode(_ v: Double) -> Double { FilmLookCube.encodeSRGB(max(0, min(1, v))) }
            var r = clamp(rIn), g = clamp(gIn), b = clamp(bIn)

            if !neutral {
                // 1. Channel mixer. B&W: the emulsion's spectral weights,
                //    summed in linear light and re-encoded. Color: crosstalk
                //    on encoded values. Clamped either way.
                if let m = mixer, blackAndWhite {
                    let y = clamp(encode(m[0] * decode(r) + m[1] * decode(g) + m[2] * decode(b)))
                    (r, g, b) = (y, y, y)
                } else if let m = mixer {
                    (r, g, b) = (clamp(r * m[0] + g * m[1] + b * m[2]),
                                 clamp(r * m[3] + g * m[4] + b * m[5]),
                                 clamp(r * m[6] + g * m[7] + b * m[8]))
                }
                // 2. Curves: truncating 0–255 index (computed in Float, as the app does)
                func index(_ v: Double) -> Int { min(max(Int(Float(v) * 255.0), 0), 255) }
                (r, g, b) = (red[index(r)], green[index(g)], blue[index(b)])

                // 3. Saturation around Rec.709 luma
                if saturation != 0 {
                    let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let s = 1 + saturation
                    (r, g, b) = (lum + (r - lum) * s, lum + (g - lum) * s, lum + (b - lum) * s)
                }

                // 4. Print contrast around 0.5, clamped
                let k = contrastFactor
                (r, g, b) = (clamp((r - 0.5) * k + 0.5), clamp((g - 0.5) * k + 0.5), clamp((b - 0.5) * k + 0.5))
            }

            // 5. Push / pull
            if let curve = pushCurve { (r, g, b) = (curve(r), curve(g), curve(b)) }

            // 6. Characteristic curve
            if let curve = characteristic { (r, g, b) = (curve(r), curve(g), curve(b)) }

            return (clamp(r), clamp(g), clamp(b))
        }
    }

    // MARK: - sRGB transfer (Display P3 uses it)

    static func decodeSRGB(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func encodeSRGB(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    // MARK: - Curves

    /// Characteristic-curve control points: toe, midtone slope, shoulder.
    public static func characteristicCurvePoints(_ curve: FilmProfile.CharacteristicCurve) -> [(Double, Double)] {
        let toe = curve.toeLift
        let ceiling = 1.0 - curve.shoulderCompression
        let lower = min(max(0.5 - 0.25 * curve.midtoneSlope, toe + 0.02), 0.45)
        let upper = max(min(0.5 + 0.28 * curve.midtoneSlope, ceiling - 0.02), 0.55)
        return [(0.0, toe), (0.25, lower), (0.5, 0.5), (0.78, upper), (1.0, ceiling)]
    }

    /// Push steepens midtones, pull flattens them; black, mid-gray and white stay put.
    public static func pushPullCurvePoints(stops: Int) -> [(Double, Double)]? {
        guard stops != 0 else { return nil }
        let s = Double(stops)
        func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
        return [(0.0, 0.0), (0.25, clamp01(0.25 - 0.03 * s)), (0.5, 0.5),
                (0.75, clamp01(0.75 + 0.025 * s)), (1.0, 1.0)]
    }

    /// 256-entry table from 0–255 control points: linear between points,
    /// flat beyond the first/last point. Values are rounded through Float,
    /// matching GlassMeter's FilmLUTProcessor.
    static func table(_ points: [[Double]]) -> [Double] {
        var table = [Double](repeating: 0, count: 256)
        let sorted = points.filter { $0.count == 2 }.sorted { $0[0] < $1[0] }
        guard let first = sorted.first, let last = sorted.last else { return table }
        for i in 0..<256 {
            let x = Double(i)
            var y: Double
            if x <= first[0] {
                y = first[1]
            } else if x >= last[0] {
                y = last[1]
            } else {
                y = last[1]
                for j in 0..<(sorted.count - 1) where x >= sorted[j][0] && x <= sorted[j + 1][0] {
                    let t = (x - sorted[j][0]) / (sorted[j + 1][0] - sorted[j][0])
                    y = sorted[j][1] + t * (sorted[j + 1][1] - sorted[j][1])
                    break
                }
            }
            table[i] = Double(Float(y / 255.0))
        }
        return table
    }
}

/// Monotone piecewise-cubic Hermite curve (PCHIP interior slopes,
/// one-sided secant slopes at the ends). Inputs outside the first/last
/// point are clamped. See AGENT_GUIDE.md for the exact formula.
public struct MonotoneCurve: Sendable {
    let xs: [Double], ys: [Double], slopes: [Double]

    public init(_ points: [(Double, Double)]) {
        let xs = points.map(\.0), ys = points.map(\.1)
        self.xs = xs
        self.ys = ys
        let n = points.count
        let h = (0..<(n - 1)).map { xs[$0 + 1] - xs[$0] }
        let delta = (0..<(n - 1)).map { (ys[$0 + 1] - ys[$0]) / h[$0] }
        var m = [Double](repeating: 0, count: n)
        m[0] = delta[0]
        m[n - 1] = delta[n - 2]
        for k in 1..<(n - 1) {
            if delta[k - 1] * delta[k] <= 0 {
                m[k] = 0
            } else {
                let w1 = 2 * h[k] + h[k - 1], w2 = h[k] + 2 * h[k - 1]
                m[k] = (w1 + w2) / (w1 / delta[k - 1] + w2 / delta[k])
            }
        }
        slopes = m
    }

    public func callAsFunction(_ xIn: Double) -> Double {
        let x = min(max(xIn, xs[0]), xs[xs.count - 1])
        var k = 0
        while k < xs.count - 2 && x > xs[k + 1] { k += 1 }
        let h = xs[k + 1] - xs[k]
        let t = (x - xs[k]) / h
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * ys[k] + (t3 - 2 * t2 + t) * h * slopes[k]
            + (-2 * t3 + 3 * t2) * ys[k + 1] + (t3 - t2) * h * slopes[k + 1]
    }
}
