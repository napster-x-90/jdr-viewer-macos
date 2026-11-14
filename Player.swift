import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class ViewerModel: ObservableObject {
    @Published var library: Library? {
        didSet {
            let groups = Dictionary(grouping: library?.recordings ?? []) { Self.day.string(from: $0.date) }
            grouped = groups
            dates = groups.keys.sorted(by: >)
        }
    }
    @Published var source: URL?
    @Published var selection: Recording?
    @Published var loaded: PreparedRecording?
    @Published var scanning = false
    @Published var loading = false
    @Published var error: String?
    @Published var position = 0.0
    @Published var playing = false
    @Published var muted = false { didSet { audioPlayer.isMuted = muted } }
    @Published var speed: Float = 1 { didSet { if playing { schedulePlayback() } } }
    @Published private(set) var exporting = false
    @Published var layout = 2
    @Published var dateFilter = ""
    let players = [AVPlayer(), AVPlayer()]
    private let audioPlayer = AVPlayer()
    private var playbackPlayers: [AVPlayer] { players + [audioPlayer] }
    private var scanTask: Task<Library, Error>?
    private var preparation: Task<PreparedRecording, Error>?
    private var generation = 0
    private var transport = 0
    private var timer: Timer?
    private var didStart = false
    private var seeking = false
    private var resumeAfterScrub = false

    private var grouped: [String: [Recording]] = [:]
    private(set) var dates: [String] = []

    var filtered: [Recording] {
        if dateFilter.isEmpty { return library?.recordings ?? [] }
        return grouped[dateFilter] ?? []
    }

    static let day = formatter("yyyy.MM.dd")
    static let time = formatter("HH:mm:ss")
    private static func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = JDR.clock
        formatter.timeZone = JDR.clock.timeZone
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = pattern
        return formatter
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        playbackPlayers.forEach {
            $0.actionAtItemEnd = .pause
            $0.automaticallyWaitsToMinimizeStalling = false
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let last = UserDefaults.standard.string(forKey: "LastJDRSource"),
           FileManager.default.fileExists(atPath: last) {
            open(URL(fileURLWithPath: last))
            return
        }
        let volumes = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let cards = volumes.filter {
            let dir = $0.appendingPathComponent("data")
            return (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
                .contains(where: { $0.lowercased().hasSuffix(".jdr") }) == true
        }
        if cards.count == 1 { open(cards[0]) }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "USB, data 폴더 또는 JDR 파일을 선택하세요."
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        generation += 1
        let token = generation
        scanTask?.cancel()
        preparation?.cancel()
        resetPlayback()
        selection = nil
        library = nil
        dateFilter = ""
        source = url
        scanning = true
        loading = false
        error = nil
        let task = Task.detached(priority: .userInitiated) { try JDR.scan(url) }
        scanTask = task
        Task {
            do {
                let result = try await task.value
                guard generation == token else { return }
                library = result
                if result.recordings.isEmpty { error = "유효한 녹화 구간이 없습니다." }
                else { UserDefaults.standard.set(url.path, forKey: "LastJDRSource") }
            } catch {
                guard generation == token else { return }
                self.error = error.localizedDescription
            }
            scanning = false
        }
    }

    func select(_ recording: Recording) {
        guard selection != recording || error != nil else { return }
        generation += 1
        let token = generation
        preparation?.cancel()
        resetPlayback()
        selection = recording
        loading = true
        error = nil
        let task = Task.detached(priority: .userInitiated) { try Movies.prepare(recording) }
        preparation = task
        Task {
            do {
                let result = try await task.value
                guard generation == token else { return }
                loaded = result
                for i in players.indices {
                    if let url = result.movies[i] { players[i].replaceCurrentItem(with: AVPlayerItem(url: url)) }
                }
                if let audio = result.audio { audioPlayer.replaceCurrentItem(with: AVPlayerItem(url: audio)) }
                loading = false
                schedulePlayback()
            } catch {
                guard generation == token else { return }
                self.error = error.localizedDescription
                loading = false
            }
        }
    }

    func saveMP4(channel: Int) {
        guard !exporting, let selection, let recording = loaded,
              recording.movies.indices.contains(channel), recording.movies[channel] != nil else { return }
        let panel = NSSavePanel()
        panel.title = "MP4 저장"
        panel.prompt = "저장"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        let time = Self.time.string(from: selection.date).replacingOccurrences(of: ":", with: "-")
        let channelName = String(format: "%02d", channel)
        panel.nameFieldStringValue = "\(Self.day.string(from: selection.date))_\(time)_CH\(channelName).mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        Task {
            defer { exporting = false }
            do {
                let task = Task.detached(priority: .userInitiated) {
                    try await MP4Export.save(recording, channel: channel, to: url)
                }
                try await task.value
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                let alert = NSAlert()
                alert.messageText = "MP4를 저장하지 못했습니다"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    func step(_ direction: Int) {
        let list = filtered
        guard let selection, let i = list.firstIndex(of: selection),
              list.indices.contains(i - direction) else { return }
        select(list[i - direction])
    }

    func toggle() {
        guard let loaded else { return }
        if playing { pause() }
        else if position >= loaded.duration - 0.05 { seek(0, resume: true) }
        else { schedulePlayback() }
    }

    func beginScrub() {
        resumeAfterScrub = playing
        pause()
        seeking = true
    }

    func endScrub() { seek(position, resume: resumeAfterScrub) }

    func jump(_ delta: Double) { seek(position + delta, resume: playing) }

    private func resetPlayback() {
        pause()
        playbackPlayers.forEach { $0.replaceCurrentItem(with: nil) }
        loaded = nil
        position = 0
        seeking = false
    }

    private func pause() {
        transport += 1
        playing = false
        playbackPlayers.forEach { $0.pause() }
    }

    private func seek(_ target: Double, resume: Bool) {
        guard let loaded else { return }
        pause()
        let token = transport
        position = max(0, min(target, loaded.duration))
        seeking = true
        let time = CMTime(seconds: position, preferredTimescale: 1000)
        Task {
            for player in playbackPlayers where player.currentItem != nil {
                await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                guard token == transport else { return }
            }
            seeking = false
            if resume && position < loaded.duration { schedulePlayback() }
        }
    }

    private func schedulePlayback() {
        guard loaded != nil else { return }
        transport += 1
        let token = transport
        playing = true
        seeking = false
        let time = CMTime(seconds: position, preferredTimescale: 1000)
        Task {
            let active = playbackPlayers.filter { $0.currentItem != nil }
            for player in active { player.pause() }
            for _ in 0..<200 {
                guard token == transport else { return }
                if active.allSatisfy({ $0.currentItem?.status == .readyToPlay }) { break }
                if active.contains(where: { $0.currentItem?.status == .failed }) { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard token == transport else { return }
            guard active.allSatisfy({ $0.currentItem?.status == .readyToPlay }) else {
                pause()
                error = "이 구간을 재생할 수 없습니다."
                return
            }
            let host = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(value: 160, timescale: 1000)
            for player in active { player.setRate(speed, time: time, atHostTime: host) }
        }
    }

    private func tick() {
        guard let loaded else { return }
        if let failure = players.first(where: { $0.currentItem?.status == .failed })?.currentItem?.error {
            pause()
            error = failure.localizedDescription
            return
        }
        guard !seeking else { return }
        let active = playbackPlayers.compactMap { player -> Double? in
            guard player.currentItem != nil else { return nil }
            let seconds = player.currentTime().seconds
            return seconds.isFinite ? seconds : nil
        }
        if playing, let latest = active.max() {
            position = min(latest, loaded.duration)
            let stopped = playbackPlayers.allSatisfy { $0.currentItem == nil || $0.rate == 0 }
            if latest >= loaded.duration - 0.03 || (stopped && latest > loaded.duration - 0.15) {
                position = loaded.duration
                pause()
            }
        }
    }
}

final class CameraSurface: NSView {
    let display = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = display
        display.backgroundColor = NSColor.black.cgColor
        display.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { nil }
}

struct CameraView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> CameraSurface {
        let surface = CameraSurface(frame: .zero)
        surface.display.player = player
        return surface
    }
    func updateNSView(_ view: CameraSurface, context: Context) { view.display.player = player }
    static func dismantleNSView(_ view: CameraSurface, coordinator: ()) { view.display.player = nil }
}
