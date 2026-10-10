//
//  FilmLookLUT.swift
//  GlassFilmLooks
//
//  Bakes the static part of a film look (cube + contrast + push/pull +
//  characteristic curve + optional lens filter) into a 3D LUT by running
//  FilmLookRenderer over an identity grid. Use it for .cube export, Metal
//  shaders, or any pipeline that wants a single lookup per pixel.
//

import CoreImage
import Foundation

public enum FilmLookLUT {

    /// Samples the look on a size³ grid in `colorSpace` (encoded values in,
    /// encoded values out). Entries are RGB triplets with red varying fastest,
    /// then green, then blue — the .cube and CIColorCube order.
    public static func sample(
        _ film: FilmProfile,
        size: Int = 33,
        colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
        options: FilmLookOptions = .lookOnly,
        renderer: FilmLookRenderer = FilmLookRenderer()
    ) -> [Float] {
        var options = options
        options.grain = false
        options.halation = false

        // Identity grid: width = size (red), height = size² (green, then blue)
        let width = size, height = size * size
        var grid = [Float](repeating: 1, count: width * height * 4)
        let step = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let i = ((b * size + g) * size + r) * 4
                    grid[i] = Float(r) / step
                    grid[i + 1] = Float(g) / step
                    grid[i + 2] = Float(b) / step
                }
            }
        }
        let input = CIImage(
            bitmapData: grid.withUnsafeBufferPointer { Data(buffer: $0) },
            bytesPerRow: width * 16,
            size: CGSize(width: width, height: height),
            format: .RGBAf,
            colorSpace: colorSpace
        )

        let output = renderer.apply(film, to: input, options: options)
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(output, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf, colorSpace: colorSpace)
        }

        // CIImage(bitmapData:) rows run top-down; render(toBitmap:) also writes
        // top-down, so pixel order matches the grid. Drop alpha, clamp to 0…1.
        var rgb = [Float](repeating: 0, count: size * size * size * 3)
        for p in 0..<(width * height) {
            for c in 0..<3 {
                rgb[p * 3 + c] = min(1, max(0, pixels[p * 4 + c]))
            }
        }
        return rgb
    }

    /// A .cube file (Adobe/Resolve 3D LUT text format).
    public static func cubeFile(
        _ film: FilmProfile,
        size: Int = 33,
        colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
        options: FilmLookOptions = .lookOnly,
        title: String? = nil,
        comments: [String] = []
    ) -> String {
        let rgb = sample(film, size: size, colorSpace: colorSpace, options: options)
        var lines = comments.map { "# \($0)" }
        lines.append("TITLE \"\(title ?? film.name)\"")
        lines.append("LUT_3D_SIZE \(size)")
        lines.append("DOMAIN_MIN 0.0 0.0 0.0")
        lines.append("DOMAIN_MAX 1.0 1.0 1.0")
        lines.reserveCapacity(lines.count + size * size * size)
        for i in stride(from: 0, to: rgb.count, by: 3) {
            lines.append(String(format: "%.6f %.6f %.6f", rgb[i], rgb[i + 1], rgb[i + 2]))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
