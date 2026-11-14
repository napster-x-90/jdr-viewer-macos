import AVFoundation
import Foundation

final class PreparedRecording {
    let folder: URL
    let movies: [URL?]
    let start: Date
    let duration: Double
    let audio: URL?
    var hasAudio: Bool { audio != nil }

    init(folder: URL, movies: [URL?], start: Date, duration: Double, audio: URL?) {
        self.folder = folder
        self.movies = movies
        self.start = start
        self.duration = duration
        self.audio = audio
    }

    deinit { try? FileManager.default.removeItem(at: folder) }
}

enum Movies {
    static func prepare(_ recording: Recording, includeAudio: Bool = true) throws -> PreparedRecording {
        let segment = try JDR.read(recording)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("JDRViewer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            var urls: [URL?] = [nil, nil]
            var duration = 0.0
            for channel in segment.frames.indices where !segment.frames[channel].isEmpty {
                try Task.checkCancellation()
                let output = folder.appendingPathComponent("channel-\(channel).mov")
                duration = max(duration, try write(segment, channel, output))
                urls[channel] = output
            }
            let audioURL = folder.appendingPathComponent("audio.wav")
            let hasAudio = includeAudio && (try? writeAudio(segment, duration: duration, to: audioURL)) == true
            try Task.checkCancellation()
            return PreparedRecording(folder: folder, movies: urls, start: segment.start,
                                     duration: duration, audio: hasAudio ? audioURL : nil)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private static func write(_ segment: Segment, _ channel: Int, _ url: URL) throws -> Double {
        let frames = segment.frames[channel]
        let first = frames[0]
        let nals = units(segment.data, first)
        guard let sps = nals.first(where: { segment.data[$0.lowerBound] & 31 == 7 }),
              let pps = nals.first(where: { segment.data[$0.lowerBound] & 31 == 8 }) else {
            throw ViewerError("H.264 영상의 시작 정보를 찾을 수 없습니다.")
        }
        var videoFormat: CMFormatDescription?
        let status = segment.data.withUnsafeBytes { raw -> OSStatus in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: 2,
                parameterSetPointers: [base + sps.lowerBound, base + pps.lowerBound],
                parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4,
                formatDescriptionOut: &videoFormat)
        }
        guard status == noErr, let videoFormat else { throw ViewerError("지원하지 않는 H.264 영상입니다.") }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        guard writer.canAdd(videoInput) else { throw ViewerError("영상 트랙을 준비할 수 없습니다.") }
        writer.add(videoInput)

        guard writer.startWriting() else { throw writer.error ?? ViewerError("재생 파일을 만들 수 없습니다.") }
        writer.startSession(atSourceTime: .zero)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        var videoTimes: [Int64] = []
        for frame in frames {
            let position = Int64((frame.date.timeIntervalSince(segment.start) * 1000).rounded())
            let minimum = videoTimes.last.map { $0 + 1 } ?? 0
            videoTimes.append(max(position, minimum))
        }
        let videoEnd = videoTimes.last! + Int64(max(1, 1000 / frames.last!.fps))
        for v in frames.indices {
            try Task.checkCancellation()
            let frame = frames[v]
            var data = Data()
            for nal in units(segment.data, frame) {
                let type = segment.data[nal.lowerBound] & 31
                if type == 7 || type == 8 || type == 9 { continue }
                var size = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
                data.append(segment.data.subdata(in: nal))
            }
            let next = v + 1 < videoTimes.count ? videoTimes[v + 1] : videoEnd
            let sample = try buffer(data, format: videoFormat, time: CMTime(value: videoTimes[v], timescale: 1000),
                                    duration: CMTime(value: next - videoTimes[v], timescale: 1000), count: 1)
            if !frame.key, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
                let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            try append(sample, to: videoInput, writer: writer)
        }
        videoInput.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        while done.wait(timeout: .now() + 0.1) == .timedOut {
            try Task.checkCancellation()
        }
        guard writer.status == .completed else { throw writer.error ?? ViewerError("재생 파일을 저장할 수 없습니다.") }
        return Double(videoEnd) / 1000
    }

    private static func writeAudio(_ segment: Segment, duration: Double, to url: URL) throws -> Bool {
        guard segment.sampleRate == 8000, segment.bits == 16, !segment.audio.isEmpty else { return false }
        let sampleCount = Int((duration * 8000).rounded(.up))
        guard sampleCount > 0, sampleCount <= 28_800_000 else { return false }
        var pcm = Data(count: sampleCount * 2)
        var next = 0
        for frame in segment.audio where frame.length.isMultiple(of: 2) {
            try Task.checkCancellation()
            let timestamp = max(0, Int((frame.date.timeIntervalSince(segment.start) * 8000).rounded()))
            let start = next == 0 || timestamp > next + 800 ? timestamp : next
            guard start < sampleCount else { break }
            let bytes = min(frame.length, (sampleCount - start) * 2)
            pcm.replaceSubrange(start * 2..<(start * 2 + bytes),
                                with: segment.data[frame.offset..<(frame.offset + bytes)])
            next = start + bytes / 2
        }
        guard next > 0 else { return false }
        var wave = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { wave.append(contentsOf: $0) }
        }
        append(UInt32(36 + pcm.count))
        wave.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(8000))
        append(UInt32(16000))
        append(UInt16(2))
        append(UInt16(16))
        wave.append(contentsOf: "data".utf8)
        append(UInt32(pcm.count))
        wave.append(pcm)
        try wave.write(to: url, options: .atomic)
        return true
    }

    private static func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput, writer: AVAssetWriter) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing, ProcessInfo.processInfo.systemUptime < deadline else {
                throw writer.error ?? ViewerError("영상 준비 시간이 초과되었습니다.")
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        guard input.append(sample) else { throw writer.error ?? ViewerError("프레임을 처리할 수 없습니다.") }
    }

    private static func buffer(_ data: Data, format: CMFormatDescription, time: CMTime,
                               duration: CMTime, count: Int) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        guard !data.isEmpty, count > 0,
              CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &block) == noErr, let block else { throw ViewerError("프레임을 읽을 수 없습니다.") }
        let status = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: data.count)
        }
        guard status == noErr else { throw ViewerError("프레임을 복사할 수 없습니다.") }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var size = data.count / count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
            let sample else { throw ViewerError("재생 샘플을 만들 수 없습니다.") }
        return sample
    }

    private static func units(_ data: Data, _ frame: Frame) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        let end = frame.offset + frame.length
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = frame.offset
            while i + 2 < end {
                if bytes[i] == 0, bytes[i + 1] == 0 {
                    let length = bytes[i + 2] == 1 ? 3 : (i + 3 < end && bytes[i + 2] == 0 && bytes[i + 3] == 1 ? 4 : 0)
                    if length > 0 {
                        if let start, start < i { result.append(start..<i) }
                        i += length
                        start = i
                        continue
                    }
                }
                i += 1
            }
        }
        if let start, start < end { result.append(start..<end) }
        return result
    }
}
