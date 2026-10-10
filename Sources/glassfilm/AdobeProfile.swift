//
//  AdobeProfile.swift
//  glassfilm
//
//  Writes a Lightroom / Camera Raw "Look" profile (.xmp) holding a 3D RGB
//  table, in the DNG SDK dng_rgb_table stream format:
//
//    uint32 LE  type = 1, version = 1, dimensions = 3, divisions = N
//    N³ × 3 uint16 LE  (red outermost, then green, then blue), each stored as
//                      value − identity(index), wrapping mod 2¹⁶
//    uint32 LE  primaries, gamma, gamut;  float64 LE  minAmount, maxAmount
//
//  The stream is zlib-compressed, prefixed with its uncompressed length
//  (uint32 LE), Base85-encoded with Adobe's alphabet, and named by the MD5
//  of the uncompressed stream. Verified byte-for-byte against an
//  Adobe-generated profile.
//

import Compression
import CryptoKit
import Foundation

enum AdobeProfile {

    /// dng_rgb_table enums. Adobe RGB + gamma 2.2 is the pairing Adobe's own
    /// profiles use, so the table is sampled in Adobe RGB (1998).
    static let primariesAdobeRGB: UInt32 = 1
    static let gamma22: UInt32 = 3
    static let gamutClip: UInt32 = 0

    struct Metadata {
        let name: String
        let group: String
        let copyright: String
        let contactInfo: String
        let description: String
    }

    /// `rgb`: size³ triplets, red fastest (FilmLookLUT.sample order).
    static func xmp(rgb: [Float], size: Int, metadata: Metadata) -> String {
        let stream = tableStream(rgb: rgb, size: size)
        let digest = Insecure.MD5.hash(data: stream).map { String(format: "%02X", $0) }.joined()
        var blob = Data()
        var length = UInt32(stream.count).littleEndian
        blob.append(Data(bytes: &length, count: 4))
        blob.append(zlibCompress(stream))
        let encoded = base85(blob)
        let uuid = Insecure.MD5.hash(data: Data(("glassmeter-film-looks/" + metadata.name).utf8))
            .map { String(format: "%02X", $0) }.joined()

        return """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="GlassFilmLooks">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
           crs:PresetType="Look"
           crs:Cluster=""
           crs:UUID="\(uuid)"
           crs:SupportsAmount="True"
           crs:SupportsColor="True"
           crs:SupportsMonochrome="True"
           crs:SupportsHighDynamicRange="True"
           crs:SupportsNormalDynamicRange="True"
           crs:SupportsSceneReferred="True"
           crs:SupportsOutputReferred="True"
           crs:RequiresRGBTables="False"
           crs:ShowInPresets="True"
           crs:ShowInQuickActions="False"
           crs:CameraModelRestriction=""
           crs:Copyright="\(escape(metadata.copyright))"
           crs:ContactInfo="\(escape(metadata.contactInfo))"
           crs:Version="18.0"
           crs:ProcessVersion="15.4"
           crs:ConvertToGrayscale="False"
           crs:RGBTable="\(digest)"
           crs:Table_\(digest)="\(encoded)"
           crs:HasSettings="True">
           <crs:Name>
            <rdf:Alt>
             <rdf:li xml:lang="x-default">\(escape(metadata.name))</rdf:li>
            </rdf:Alt>
           </crs:Name>
           <crs:Group>
            <rdf:Alt>
             <rdf:li xml:lang="x-default">\(escape(metadata.group))</rdf:li>
            </rdf:Alt>
           </crs:Group>
           <crs:Description>
            <rdf:Alt>
             <rdf:li xml:lang="x-default">\(escape(metadata.description))</rdf:li>
            </rdf:Alt>
           </crs:Description>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>

        """
    }

    // MARK: - Stream

    static func tableStream(rgb: [Float], size: Int) -> Data {
        var data = Data()
        func put32(_ v: UInt32) { var le = v.littleEndian; data.append(Data(bytes: &le, count: 4)) }
        func put16(_ v: UInt16) { var le = v.littleEndian; data.append(Data(bytes: &le, count: 2)) }
        func put64(_ v: Double) { var le = v.bitPattern.littleEndian; data.append(Data(bytes: &le, count: 8)) }

        put32(1); put32(1); put32(3); put32(UInt32(size))

        let identity = (0..<size).map { UInt32(($0 * 0xFFFF + size / 2) / (size - 1)) }
        for r in 0..<size {
            for g in 0..<size {
                for b in 0..<size {
                    let i = ((b * size + g) * size + r) * 3
                    let index = [r, g, b]
                    for c in 0..<3 {
                        let value = UInt32((Double(rgb[i + c]) * 65535).rounded())
                        put16(UInt16(truncatingIfNeeded: value &- identity[index[c]]))
                    }
                }
            }
        }

        put32(primariesAdobeRGB); put32(gamma22); put32(gamutClip)
        put64(0.0); put64(2.0) // amount slider 0–200 %
        return data
    }

    // MARK: - Encoding

    /// zlib (RFC 1950): header + raw deflate + Adler-32.
    static func zlibCompress(_ input: Data) -> Data {
        let capacity = input.count + 1024
        var deflated = [UInt8](repeating: 0, count: capacity)
        let written = input.withUnsafeBytes { source in
            compression_encode_buffer(&deflated, capacity,
                                      source.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                      nil, COMPRESSION_ZLIB)
        }
        precondition(written > 0, "deflate failed")

        var a: UInt32 = 1, b: UInt32 = 0
        for byte in input { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let adler = (b << 16) | a

        var out = Data([0x78, 0x9C])
        out.append(contentsOf: deflated[0..<written])
        out.append(contentsOf: [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF),
                                UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)])
        return out
    }

    static let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?`'|()[]{}@%$#")

    /// Adobe Base85: little-endian 4-byte groups, least-significant digit first;
    /// a trailing group of k bytes is written as k + 1 digits.
    static func base85(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var out = [Character]()
        out.reserveCapacity(bytes.count * 5 / 4 + 5)
        var i = 0
        while i < bytes.count {
            let count = min(4, bytes.count - i)
            var value: UInt32 = 0
            for k in 0..<count { value |= UInt32(bytes[i + k]) << (8 * UInt32(k)) }
            let digits = count == 4 ? 5 : count + 1
            for _ in 0..<digits {
                out.append(alphabet[Int(value % 85)])
                value /= 85
            }
            i += 4
        }
        return String(out)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
