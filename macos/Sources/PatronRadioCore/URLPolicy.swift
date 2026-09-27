import Foundation

/// Guards for URLs that come from untrusted places: user-edited station lists
/// and the community-editable radio-browser.info directory (the "Fix" tool).
public enum URLPolicy {
    /// True for http(s) URLs only — anything else is never fetched or opened.
    public static func isWebURL(_ string: String) -> Bool {
        guard let u = URL(string: string), let scheme = u.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && !(u.host ?? "").isEmpty
    }

    /// Mirrors IcyStreamReader::isDisallowedUrl: reject non-http(s) schemes and
    /// literal IPs that aren't globally routable (loopback, private, link-local,
    /// ULA, multicast...) to limit SSRF from untrusted stream URLs. Hostnames that
    /// resolve to such addresses aren't caught (that needs DNS); this covers the
    /// direct case.
    public static func isDisallowedStreamURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return true }
        guard var host = url.host, !host.isEmpty else { return true }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let v4 = parseIPv4(host) { return !isGlobalIPv4(v4) }
        if let v6 = parseIPv6(host) { return !isGlobalIPv6(v6) }
        return false
    }

    static func parseIPv4(_ s: String) -> [UInt8]? {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: addr.s_addr) { Array($0) }
    }

    static func parseIPv6(_ s: String) -> [UInt8]? {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, s, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Array($0) }
    }

    static func isGlobalIPv4(_ b: [UInt8]) -> Bool {
        switch (b[0], b[1], b[2]) {
        case (0, _, _), (10, _, _), (127, _, _): return false
        case (100, 64...127, _): return false          // CGNAT
        case (169, 254, _): return false               // link-local
        case (172, 16...31, _): return false
        case (192, 168, _): return false
        case (192, 0, 0), (192, 0, 2): return false    // IETF / TEST-NET-1
        case (198, 18...19, _): return false           // benchmarking
        case (198, 51, 100), (203, 0, 113): return false
        case (224...255, _, _): return false           // multicast, reserved, broadcast
        default: return true
        }
    }

    static func isGlobalIPv6(_ b: [UInt8]) -> Bool {
        if b.allSatisfy({ $0 == 0 }) { return false }                                  // ::
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return false }            // ::1
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {        // ::ffff:a.b.c.d
            return isGlobalIPv4(Array(b[12..<16]))
        }
        if b[0] & 0xfe == 0xfc { return false }                                          // fc00::/7 ULA
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return false }                          // fe80::/10
        if b[0] == 0xff { return false }                                                 // multicast
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8 { return false } // documentation
        return true
    }

    /// Append `source=patron_radio` like the widget does for donate/playlist links.
    public static func taggedOutboundURL(_ string: String) -> String {
        string + (string.contains("?") ? "&" : "?") + "source=patron_radio"
    }
}
