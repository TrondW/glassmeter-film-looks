//
//  ParityTests.swift
//  GlassFilmLooksTests
//
//  Checks the package against profiles/test-vectors.json, produced by the
//  independent Python reference (tools/reference/film_look.py).
//

import CoreImage
import XCTest
@testable import GlassFilmLooks

final class ParityTests: XCTestCase {

    struct Vectors: Decodable {
        struct Case: Decodable {
            let pushPullStops: Int
            let outputs: [String: [Float]]
        }
        let inputs: [Float]
        let cases: [Case]
    }

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!

    func loadVectors() throws -> Vectors {
        let url = Self.root.appendingPathComponent("profiles/test-vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func render(_ film: FilmProfile, inputs: [Float], options: FilmLookOptions, context: CIContext) -> [Float] {
        let count = inputs.count / 3
        var rgba = [Float]()
        for i in 0..<count { rgba += [inputs[i * 3], inputs[i * 3 + 1], inputs[i * 3 + 2], 1] }
        let image = CIImage(bitmapData: rgba.withUnsafeBufferPointer { Data(buffer: $0) },
                            bytesPerRow: count * 16, size: CGSize(width: count, height: 1),
                            format: .RGBAf, colorSpace: p3)
        let output = FilmLookRenderer().apply(film, to: image, options: options)
        var out = [Float](repeating: 0, count: count * 4)
        out.withUnsafeMutableBytes {
            context.render(output, toBitmap: $0.baseAddress!, rowBytes: count * 16,
                           bounds: CGRect(x: 0, y: 0, width: count, height: 1), format: .RGBAf, colorSpace: p3)
        }
        return (0..<count).flatMap { [out[$0 * 4], out[$0 * 4 + 1], out[$0 * 4 + 2]] }
    }

    func assertParity(context: CIContext, label: String) throws {
        let vectors = try loadVectors()
        let library = FilmProfileLibrary.bundled
        var worst: (error: Float, film: String) = (0, "")
        for testCase in vectors.cases {
            var options = FilmLookOptions.lookOnly
            options.pushPullStops = testCase.pushPullStops
            for (id, expected) in testCase.outputs {
                let film = try XCTUnwrap(library.film(id: id), "missing film \(id)")
                let actual = render(film, inputs: vectors.inputs, options: options, context: context)
                // The app's 8-bit output clamps; compare in 0…1
                let error = zip(actual, expected).map { abs(min(1, max(0, $0)) - min(1, max(0, $1))) }.max() ?? 0
                if error > worst.error { worst = (error, "\(id) push \(testCase.pushPullStops)") }
            }
        }
        print("[\(label)] worst error \(worst.error) at \(worst.film)")
        XCTAssertLessThan(worst.error, 0.02, "[\(label)] \(worst.film)")
    }

    /// The per-pixel function (no cube interpolation) should match almost exactly.
    func testLookFunctionMatchesReference() throws {
        let vectors = try loadVectors()
        var worst: Double = 0
        for testCase in vectors.cases {
            for (id, expected) in testCase.outputs {
                let look = FilmLookCube.Look(film: FilmProfileLibrary.bundled.film(id: id)!, pushPullStops: testCase.pushPullStops)
                for p in 0..<(vectors.inputs.count / 3) {
                    let out = look.apply(Double(vectors.inputs[p * 3]), Double(vectors.inputs[p * 3 + 1]), Double(vectors.inputs[p * 3 + 2]))
                    for (a, e) in zip([out.0, out.1, out.2], expected[(p * 3)..<(p * 3 + 3)]) {
                        worst = max(worst, abs(a - Double(e)))
                    }
                }
            }
        }
        print("[look function] worst error \(worst)")
        XCTAssertLessThan(worst, 0.001)
    }

    /// The app's own context configuration.
    func testParityInDisplayP3WorkingSpace() throws {
        let context = CIContext(options: [.workingColorSpace: p3, .workingFormat: CIFormat.RGBAf])
        try assertParity(context: context, label: "P3 working space")
    }

    /// A default (extended linear sRGB) context, as most apps use.
    func testParityInDefaultContext() throws {
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAf])
        try assertParity(context: context, label: "default context")
    }

    func testLibraryLoads() {
        let library = FilmProfileLibrary.bundled
        XCTAssertEqual(library.films.count, 31)
        XCTAssertTrue(library.film(id: "digital-neutral")!.isNeutral)
        XCTAssertFalse(library.attribution.isEmpty)
    }

    func testNeutralLUTIsIdentity() {
        let neutral = FilmProfileLibrary.bundled.film(id: "digital-neutral")!
        let size = 9
        let rgb = FilmLookLUT.sample(neutral, size: size)
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            let i = ((b * size + g) * size + r) * 3
            XCTAssertEqual(rgb[i], Float(r) / 8, accuracy: 0.002)
            XCTAssertEqual(rgb[i + 1], Float(g) / 8, accuracy: 0.002)
            XCTAssertEqual(rgb[i + 2], Float(b) / 8, accuracy: 0.002)
        }}}
    }
}
