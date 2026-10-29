// Films the running Magnetite and nothing else: ScreenCaptureKit with a filter that
// includes only Magnetite's windows, so whatever is open under the notch never
// reaches the file. The rest of the frame is black, like the notch itself.
//
// usage: notchrec OUT.mov SECONDS X Y W H   (points, top-left origin, built-in display)
import AVFoundation
import CoreMedia
import ScreenCaptureKit

final class Recorder: NSObject, SCStreamOutput {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    var started = false

    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422HQ,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete
        else { return }
        if !started {
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            started = true
            print("first-frame \(Date().timeIntervalSince1970)")
            fflush(stdout)
        }
        if input.isReadyForMoreMediaData { input.append(buffer) }
    }
}

let a = CommandLine.arguments
guard a.count == 7, let secs = Double(a[2]), let x = Double(a[3]), let y = Double(a[4]),
      let w = Double(a[5]), let h = Double(a[6])
else {
    FileHandle.standardError.write(Data("usage: notchrec OUT.mov SECONDS X Y W H\n".utf8))
    exit(1)
}

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }),
              let app = content.applications.first(where: { $0.bundleIdentifier == "com.laks.magnetite" })
        else { FileHandle.standardError.write(Data("no built-in display or Magnetite\n".utf8)); exit(2) }
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: x, y: y, width: w, height: h)
        config.width = Int(w * 2)
        config.height = Int(h * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false
        config.backgroundColor = .black
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 8
        let rec = try Recorder(url: URL(fileURLWithPath: a[1]), width: config.width, height: config.height)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(rec, type: .screen, sampleHandlerQueue: DispatchQueue(label: "rec"))
        try await stream.startCapture()
        try await Task.sleep(nanoseconds: UInt64(secs * 1e9))
        try await stream.stopCapture()
        rec.input.markAsFinished()
        await rec.writer.finishWriting()
        print("done \(rec.writer.status.rawValue)")
        exit(rec.writer.status == .completed ? 0 : 3)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(4)
    }
}
dispatchMain()
