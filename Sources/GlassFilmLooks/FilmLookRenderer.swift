//
//  FilmLookRenderer.swift
//  GlassFilmLooks
//
//  Core Image port of GlassMeter's film pipeline (FilmEffectRenderer +
//  the capture path in CameraManager). Same filters, same constants, same
//  order. See AGENT_GUIDE.md for the math written out.
//
//  GlassMeter renders in a CIContext whose working space is gamma-encoded
//  Display P3, so every film operation sees display-encoded values (0.5 is
//  the middle of the encoded range, not linear 0.5). This renderer converts
//  into that encoding first and back out at the end, so it produces the same
//  result in ANY CIContext, including the default linear one.
//
//  Order: lens filter -> clamp -> film look cube -> reciprocity drift ->
//  halation -> grain.
//
//  Not thread-safe (it caches cube data); use one instance per render queue.
//

import CoreImage
import Foundation

public struct FilmLookOptions: Sendable {
    /// Push (+) / pull (−) development in stops. Clamp to the film's
    /// maxPushStops / maxPullStops if you want to stay realistic.
    public var pushPullStops: Int = 0
    /// Film grain. Size-dependent, so it can't live in a LUT.
    public var grain: Bool = true
    /// Highlight halation (red bloom). Films with `halation.alwaysOn` halate
    /// even when this is false.
    public var halation: Bool = true
    /// Lens spread for halation, 0–1. GlassMeter takes this from the lens
    /// (0.05 very well corrected … 0.55 the "glow" lens); 0.2 is typical.
    public var halationSpread: Double = 0.2
    /// Optional long-exposure warm drift for color films, given the metered
    /// shutter time in seconds. nil = off.
    public var simulatedShutterSeconds: Double? = nil
    /// Optional lens filter (yellow/orange/red for B&W, warming, conversion).
    public var colorFilter: FilmColorFilter = .none
    /// Grain pattern offset in pixels. Change it every frame to animate grain
    /// in a live preview; keep it fixed for stills.
    public var grainOffset: CGPoint = .zero
    public init() {}

    /// Only the LUT-able part: no grain, no halation, no drift.
    public static var lookOnly: FilmLookOptions {
        var options = FilmLookOptions()
        options.grain = false
        options.halation = false
        return options
    }
}

public final class FilmLookRenderer {

    /// The space GlassMeter's film math runs in.
    public static let encodingSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    private var cubeCache: [String: Data?] = [:]

    public init() {}

    // MARK: - Public

    /// Applies the complete film simulation to an image in any working space.
    public func apply(_ film: FilmProfile, to image: CIImage, options: FilmLookOptions = FilmLookOptions()) -> CIImage {
        let extent = image.extent
        guard var working = image.matchedFromWorkingSpace(to: Self.encodingSpace) else { return image }
        working = applyEncoded(film, to: working, options: options)
        let result = working.matchedToWorkingSpace(from: Self.encodingSpace) ?? working
        return extent.isInfinite ? result : result.cropped(to: extent)
    }

