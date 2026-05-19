import Testing
import Foundation
@testable import SwiftXM

@Suite("XMMixer")
struct XMMixerTests {

    @Test("Renders silence into the provided buffer for an empty module")
    func rendersSilenceWithoutCrashing() throws {
        let data = makeEmptyModule()
        let file = try XMFile(data: data)
        let mixer = XMMixer(file: file, sampleRate: 44_100)

        let frames = 256
        var buffer = [Float](repeating: 1.0, count: frames * 2)
        buffer.withUnsafeMutableBufferPointer { ptr in
            _ = mixer.render(into: ptr.baseAddress!, frames: frames)
        }
        // No instruments, no patterns: every output frame must be
        // silence even though the input buffer was pre-filled.
        #expect(buffer.allSatisfy { $0 == 0 })
    }

    @Test("Reports finished after the order list is exhausted")
    func finishesEmptyOrderList() throws {
        let data = makeEmptyModule()
        let file = try XMFile(data: data)
        let mixer = XMMixer(file: file, sampleRate: 44_100)

        let frames = 8_192
        var buffer = [Float](repeating: 0, count: frames * 2)
        let written = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
            mixer.render(into: ptr.baseAddress!, frames: frames)
        }
        #expect(mixer.finished)
        #expect(written <= frames)
    }

    @Test("Honors the requested sample rate")
    func sampleRate() throws {
        let data = makeEmptyModule()
        let file = try XMFile(data: data)
        let mixer = XMMixer(file: file, sampleRate: 48_000)
        #expect(mixer.sampleRate == 48_000)
    }
}

/// Same minimal module the parser tests use.
private func makeEmptyModule() -> Data {
    let headerTailLen = 4 + 20 + 256
    var data = Data(repeating: 0, count: 60 + headerTailLen)
    for (i, b) in "Extended Module: ".utf8.enumerated() { data[i] = b }
    data[37] = 0x1A
    data[58] = 0x04
    data[59] = 0x01
    data[60] = UInt8(truncatingIfNeeded: headerTailLen)
    data[61] = UInt8(truncatingIfNeeded: headerTailLen >> 8)
    data[68] = 4
    data[74] = 0x01
    data[76] = 6
    data[78] = 125
    return data
}
