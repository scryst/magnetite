// Dumps band goldens from the REAL analyser.
//
//   bandsprobe FIXTURE.f32 > golden/bands-NAME.txt
//
// Compiled by refresh-golden.sh together with Sources/NotchApp/Audio/
// AudioTap.swift — the shipping ring buffer, window, FFT, partition and meter,
// not a restatement of them. The fixture is raw mono float32; it is fed in
// 512-frame chunks, the buffer size the default output device actually hands
// the IOProc, and the published bands are printed after every chunk. The first
// chunk precedes a full analysis block, so its line records the pre-publish
// zeros — that gating is part of the behavior the port must reproduce.
import AudioToolbox
import Foundation

@main
struct Main {
    static func main() {
        guard CommandLine.arguments.count >= 2,
              let data = FileManager.default.contents(atPath: CommandLine.arguments[1])
        else {
            FileHandle.standardError.write(Data("usage: bandsprobe FIXTURE.f32\n".utf8))
            exit(1)
        }
        var samples = [Float](repeating: 0, count: data.count / 4)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }

        let tap = AudioTap()
        let chunk = 512
        var out = [Float](repeating: 0, count: AudioTap.bandCount)
        var index = 0
        var offset = 0
        while offset < samples.count {
            let frames = min(chunk, samples.count - offset)
            samples.withUnsafeMutableBufferPointer { buf in
                var abl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                        mData: UnsafeMutableRawPointer(buf.baseAddress! + offset)))
                withUnsafePointer(to: &abl) { tap.consume($0) }
            }
            tap.levels(into: &out)
            print("\(index) " + out.map { String(format: "%.8e", $0) }.joined(separator: " "))
            index += 1
            offset += frames
        }
    }
}
