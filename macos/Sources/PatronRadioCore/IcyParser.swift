import Foundation

/// Splits a Shoutcast/Icecast byte stream into audio and in-band metadata.
///
/// Port of the Plasma widget's IcyStreamReader::processData(): every
/// `icy-metaint` bytes of audio, the server inserts one length byte (×16) and
/// that many bytes of `StreamTitle='...';` metadata. Pure value type, so it is
/// unit-tested without any networking.
public struct IcyDemuxer: Sendable {
    /// Sane upper bound for icy-metaint (real values are a few KB); hostile
    /// headers beyond this are treated as "no metadata".
    public static let maxMetaInt = 1024 * 1024

    public struct Output: Equatable, Sendable {
        public var audio = Data()
        /// Titles in arrival order, already de-duplicated against the previous title.
        public var titles: [String] = []
    }

    private enum State: Sendable { case audio, metaLength, metaData }

    public let metaInt: Int?       // nil = stream carries no metadata
    private var state: State = .audio
    private var audioBytesRead = 0
    private var metaBytesLeft = 0
    private var metaBuffer = Data()
    public private(set) var lastTitle: String?

    public init(metaIntHeader: String?) {
        metaInt = IcyDemuxer.parseMetaInt(metaIntHeader)
    }

    public static func parseMetaInt(_ header: String?) -> Int? {
        guard let h = header?.trimmingCharacters(in: .whitespaces), let v = Int(h),
              v > 0, v <= maxMetaInt else { return nil }
        return v
    }

    public mutating func consume(_ data: Data) -> Output {
        var out = Output()
        guard let metaInt else {
            out.audio = data
            return out
        }
        out.audio.reserveCapacity(data.count)
        var i = data.startIndex
        while i < data.endIndex {
            switch state {
            case .audio:
                let n = min(metaInt - audioBytesRead, data.endIndex - i)
                out.audio.append(data[i..<(i + n)])
                audioBytesRead += n
                i += n
                if audioBytesRead == metaInt {
                    state = .metaLength
                    audioBytesRead = 0
                }
            case .metaLength:
                metaBytesLeft = Int(data[i]) * 16
                i += 1
                if metaBytesLeft > 0 {
                    state = .metaData
                    metaBuffer.removeAll(keepingCapacity: true)
                } else {
                    state = .audio
                }
            case .metaData:
                let n = min(metaBytesLeft, data.endIndex - i)
                metaBuffer.append(data[i..<(i + n)])
                metaBytesLeft -= n
                i += n
                if metaBytesLeft == 0 {
                    if let title = IcyDemuxer.extractStreamTitle(metaBuffer), title != lastTitle {
                        lastTitle = title
                        out.titles.append(title)
                    }
                    state = .audio
                }
            }
        }
        return out
    }

    /// Pulls the `StreamTitle='...';` value out of one metadata block.
    public static func extractStreamTitle(_ block: Data) -> String? {
        // Most servers send UTF-8; some older playout systems send Latin-1.
        let text = String(data: block, encoding: .utf8)
            ?? String(data: block, encoding: .isoLatin1)
            ?? String(decoding: block, as: UTF8.self)
        guard let start = text.range(of: "StreamTitle='") else { return nil }
        guard let end = text.range(of: "';", range: start.upperBound..<text.endIndex) else { return nil }
        let raw = String(text[start.upperBound..<end.lowerBound])
        return decodeHTMLEntities(raw)
    }

    // MARK: - HTML entities

    /// Station playout chains often HTML-escape titles, so "Simon & Garfunkel"
    /// arrives as "Simon &amp; Garfunkel". Decodes the handful of named entities
    /// escapers actually emit plus numeric references; anything unrecognized is
    /// left untouched. Deliberately not an HTML parser (untrusted input). Single pass.
    public static func decodeHTMLEntities(_ text: String) -> String {
        // Longest sequence decoded is "&#x10FFFF;"; a '&' with no ';' within that
        // window is a literal ampersand.
        let maxEntityLen = 10
        let chars = Array(text.utf16)
        var out = [UInt16]()
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            if chars[i] == 0x26 /* & */ {
                var semi = -1
                var j = i + 1
                while j < chars.count && j - i <= maxEntityLen {
                    if chars[j] == 0x3B /* ; */ { semi = j; break }
                    j += 1
                }
                if semi != -1, let decoded = decodeEntityBody(Array(chars[(i + 1)..<semi])) {
                    out.append(contentsOf: decoded)
                    i = semi + 1
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return String(decoding: out, as: UTF16.self)
    }

    private static func decodeEntityBody(_ body: [UInt16]) -> [UInt16]? {
        let s = String(decoding: body, as: UTF16.self)
        if !s.hasPrefix("#") {
            // nbsp becomes a plain space so it can't skew menu bar text widths.
            let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
            return named[s].map { Array($0.utf16) }
        }
        let isHex = s.count >= 2 && (s.dropFirst().first == "x" || s.dropFirst().first == "X")
        let digits = s.dropFirst(isHex ? 2 : 1)
        guard !digits.isEmpty else { return nil }
        // ASCII digits only — no whitespace, signs or other numeral systems.
        let ok = digits.unicodeScalars.allSatisfy { c in
            ("0"..."9").contains(c) || (isHex && (("a"..."f").contains(c) || ("A"..."F").contains(c)))
        }
        guard ok, digits.count <= 8, let cp = UInt32(digits, radix: isHex ? 16 : 10) else { return nil }
        // Printable Unicode only: no C0/C1 controls, no surrogates, nothing past U+10FFFF.
        if cp < 0x20 || cp == 0x7F || (0x80...0x9F).contains(cp) || (0xD800...0xDFFF).contains(cp) || cp > 0x10FFFF {
            return nil
        }
        guard let scalar = Unicode.Scalar(cp) else { return nil }
        return Array(String(Character(scalar)).utf16)
    }
}

/// What the stream's HTTP headers tell us about the audio.
public struct StreamInfo: Equatable, Sendable {
    public var codec: String      // "MP3", "AAC", ... ("" if unknown)
    public var bitrateKbps: Int?  // from icy-br

    public init(contentType: String?, icyBr: String?, url: URL?) {
        let ct = (contentType ?? "").lowercased()
        let ext = url?.pathExtension.lowercased() ?? ""
        if ct.contains("mpeg") || ct.contains("mp3") || (ct.isEmpty && ext == "mp3") {
            codec = "MP3"
        } else if ct.contains("aacp") || ct.contains("aac") || (ct.isEmpty && ext == "aac") {
            codec = ct.contains("aacp") ? "AAC+" : "AAC"
        } else {
            codec = ""
        }
        // icy-br is kbps, occasionally a comma list ("128,128").
        let br = icyBr?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        bitrateKbps = br.flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
    }

    public var bitrateText: String { bitrateKbps.map { "\($0) kbps" } ?? "" }
}
