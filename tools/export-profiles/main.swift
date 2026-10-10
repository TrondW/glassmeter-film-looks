// Exports GlassMeter's film registry (FilmStock.swift) to profiles/film-stocks.json.
// Compiled together with the app's own model file, so the JSON can never drift
// from what the app ships. Run via tools/export-profiles/export.sh.

import Foundation

struct Point: Encodable { let x: Double; let y: Double }

func points(_ curve: [CurvePoint]?) -> [[Double]]? {
    curve?.map { [$0.x, $0.y] }
}

func process(_ type: FilmType) -> String {
    switch type {
    case .c41: return "C-41"
    case .e6: return "E-6"
    case .bw: return "BW"
    }
}

var films: [[String: Any]] = []
for film in FilmRegistry.all {
    let isNeutral = film.id == "digital-neutral"
    var look: [String: Any] = [
        "saturation": film.saturation,
        "contrast": film.contrast,
    ]
    look["channelMixer"] = film.channelMixer ?? NSNull()
    if let r = points(film.redCurve), let g = points(film.greenCurve), let b = points(film.blueCurve) {
        look["curves"] = ["red": r, "green": g, "blue": b]
    } else {
        look["curves"] = NSNull()
    }
    if isNeutral {
        look["characteristicCurve"] = NSNull()
    } else {
        let c = film.characteristicCurve
        look["characteristicCurve"] = [
            "toeLift": c.toeLift,
            "shoulderCompression": c.shoulderCompression,
            "midtoneSlope": c.midtoneSlope,
        ]
    }

    var entry: [String: Any] = [
        "id": film.id,
        "name": film.name,
        "displayName": film.displayName,
        "manufacturer": film.manufacturer,
        "process": process(film.type),
        "iso": ["box": film.isoDefault, "min": film.isoRange.min, "max": film.isoRange.max],
        "maxPushStops": film.maxPush,
        "maxPullStops": film.maxPull,
        "discontinued": film.discontinued,
        "character": film.characterNote,
        "look": look,
        "grain": ["intensity": film.grainIntensity],
        "halation": ["factor": film.halationFactor, "alwaysOn": film.forcesHalation],
        "reciprocity": [
            "thresholdSeconds": film.reciprocity.thresholdMs / 1000.0,
            "exponent": film.reciprocity.exponent,
        ],
    ]
    entry["notes"] = film.notes ?? NSNull()
    films.append(entry)
}

let document: [String: Any] = [
    "schema": "glassmeter-film-looks/1",
    "source": "GlassMeter by Glass Works — https://glass-works.ai",
    "license": "CC-BY-4.0",
    "attribution": "Film simulations from GlassMeter by Glass Works (glass-works.ai)",
    "pipelineSpec": "AGENT_GUIDE.md",
    "films": films,
]

let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try data.write(to: out)
print("exported \(films.count) films -> \(out.path)")
