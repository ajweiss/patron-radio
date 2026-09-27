import Foundation
import Testing
@testable import PatronRadioCore

/// Builds an ICY stream: `audio` split into metaint-sized runs with a metadata
/// block (or an empty one) after each run.
private func icyStream(metaInt: Int, audio: [UInt8], titles: [String?]) -> Data {
    var out = Data()
    var runs = stride(from: 0, to: audio.count, by: metaInt).map { Array(audio[$0..<min($0 + metaInt, audio.count)]) }
    while runs.count < titles.count { runs.append([]) }
    for (i, run) in runs.enumerated() {
        out.append(contentsOf: run)
        guard run.count == metaInt else { break }
        if i < titles.count, let t = titles[i] {
            var meta = Array("StreamTitle='\(t)';".utf8)
            let blocks = (meta.count + 15) / 16
            meta += Array(repeating: 0, count: blocks * 16 - meta.count)
            out.append(UInt8(blocks))
            out.append(contentsOf: meta)
        } else {
            out.append(0)
        }
    }
    return out
}

struct IcyDemuxerTests {
    @Test func passesAudioThroughWithoutMetaInt() {
        var d = IcyDemuxer(metaIntHeader: nil)
        let data = Data((0..<100).map { UInt8($0) })
        let out = d.consume(data)
        #expect(out.audio == data)
        #expect(out.titles.isEmpty)
    }

    @Test func rejectsHostileMetaIntHeaders() {
        #expect(IcyDemuxer.parseMetaInt("16000") == 16000)
        #expect(IcyDemuxer.parseMetaInt(" 8192 ") == 8192)
        #expect(IcyDemuxer.parseMetaInt("0") == nil)
        #expect(IcyDemuxer.parseMetaInt("-5") == nil)
        #expect(IcyDemuxer.parseMetaInt("banana") == nil)
        #expect(IcyDemuxer.parseMetaInt(String(IcyDemuxer.maxMetaInt + 1)) == nil)
        #expect(IcyDemuxer.parseMetaInt("99999999999999999999999") == nil)
    }

    @Test func splitsAudioAndTitles() {
        let audio = (0..<40).map { UInt8($0) }
        let stream = icyStream(metaInt: 10, audio: audio, titles: ["One", nil, "Two", "Two"])
        var d = IcyDemuxer(metaIntHeader: "10")
        let out = d.consume(stream)
        #expect(Array(out.audio) == audio)
        #expect(out.titles == ["One", "Two"]) // repeats are suppressed
    }

    @Test func survivesByteAtATimeDelivery() {
        let audio = (0..<50).map { UInt8($0 % 251) }
        let stream = icyStream(metaInt: 7, audio: audio, titles: ["Khruangbin - María También", nil, nil, "Four Tet - Baby"])
        var d = IcyDemuxer(metaIntHeader: "7")
        var audioOut = Data()
        var titles: [String] = []
        for byte in stream {
            let o = d.consume(Data([byte]))
            audioOut.append(o.audio)
            titles += o.titles
        }
        #expect(Array(audioOut) == audio)
        #expect(titles == ["Khruangbin - María También", "Four Tet - Baby"])
    }

    @Test func decodesEntitiesInTitles() {
        let stream = icyStream(metaInt: 4, audio: [1, 2, 3, 4], titles: ["Simon &amp; Garfunkel"])
        var d = IcyDemuxer(metaIntHeader: "4")
        #expect(d.consume(stream).titles == ["Simon & Garfunkel"])
    }

    @Test func fallsBackToLatin1ForNonUTF8Titles() {
        var block = Data("StreamTitle='Caf".utf8)
        block.append(0xE9) // é in Latin-1, invalid as UTF-8
        block.append(contentsOf: Array("';".utf8))
        #expect(IcyDemuxer.extractStreamTitle(block) == "Café")
    }

    @Test func ignoresMetadataWithoutStreamTitle() {
        #expect(IcyDemuxer.extractStreamTitle(Data("StreamUrl='x';".utf8)) == nil)
        #expect(IcyDemuxer.extractStreamTitle(Data("StreamTitle='unterminated".utf8)) == nil)
        #expect(IcyDemuxer.extractStreamTitle(Data("StreamTitle='';".utf8)) == "")
    }
}

/// Same cases as the widget's tests/test_icystream.cpp.
struct HTMLEntityTests {
    let decode = IcyDemuxer.decodeHTMLEntities

    @Test func namedEntities() {
        #expect(decode("Simon &amp; Garfunkel") == "Simon & Garfunkel")
        #expect(decode("&lt;3 Deluxe &gt;&gt;") == "<3 Deluxe >>")
        #expect(decode("&quot;Heroes&quot;") == "\"Heroes\"")
        #expect(decode("Guns N&apos; Roses") == "Guns N' Roses")
        #expect(decode("A&nbsp;B") == "A B")
    }

    @Test func numericEntities() {
        #expect(decode("Don&#39;t Stop") == "Don't Stop")
        #expect(decode("It&#8217;s Oh So Quiet") == "It\u{2019}s Oh So Quiet")
        #expect(decode("It&#x2019;s") == "It\u{2019}s")
        #expect(decode("Party &#128512;") == "Party 😀")
    }

    @Test func leavesLiteralsAlone() {
        #expect(decode("AC & DC") == "AC & DC")
        #expect(decode("Mumford & Sons; Live") == "Mumford & Sons; Live")
        #expect(decode("Rock &") == "Rock &")
        #expect(decode("&foo;") == "&foo;")
        #expect(decode("&#;") == "&#;")
        #expect(decode("&#x;") == "&#x;")
        #expect(decode("&# 39;") == "&# 39;")
        #expect(decode("") == "")
    }

    @Test func rejectsUnsafeCodePoints() {
        #expect(decode("&#0;") == "&#0;")
        #expect(decode("&#31;") == "&#31;")
        #expect(decode("&#x9F;") == "&#x9F;")
        #expect(decode("&#xD800;") == "&#xD800;")
        #expect(decode("&#1114112;") == "&#1114112;")
    }

    @Test func isSinglePass() {
        #expect(decode("Me &amp;amp; You") == "Me &amp; You")
    }
}

struct StreamInfoTests {
    @Test func codecFromContentType() {
        #expect(StreamInfo(contentType: "audio/mpeg", icyBr: "128", url: nil).codec == "MP3")
        #expect(StreamInfo(contentType: "audio/aacp", icyBr: nil, url: nil).codec == "AAC+")
        #expect(StreamInfo(contentType: "audio/aac", icyBr: nil, url: nil).codec == "AAC")
        #expect(StreamInfo(contentType: nil, icyBr: nil, url: URL(string: "http://x/a.mp3")).codec == "MP3")
        #expect(StreamInfo(contentType: "application/ogg", icyBr: nil, url: nil).codec == "")
    }

    @Test func bitrateHandlesListsAndJunk() {
        #expect(StreamInfo(contentType: nil, icyBr: "128,128", url: nil).bitrateKbps == 128)
        #expect(StreamInfo(contentType: nil, icyBr: " 96 ", url: nil).bitrateText == "96 kbps")
        #expect(StreamInfo(contentType: nil, icyBr: "fast", url: nil).bitrateKbps == nil)
        #expect(StreamInfo(contentType: nil, icyBr: "0", url: nil).bitrateKbps == nil)
    }
}
