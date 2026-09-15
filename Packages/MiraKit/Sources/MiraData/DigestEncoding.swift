import Foundation

/// Storage digests use fixed lowercase ASCII, independent of locale and printf formatting.
enum DigestEncoding {
    private static let digits = Array("0123456789abcdef".utf8)

    static func hexadecimal<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 15)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}
