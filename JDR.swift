import Foundation

struct ViewerError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct Recording: Identifiable, Hashable {
    let file: URL
    let offset: Int
    let limit: Int
    let date: Date
    var id: String { "\(file.path)#\(offset)" }
    var filename: String { file.lastPathComponent }
}

struct Library {
    let recordings: [Recording]
    let files: Int
    let skipped: Int
}

struct Frame {
    let offset: Int
    let length: Int
    let date: Date
    let key: Bool
    let fps: Int
}

struct Segment {
    let data: Data
    let frames: [[Frame]]
    let audio: [Frame]
    let start: Date
    let sampleRate: Int
    let bits: Int
}

enum JDR {
    // Interpret SYSTEMTIME as a wall clock. UTC keeps its original display fields intact.
    static var clock: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func stamp(_ bytes: Data, _ offset: Int) -> Date? {
        let fields = (0..<8).map { bytes.u16(offset + 2 * $0) }
        guard (2000...2099).contains(fields[0]), (1...12).contains(fields[1]),
              (1...31).contains(fields[3]), fields[4] < 24, fields[5] < 60,
              fields[6] < 60, fields[7] < 1000 else { return nil }
        return clock.date(from: DateComponents(year: fields[0], month: fields[1], day: fields[3],
                                               hour: fields[4], minute: fields[5], second: fields[6],
                                               nanosecond: fields[7] * 1_000_000))
    }

    static func scan(_ url: URL) throws -> Library {
        var folder = url
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else {
            throw ViewerError("폴더나 파일을 찾을 수 없습니다. USB 연결을 확인해 주세요.")
        }
        var files = [url]
        if directory.boolValue {
            let child = url.appendingPathComponent("data", isDirectory: true)
            if FileManager.default.fileExists(atPath: child.path) { folder = child }
            files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])
        }
        files = files.filter { $0.pathExtension.lowercased() == "jdr" }
        guard !files.isEmpty else { throw ViewerError("이 위치에 JDR 파일이 없습니다.") }
        var recordings: [Recording] = []
        var skipped = 0
        for file in files {
            try Task.checkCancellation()
            do { recordings += try scanFile(file) }
            catch { skipped += 1 }
        }
        recordings.sort { ($0.date, $0.id) > ($1.date, $1.id) }
        return Library(recordings: recordings, files: files.count, skipped: skipped)
    }

    private static func scanFile(_ file: URL) throws -> [Recording] {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: 1536) ?? Data()
        guard header.count == 1536, header.u32(0) == 0x4a414e31, header.u32(512) == 0x4a455631 else {
            throw ViewerError("지원하지 않는 JDR 헤더입니다.")
        }
        let count = header.u32(516)
        guard count <= 50 else { throw ViewerError("JDR 색인 크기가 올바르지 않습니다.") }
        var entries: [Int: Date] = [:]
        for i in 0..<count {
            let at = 520 + i * 20
            let offset = header.u32(at) >> 4
            if offset >= 1536, offset % 512 == 0, offset <= size - 512, let date = stamp(header, at + 4) {
                entries[offset] = date
            }
        }
        if count > 0 && entries.isEmpty { throw ViewerError("유효한 녹화 구간을 찾지 못했습니다.") }
        let offsets = entries.keys.sorted()
        return offsets.enumerated().map { i, offset in
            Recording(file: file, offset: offset, limit: i + 1 < offsets.count ? offsets[i + 1] : size,
                      date: entries[offset]!)
        }
    }

    static func read(_ recording: Recording) throws -> Segment {
        let handle = try FileHandle(forReadingFrom: recording.file)
        defer { try? handle.close() }
        let global = try handle.read(upToCount: 32) ?? Data()
        try handle.seek(toOffset: UInt64(recording.offset))
        let header = try handle.read(upToCount: 512) ?? Data()
        guard global.count == 32, global.u32(0) == 0x4a414e31,
              header.count == 512, header.u32(0) == 0x4a454231 else {
            throw ViewerError("녹화 구간의 헤더를 읽을 수 없습니다.")
        }
        let count = header.u32(4)
        let start = recording.offset + 512
        let index = header.u32(0xb8)
        let end = index > start && index <= recording.limit ? index : recording.limit
        guard count > 0, count <= 200_000, end > start, end - start <= 100 * 1024 * 1024 else {
            throw ViewerError("녹화 구간의 크기가 올바르지 않습니다.")
        }
        let bytes = try handle.read(upToCount: end - start) ?? Data()
        var at = 0
        var channels: [[Frame]] = [[], []]
        var audio: [Frame] = []
        for i in 0..<count {
            if i % 512 == 0 { try Task.checkCancellation() }
            guard at <= bytes.count - 28 else { throw ViewerError("녹화 구간이 중간에 끊겼습니다.") }
            let length = bytes.u32(at + 4)
            guard length <= bytes.count - at - 28 else { throw ViewerError("프레임 길이가 올바르지 않습니다.") }
            let payload = at + 28
            let video = bytes[at + 2] == 86 && (bytes[at + 3] == 73 || bytes[at + 3] == 80)
            let sound = bytes[at + 2] == 65 && bytes[at + 3] == 68
            if (video || sound), length > 0, let date = stamp(bytes, at + 12) {
                let frame = Frame(offset: payload, length: length, date: date,
                                  key: bytes[at + 3] == 73, fps: bytes[at + 8] == 0 ? 30 : Int(bytes[at + 8]))
                if video, bytes[at] == 48, (48...49).contains(bytes[at + 1]) {
                    let channel = Int(bytes[at + 1] - 48)
                    if frame.key || !channels[channel].isEmpty { channels[channel].append(frame) }
                } else if sound { audio.append(frame) }
            }
            at = payload + length
        }
        guard let first = channels.compactMap({ $0.first?.date }).min() else {
            throw ViewerError("이 구간에 재생할 영상이 없습니다.")
        }
        let startTime = min(first, recording.date)
        return Segment(data: bytes, frames: channels, audio: audio, start: startTime,
                       sampleRate: global.u32(24), bits: global.u32(28))
    }
}

extension Data {
    func u16(_ i: Int) -> Int { Int(self[i]) | Int(self[i + 1]) << 8 }
    func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
}
