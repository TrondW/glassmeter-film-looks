//
//  main.swift
//  glassfilm — regenerate the published LUTs, Lightroom profiles and samples.
//
//  swift run glassfilm cubes <outdir> [--size 33] [--space srgb|p3] [--push N]
//  swift run glassfilm lightroom <outdir> [--size 32]
//  swift run glassfilm render <image> <outdir> [--width 1200] [--film id,...]
//                       [--no-grain] [--no-halation] [--push N]
//

import CoreImage
import Foundation
import GlassFilmLooks
import ImageIO
import UniformTypeIdentifiers

let library = FilmProfileLibrary.bundled
let looks = library.films.filter { !$0.isNeutral }
var args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func directory(_ path: String) -> URL {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let credit = [
    "Film simulation from GlassMeter by Glass Works — https://glass-works.ai",
    "Licensed CC BY 4.0 — credit \"GlassMeter by Glass Works\" when you use or share it.",
    "Film names are trademarks of their owners; these are original interpretations, not affiliated or endorsed.",
]

guard let command = args.first else {
    fail("usage: glassfilm cubes|lightroom|render …  (see Sources/glassfilm/main.swift)")
}
args.removeFirst()

switch command {

case "cubes":
    let size = Int(option("--size") ?? "33") ?? 33
    let space = option("--space") ?? "srgb"
    var lookOptions = FilmLookOptions.lookOnly
    lookOptions.pushPullStops = Int(option("--push") ?? "0") ?? 0
    let colorSpace = CGColorSpace(name: space == "p3" ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
    guard let path = args.first else { fail("usage: glassfilm cubes <outdir>") }
    let out = directory(path)
    for film in looks {
        let text = FilmLookLUT.cubeFile(
            film, size: size, colorSpace: colorSpace, options: lookOptions,
            title: "GlassMeter \(film.displayName)",
            comments: credit + ["Input/output: \(space == "p3" ? "Display P3" : "sRGB") encoded, normally exposed image."]
        )
        try text.write(to: out.appendingPathComponent("\(film.id).cube"), atomically: true, encoding: .utf8)
        print("cube", film.id)
    }

case "lightroom":
    let size = Int(option("--size") ?? "32") ?? 32
    guard let path = args.first else { fail("usage: glassfilm lightroom <outdir>") }
    let out = directory(path)
    let adobeRGB = CGColorSpace(name: CGColorSpace.adobeRGB1998)!
    for film in looks {
        let rgb = FilmLookLUT.sample(film, size: size, colorSpace: adobeRGB)
        let xmp = AdobeProfile.xmp(rgb: rgb, size: size, metadata: .init(
            name: "GM \(film.displayName)",
            group: "GlassMeter Film",
            copyright: "GlassMeter by Glass Works, CC BY 4.0",
            contactInfo: "https://glass-works.ai",
            description: "\(film.character). Original interpretation of \(film.name); not affiliated with or endorsed by \(film.manufacturer)."
        ))
        try xmp.write(to: out.appendingPathComponent("GM \(film.displayName).xmp"), atomically: true, encoding: .utf8)
        print("lightroom", film.id)
    }

case "render":
    let width = Double(option("--width") ?? "1200") ?? 1200
    let only = option("--film").map { Set($0.split(separator: ",").map(String.init)) }
    var options = FilmLookOptions()
    options.grain = !flag("--no-grain")
    options.halation = !flag("--no-halation")
    options.pushPullStops = Int(option("--push") ?? "0") ?? 0
    guard args.count >= 2 else { fail("usage: glassfilm render <image> <outdir>") }
    guard var source = CIImage(contentsOf: URL(fileURLWithPath: args[0]), options: [.applyOrientationProperty: true]) else {
        fail("cannot read \(args[0])")
    }
    let scale = width / source.extent.width
    if scale < 1 {
        source = source.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale])
    }
    source = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
    let out = directory(args[1])
    let context = CIContext(options: [.workingFormat: CIFormat.RGBAh])
    let renderer = FilmLookRenderer()
    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    for film in library.films where only?.contains(film.id) ?? true {
        let image = renderer.apply(film, to: source, options: options)
        let url = out.appendingPathComponent("\(film.id).jpg")
        try context.writeJPEGRepresentation(of: image, to: url, colorSpace: p3,
                                            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.88])
        print("render", film.id)
    }

default:
    fail("unknown command \(command)")
}
