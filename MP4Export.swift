import AVFoundation
import AudioToolbox
import Foundation

enum MP4Export {
    static func save(_ recording: PreparedRecording, channel: Int, to destination: URL) async throws {
        guard recording.movies.indices.contains(channel), let movie = recording.movies[channel] else {
            throw ViewerError("이 채널에 저장할 영상이 없습니다.")
        }
        let folder = destination.deletingLastPathComponent()
        let staged = folder.appendingPathComponent(".jdr-" + UUID().uuidString + ".mp4")
        let encodedAudio = recording.folder.appendingPathComponent("export-" + UUID().uuidString + ".m4a")
        defer {
            try? FileManager.default.removeItem(at: staged)
            try? FileManager.default.removeItem(at: encodedAudio)
        }

        let video = AVURLAsset(url: movie)
        let composition = AVMutableComposition()
        let duration = try await video.load(.duration)
        try await insertTrack(from: video, type: .video, duration: duration, into: composition)
        if let audio = recording.audio {
            try encodeAudio(from: audio, to: encodedAudio)
            let asset = AVURLAsset(url: encodedAudio)
            let audioDuration = try await asset.load(.duration)
            try await insertTrack(from: asset, type: .audio, duration: min(duration, audioDuration), into: composition)
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough),
              session.supportedFileTypes.contains(.mp4) else {
            throw ViewerError("이 영상을 MP4로 저장할 수 없습니다.")
        }
        session.shouldOptimizeForNetworkUse = true
        if #available(macOS 15.0, *) {
            try await session.export(to: staged, as: .mp4)
        } else {
            session.outputURL = staged
            session.outputFileType = .mp4
            await session.export()
            guard session.status == .completed else {
                throw session.error ?? ViewerError("MP4를 저장하지 못했습니다.")
            }
        }

        // Publish the completed file atomically, including when replacing an existing MP4.
        let result = staged.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                rename(from!, to!)
            }
        }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func insertTrack(from asset: AVAsset, type: AVMediaType, duration: CMTime,
                                    into composition: AVMutableComposition) async throws {
        guard let source = try await asset.loadTracks(withMediaType: type).first,
              let track = composition.addMutableTrack(withMediaType: type,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ViewerError("MP4에 넣을 트랙을 읽을 수 없습니다.")
        }
        let sourceRange = try await source.load(.timeRange)
        let range = CMTimeRange(start: .zero, duration: duration).intersection(sourceRange)
        guard range.duration > .zero else { throw ViewerError("저장할 트랙이 비어 있습니다.") }
        try track.insertTimeRange(range, of: source, at: range.start)
    }

    private static func encodeAudio(from source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: input.processingFormat.sampleRate,
            AVNumberOfChannelsKey: Int(input.processingFormat.channelCount)
        ]
        let output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: input.processingFormat.commonFormat,
                                     interleaved: input.processingFormat.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192) else {
            throw ViewerError("저장할 소리 트랙을 준비할 수 없습니다.")
        }
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }
}
