import Testing
import Foundation
import SwiftXM

// Mirrors the README "Quick start" snippet so it is compile-checked.
private func renderFirstSecond(of url: URL) throws -> [Float] {
    let file = try XMFile(data: Data(contentsOf: url))
    print(file.moduleName, file.channelCount, file.instruments.count)

    let mixer = try XMMixer(file: file, sampleRate: 44_100)
    var buffer = [Float](repeating: 0, count: 44_100 * 2)   // interleaved L R
    let frames = buffer.withUnsafeMutableBufferPointer {
        mixer.render(into: $0.baseAddress!, frames: 44_100)
    }
    if mixer.finished {
        // The song ended (or looped back) inside this buffer.
    }
    return Array(buffer.prefix(frames * 2))
}

@Suite("README quick start")
struct QuickStartTests {
    @Test("The README snippet compiles and renders")
    func quickStart() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftxm-quickstart-\(UUID().uuidString).xm")
        try richFixture().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try renderFirstSecond(of: url)
        #expect(!samples.isEmpty)
    }
}

#if canImport(AVFoundation) && !os(watchOS)
import AVFoundation

// Mirrors the README "AVAudioEngine bridge" snippet (compile check only).
final class XMPlayer {
    private let engine: AVAudioEngine
    private let sourceNode: AVAudioSourceNode

    init(file: XMFile) throws {
        let engine = AVAudioEngine()
        self.engine = engine
        let sampleRate = engine.outputNode.inputFormat(forBus: 0).sampleRate
        let mixer = try XMMixer(file: file, sampleRate: sampleRate)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: 2, interleaved: true)!
        sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let raw = buffers[0].mData else { return noErr }
            mixer.render(into: raw.assumingMemoryBound(to: Float.self), frames: Int(frameCount))
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
    }

    func start() throws { try engine.start() }
    func stop() { engine.stop() }
}
#endif
