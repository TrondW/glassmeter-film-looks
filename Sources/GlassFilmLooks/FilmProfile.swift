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
