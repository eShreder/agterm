import Testing
@testable import agtermCore

@Suite struct RelayProtocolTests {
    @Test func dataRoundTrips() {
        let wire = RelayCodec.encode(.data([0x1b, 0x5b, 0x41]))
        var dec = RelayCodec.Decoder()
        #expect(dec.feed(wire) == [.data([0x1b, 0x5b, 0x41])])
    }

    @Test func resizeRoundTrips() {
        let wire = RelayCodec.encode(.resize(cols: 120, rows: 40))
        var dec = RelayCodec.Decoder()
        #expect(dec.feed(wire) == [.resize(cols: 120, rows: 40)])
    }

    @Test func decodesAcrossChunkBoundaries() {
        let wire = RelayCodec.encode(.data([1, 2, 3, 4, 5]))
        var dec = RelayCodec.Decoder()
        #expect(dec.feed(Array(wire[..<3])).isEmpty)          // header split
        #expect(dec.feed(Array(wire[3...])) == [.data([1, 2, 3, 4, 5])])
    }

    @Test func decodesMultipleFramesInOneChunk() {
        var wire = RelayCodec.encode(.data([9]))
        wire += RelayCodec.encode(.resize(cols: 80, rows: 24))
        var dec = RelayCodec.Decoder()
        #expect(dec.feed(wire) == [.data([9]), .resize(cols: 80, rows: 24)])
    }

    @Test func emptyDataFrameIsValid() {
        let wire = RelayCodec.encode(.data([]))
        var dec = RelayCodec.Decoder()
        #expect(dec.feed(wire) == [.data([])])
    }

    @Test func maxGridResizeRoundTrips() {
        let wire = RelayCodec.encode(.resize(cols: 65535, rows: 65535))
        var dec = RelayCodec.Decoder()
        #expect(dec.feed(wire) == [.resize(cols: 65535, rows: 65535)])
    }

    @Test func partialResizePayloadWaitsForRest() {
        let wire = RelayCodec.encode(.resize(cols: 100, rows: 30))
        var dec = RelayCodec.Decoder()
        #expect(dec.feed(Array(wire[..<6])).isEmpty)          // header + 1 payload byte
        #expect(dec.feed(Array(wire[6...])) == [.resize(cols: 100, rows: 30)])
    }

    // An unknown type byte means stream corruption (app + child ship in lockstep from one bundle):
    // the frame is DROPPED — never folded into `.data`, which would write the garbage into the
    // terminal — and decoding continues at the next frame. Raw wire = [type:2][len:UInt32 BE = 1][0x41].
    @Test func unknownTypeIsDropped() {
        var dec = RelayCodec.Decoder()
        let wire: [UInt8] = [2, 0, 0, 0, 1, 0x41] + RelayCodec.encode(.data([7]))
        #expect(dec.feed(wire) == [.data([7])])
    }

    // A resize-type frame whose payload isn't exactly 4 bytes is likewise corruption: dropped (consumed,
    // not surfaced), with the following well-formed frame still decoding.
    @Test func malformedResizeIsDropped() {
        var dec = RelayCodec.Decoder()
        let wire: [UInt8] = [1, 0, 0, 0, 2, 0x00, 0x50] + RelayCodec.encode(.resize(cols: 80, rows: 24))
        #expect(dec.feed(wire) == [.resize(cols: 80, rows: 24)])
    }

    @Test func byteAtATimeStillDecodes() {
        var wire = RelayCodec.encode(.data([0xde, 0xad]))
        wire += RelayCodec.encode(.resize(cols: 10, rows: 20))
        var dec = RelayCodec.Decoder()
        var frames: [RelayFrame] = []
        for byte in wire { frames += dec.feed([byte]) }
        #expect(frames == [.data([0xde, 0xad]), .resize(cols: 10, rows: 20)])
    }
}
