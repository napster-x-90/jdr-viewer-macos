import SwiftUI

@main
struct JDRViewer: App {
    @StateObject private var model = ViewerModel()

    var body: some Scene {
        Window("블랙박스 뷰어", id: "main") {
            ViewerScreen(model: model)
                .frame(minWidth: 880, minHeight: 520)
                .task { model.start() }
        }
        .defaultSize(width: 1240, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("녹화 폴더 열기…") { model.choose() }.keyboardShortcut("o")
            }
        }
    }
}

struct ViewerScreen: View {
    @ObservedObject var model: ViewerModel
    private let canvas = Color(red: 0.065, green: 0.078, blue: 0.096)
    private let accent = Color(red: 0.43, green: 0.84, blue: 0.82)

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 255)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                stage.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                controls
            }
        }
        .background(canvas)
        .preferredColorScheme(.dark)
        .tint(accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "car.side.fill").foregroundStyle(accent)
                    Text("블랙박스 뷰어").font(.headline)
                }
                Button { model.choose() } label: {
                    Label("녹화 폴더 열기", systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.controlSize(.large)
                if let source = model.source {
                    Label(source.lastPathComponent, systemImage: "externaldrive")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(source.path)
                }
            }.padding(16)
            Divider()
            HStack {
                Text("녹화 목록").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(model.filtered.count.formatted())개")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 9)
            if !model.dates.isEmpty {
                Picker("녹화 날짜", selection: $model.dateFilter) {
                    Text("모든 날짜").tag("")
                    ForEach(model.dates, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().padding(.horizontal, 16).padding(.bottom, 10)
            }
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.filtered) { clip in
                        Button { model.select(clip) } label: { row(clip) }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 8).padding(.bottom, 8)
            }
            Divider()
            if let library = model.library {
                Text("JDR \(library.files.formatted())개" + (library.skipped > 0 ? " · 읽기 실패 \(library.skipped)개" : ""))
                    .font(.caption).foregroundStyle(.secondary).padding(14)
            } else {
                Text(model.scanning ? "목록 읽는 중…" : "JDR").font(.caption)
                    .foregroundStyle(.secondary).padding(14)
            }
        }.background(.white.opacity(0.035))
    }

    private func row(_ clip: Recording) -> some View {
        let selected = clip == model.selection
        return HStack(spacing: 10) {
            Image(systemName: selected ? "play.circle.fill" : "film")
                .frame(width: 18).foregroundStyle(selected ? accent : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(ViewerModel.time.string(from: clip.date)).font(.system(.subheadline, design: .monospaced).weight(.semibold))
                Text(ViewerModel.day.string(from: clip.date) + "  ·  " + clip.filename)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 8).padding(.horizontal, 10)
         .background(selected ? accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
         .contentShape(Rectangle())
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                if let clip = model.selection {
                    Text(ViewerModel.day.string(from: clip.date) + "  " + ViewerModel.time.string(from: clip.date))
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text(clip.filename).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("녹화 영상").font(.title3.weight(.semibold))
                }
            }
            Spacer()
            Picker("카메라", selection: $model.layout) {
                Text("두 채널").tag(2)
                Text("00").tag(0)
                Text("01").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 180)
            .disabled(model.loaded == nil)
            Menu {
                ForEach(0..<2, id: \.self) { channel in
                    if model.loaded?.movies[channel] != nil {
                        Button("채널 \(channel == 0 ? "00" : "01") 저장…") { model.saveMP4(channel: channel) }
                    }
                }
            } label: {
                if model.exporting {
                    Label("저장 중…", systemImage: "hourglass")
                } else {
                    Label("MP4 저장", systemImage: "arrow.down.to.line")
                }
            }
            .fixedSize()
            .disabled(model.loaded == nil || model.exporting)
        }.padding(.horizontal, 20).frame(height: 65)
    }

    @ViewBuilder private var stage: some View {
        if let loaded = model.loaded {
            let channels = model.layout == 2 ? [0, 1] : [model.layout]
            HStack(spacing: 8) {
                ForEach(channels, id: \.self) { channel in
                    ZStack(alignment: .topLeading) {
                        if loaded.movies[channel] != nil {
                            CameraView(player: model.players[channel])
                        } else {
                            Color.black.overlay {
                                Label("이 채널에 영상이 없습니다", systemImage: "video.slash")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(channel == 0 ? "채널 00" : "채널 01")
                            .font(.caption.weight(.medium)).padding(.horizontal, 9).padding(.vertical, 5)
                            .background(.black.opacity(0.75), in: Capsule()).padding(10)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                     .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }.padding(14)
            .overlay(alignment: .bottom) {
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle").padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(22)
                }
            }
        } else {
            VStack(spacing: 14) {
                if model.scanning || model.loading {
                    ProgressView().controlSize(.large)
                    Text(model.scanning ? "녹화 목록을 읽는 중" : "영상을 준비하는 중")
                        .font(.headline)
                } else if let error = model.error {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 35)).foregroundStyle(.orange)
                    Text(error).multilineTextAlignment(.center)
                    Button("다시 열기…") { model.choose() }
                } else {
                    Image(systemName: "play.rectangle").font(.system(size: 44, weight: .light)).foregroundStyle(accent)
                    Text(model.library == nil ? "녹화 파일을 열어 주세요" : "녹화 구간을 선택하세요").font(.title3.weight(.semibold))
                    if model.library == nil { Button("녹화 폴더 열기…") { model.choose() } }
                }
            }.padding(24)
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text(duration(model.position))
                Slider(value: $model.position, in: 0...max(0.01, model.loaded?.duration ?? 0.01),
                       onEditingChanged: { editing in if editing { model.beginScrub() } else { model.endScrub() } })
                    .accessibilityLabel("재생 위치")
                Text(duration(model.loaded?.duration ?? 0))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                icon("backward.end.fill", "이전 구간") { model.step(-1) }
                icon("gobackward.10", "10초 뒤로") { model.jump(-10) }
                Button { model.toggle() } label: {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold)).frame(width: 34, height: 24)
                }.buttonStyle(.borderedProminent).keyboardShortcut(.space, modifiers: [])
                 .accessibilityLabel(model.playing ? "일시 정지" : "재생")
                icon("goforward.10", "10초 앞으로") { model.jump(10) }
                icon("forward.end.fill", "다음 구간") { model.step(1) }
                Spacer()
                if let loaded = model.loaded {
                    Text(ViewerModel.time.string(from: loaded.start.addingTimeInterval(model.position)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                icon(model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", model.muted ? "소리 켜기" : "음소거") {
                    model.muted.toggle()
                }.disabled(model.loaded?.hasAudio != true)
                Picker("배속", selection: $model.speed) {
                    ForEach([Float(0.5), 1, 1.5, 2], id: \.self) { rate in
                        Text(rate.formatted() + "×").tag(rate)
                    }
                }.labelsHidden().frame(width: 72)
            }
        }.padding(.horizontal, 20).padding(.vertical, 12).disabled(model.loaded == nil)
    }

    private func icon(_ name: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).frame(width: 24, height: 24) }
            .buttonStyle(.borderless).help(label).accessibilityLabel(label)
    }

    private func duration(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