    /// Same as `apply`, for an image already holding Display P3 encoded values
    /// (e.g. inside a CIContext whose working space is Display P3, like GlassMeter's).
    public func applyEncoded(_ film: FilmProfile, to input: CIImage, options: FilmLookOptions) -> CIImage {
        var image = input

        // Lens filter (pre-LUT)
        image = applyColorFilter(options.colorFilter, to: image)

        // CIColorCube is undefined outside 0...1 — clamp immediately before it
        image = image.applyingFilter("CIColorClamp")

        // 1–4. The static look in one cube: mixer, curves, saturation,
        //      print contrast, push/pull, characteristic curve
        if let cube = cubeData(for: film, pushPullStops: options.pushPullStops) {
            image = image.applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": FilmLookCube.dimension,
                "inputCubeData": cube,
            ])
        }

        // 5. Reciprocity warm drift (color films, long exposures)
        if let seconds = options.simulatedShutterSeconds {
            image = applyReciprocityDrift(film, seconds: seconds, to: image)
        }

        // 6. Halation = lens spread × film factor
        let halation = options.halationSpread * film.halation.factor
        if (options.halation || film.halation.alwaysOn) && halation > 0.01 {
            image = applyHalation(to: image, intensity: halation, monochrome: film.process == .blackAndWhite)
        }

        // 7. Grain, compounding ×1.3 per push stop
        let grain = film.grain.intensity * max(0.1, pow(1.3, Double(options.pushPullStops)))
        if options.grain && grain > 0.01 {
            image = applyGrain(to: image, intensity: grain, offset: options.grainOffset)
        }

        return image
    }

    private func cubeData(for film: FilmProfile, pushPullStops: Int) -> Data? {
        let key = "\(film.id)|\(pushPullStops)"
        if let cached = cubeCache[key] { return cached }
        let data = FilmLookCube.data(for: film, pushPullStops: pushPullStops)
        cubeCache[key] = .some(data)
        return data
    }

    // MARK: - Effects

    private func applyHalation(to input: CIImage, intensity: Double, monochrome: Bool) -> CIImage {
        // Highlights with a smooth rolloff: t = clamp((x − 0.70) / 0.25), 0.15 × smoothstep(t)
        let smooth = CIVector(x: 0, y: 0, z: 0.45, w: -0.3)
        let highlights = input
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 4, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 4, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 4, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -2.8, y: -2.8, z: -2.8, w: 0),
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
            .applyingFilter("CIColorPolynomial", parameters: [
                "inputRedCoefficients": smooth,
                "inputGreenCoefficients": smooth,
                "inputBlueCoefficients": smooth,
                "inputAlphaCoefficients": CIVector(x: 0, y: 1, z: 0, w: 0),
            ])

        // Resolution-scaled blur (reference width 1000 px)
        let radius = 15.0 * intensity * 2.0 * (Self.referenceWidth(of: input) / 1000.0)
        var bloom = highlights.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])

        // Red-orange tint for color film; neutral for B&W
        if !monochrome {
            bloom = bloom.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0.1, y: 0.2, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.05, w: 0),
            ])
        }

        // Bloom strength 0.3, screened over the image
        let strength = 0.3
        bloom = bloom.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: strength, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: strength, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: strength, w: 0),
        ])
        return bloom.cropped(to: input.extent)
            .applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: input])
    }

    private func applyGrain(to input: CIImage, intensity: Double, offset: CGPoint) -> CIImage {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return input }

        // Monochrome noise, contrast scaled around 0.5 by 0.3 × intensity
        let k = intensity * 0.3
        let bias = 0.5 * (1 - k)
        let scale = Self.referenceWidth(of: input) / 400.0
        let grain = noise
            .applyingFilter("CIColorMonochrome", parameters: [
                kCIInputColorKey: CIColor(red: 0.5, green: 0.5, blue: 0.5),
                kCIInputIntensityKey: 1.0,
            ])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
            ])
            .transformed(by: CGAffineTransform(translationX: -offset.x, y: -offset.y))
            // "Chunky" grain: upscale relative to a 400 px reference width
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: input.extent.minX, y: input.extent.minY))
            .cropped(to: input.extent)

        let grained = grain.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: input])

        // Grain peaks in midtones: mask = 0.25 + 3L − 3L² (L = Rec.709 luma)
        let luma = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        let tent = CIVector(x: 0.25, y: 3.0, z: -3.0, w: 0)
        let mask = input
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": luma, "inputGVector": luma, "inputBVector": luma,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
            .applyingFilter("CIColorPolynomial", parameters: [
                "inputRedCoefficients": tent,
                "inputGreenCoefficients": tent,
                "inputBlueCoefficients": tent,
                "inputAlphaCoefficients": CIVector(x: 0, y: 1, z: 0, w: 0),
            ])
        return grained.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: input,
            kCIInputMaskImageKey: mask,
        ])
    }

    private func applyReciprocityDrift(_ film: FilmProfile, seconds: Double, to image: CIImage) -> CIImage {
        guard film.process != .blackAndWhite, seconds > 0 else { return image }
        let corrected = film.reciprocity.correctedSeconds(for: seconds)
        guard corrected > seconds * 1.05 else { return image }
        let warmth = min(1.0, log2(corrected / seconds))
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.0 + 0.05 * warmth, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1.0 + 0.01 * warmth, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1.0 - 0.06 * warmth, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
    }

    private func applyColorFilter(_ filter: FilmColorFilter, to image: CIImage) -> CIImage {
        if filter == .polarizer {
            return image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.15])
        }
        guard let rows = filter.matrix else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: rows[0], y: rows[1], z: rows[2], w: 0),
            "inputGVector": CIVector(x: rows[3], y: rows[4], z: rows[5], w: 0),
            "inputBVector": CIVector(x: rows[6], y: rows[7], z: rows[8], w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
    }

    /// GlassMeter frames are square, so its "width" is also the short side.
    /// Using the short side keeps grain and halation size the same in portrait
    /// and landscape.
    static func referenceWidth(of image: CIImage) -> Double {
        Double(min(image.extent.width, image.extent.height))
    }
}

// MARK: - Lens Filters

/// Simulated lens filters (Wratten-derived, luminance-normalized), applied before the look.
public enum FilmColorFilter: String, CaseIterable, Sendable {
    case none, yellow, orange, red, green, warming81A, conversion85B, conversion80A, polarizer

    /// Row-major 3x3 RGB matrix, nil when the filter has no color effect.
    public var matrix: [Double]? {
        switch self {
        case .yellow:        return [1.05, 0.05, 0, 0.05, 1.0, 0, 0, 0.05, 0.13]       // Wratten #8
        case .orange:        return [1.7, 0.09, 0, 0.09, 0.77, 0, 0, 0, 0.09]          // Wratten #21
        case .red:           return [3.2, 0.16, 0, 0, 0.39, 0, 0, 0, 0.1]              // Wratten #25
        case .green:         return [0.44, 0.06, 0, 0.06, 1.11, 0.06, 0, 0.06, 0.22]   // Wratten #11
        case .warming81A:    return [1.05, 0, 0, 0, 1.0, 0, 0, 0, 0.84]
        case .conversion85B: return [1.32, 0, 0, 0, 0.95, 0, 0, 0, 0.59]
        case .conversion80A: return [0.76, 0, 0, 0, 1.03, 0, 0, 0, 1.38]
        case .none, .polarizer: return nil
        }
    }
}
