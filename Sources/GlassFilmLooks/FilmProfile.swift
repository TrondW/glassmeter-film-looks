//
//  FilmProfile.swift
//  GlassFilmLooks
//
//  Film simulations from GlassMeter by Glass Works (glass-works.ai), CC BY 4.0.
//  One FilmProfile per stock, decoded from film-stocks.json.
//

import Foundation

public struct FilmProfile: Codable, Hashable, Identifiable, Sendable {

    public enum Process: String, Codable, Sendable {
        case colorNegative = "C-41"
        case slide = "E-6"
        case blackAndWhite = "BW"
    }

    public struct ISO: Codable, Hashable, Sendable {
        public let box: Int
        public let min: Int
        public let max: Int
    }

    /// The static "look": everything a 3D LUT can hold.
    public struct Look: Codable, Hashable, Sendable {
        /// Row-major 3x3 crosstalk matrix, applied first:
        /// R' = R*m[0] + G*m[1] + B*m[2], G' = R*m[3] + ..., B' = R*m[6] + ...
        /// Color films: on encoded values. Black-and-white films (identical
        /// rows = the emulsion's spectral weights): in LINEAR light, re-encoded.
        public let channelMixer: [Double]?
        public let curves: Curves?
        /// Luminance-preserving saturation offset (0 = unchanged, -1 = monochrome).
        public let saturation: Double
        /// Print contrast strength: v -> (v - 0.5) × (1 + 1.85 × contrast) + 0.5.
        public let contrast: Double
        /// Toe / shoulder / midtone slope. nil only for the "digital-neutral" pass-through.
        public let characteristicCurve: CharacteristicCurve?
    }

    /// Per-channel curves as [x, y] pairs on a 0–255 scale, linearly interpolated.
    public struct Curves: Codable, Hashable, Sendable {
        public let red: [[Double]]
        public let green: [[Double]]
        public let blue: [[Double]]
    }

    public struct CharacteristicCurve: Codable, Hashable, Sendable {
        /// Shadow base density (0 = slide-film crush, 0.04 = Portra-gentle).
        public let toeLift: Double
        /// Highlight rolloff (0 = straight line to white, 0.10 = maximum).
        public let shoulderCompression: Double
        /// Relative midtone gamma (1 = neutral).
        public let midtoneSlope: Double
    }

    public struct Grain: Codable, Hashable, Sendable {
        public let intensity: Double
    }

    public struct Halation: Codable, Hashable, Sendable {
        /// Film's share of halation strength (CineStill 1.3, B&W 0.3, others 1.0).
        public let factor: Double
        /// CineStill (no remjet): halation even when the user turns the effect off.
        public let alwaysOn: Bool
    }

    /// Generalized Schwarzschild law: corrected = T × (t / T)^p for t ≥ T.
    public struct Reciprocity: Codable, Hashable, Sendable {
        public let thresholdSeconds: Double
        public let exponent: Double
        /// The datasheet's long-exposure color correction, if it publishes one.
        public let colorShift: ColorShift?

        /// A CC filter correction: `filter` ("R", "G", "B", "C", "M", "Y") at
        /// `density` (CC10R = 0.10) is the full correction at `atSeconds`.
        /// Unfiltered, the channels that filter absorbs come out too bright.
        public struct ColorShift: Codable, Hashable, Sendable {
            public let filter: String
            public let density: Double
            public let atSeconds: Double
        }

        /// Linear-light channel gains (luminance preserved) for an unfiltered
        /// exposure of metered `seconds`; ramps in log time from the threshold.
        public func driftGains(for seconds: Double) -> (r: Double, g: Double, b: Double)? {
            guard let shift = colorShift, seconds > thresholdSeconds,
                  shift.atSeconds > thresholdSeconds, thresholdSeconds > 0 else { return nil }
            let strength = min(1, log2(seconds / thresholdSeconds) / log2(shift.atSeconds / thresholdSeconds))
            let boost = pow(10, shift.density * strength)
            let absorbed: [String: (Bool, Bool, Bool)] = [
                "R": (false, true, true), "G": (true, false, true), "B": (true, true, false),
                "C": (true, false, false), "M": (false, true, false), "Y": (false, false, true),
            ]
            guard let a = absorbed[shift.filter] else { return nil }
            let r = a.0 ? boost : 1, g = a.1 ? boost : 1, b = a.2 ? boost : 1
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            return (r / luminance, g / luminance, b / luminance)
        }

        /// Exposure time the film actually needs for a metered time `seconds`.
        public func correctedSeconds(for seconds: Double) -> Double {
            guard seconds >= thresholdSeconds, thresholdSeconds > 0 else { return seconds }
            return thresholdSeconds * pow(seconds / thresholdSeconds, exponent)
        }
    }

    public let id: String
    public let name: String
    public let displayName: String
    public let manufacturer: String
    public let process: Process
    public let iso: ISO
    public let maxPushStops: Int
    public let maxPullStops: Int
    public let discontinued: Bool
    /// One-line shooting character, written for a film picker.
    public let character: String
    public let notes: String?
    public let look: Look
    public let grain: Grain
    public let halation: Halation
    public let reciprocity: Reciprocity

    /// "digital-neutral" is a pass-through: no LUT, no characteristic curve.
    public var isNeutral: Bool { look.characteristicCurve == nil }

    public static func == (lhs: FilmProfile, rhs: FilmProfile) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Library

public struct FilmProfileLibrary: Sendable {

    private struct Document: Decodable {
        let schema: String
        let attribution: String
        let films: [FilmProfile]
    }

    public let films: [FilmProfile]
    /// Credit line to show in your app's acknowledgements (CC BY 4.0).
    public let attribution: String

    public init(data: Data) throws {
        let document = try JSONDecoder().decode(Document.self, from: data)
        films = document.films
        attribution = document.attribution
    }

    /// The film-stocks.json bundled with this package.
    public static let bundled: FilmProfileLibrary = {
        guard let url = Bundle.module.url(forResource: "film-stocks", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let library = try? FilmProfileLibrary(data: data) else {
            fatalError("GlassFilmLooks: bundled film-stocks.json is missing or invalid")
        }
        return library
    }()

    public func film(id: String) -> FilmProfile? {
        films.first { $0.id == id }
    }
}
