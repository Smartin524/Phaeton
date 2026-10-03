import AppKit
import AVFoundation
import AVKit
import FormatWheelCore
import SwiftUI

struct AudioToolView: View {
    let urls: [URL]
    let perform: (String, @escaping ToolWork) -> Void
    let close: () -> Void

    @StateObject private var model: MediaEditorModel
    @State private var fadeIn = false
    @State private var fadeOut = false

    private var isBatch: Bool { urls.count > 1 }

    init(urls: [URL], perform: @escaping (String, @escaping ToolWork) -> Void, close: @escaping () -> Void) {
        self.urls = urls
        self.perform = perform
        self.close = close
        _model = StateObject(wrappedValue: MediaEditorModel(url: urls[0]))
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                Spacer(minLength: 0)
                Text(clock(model.current))
                    .font(.system(size: 34, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                if isBatch {
                    Text("音频剪辑一次只能处理一个文件，请只拖一个。").font(.callout).foregroundStyle(.secondary)
                } else {
                    TrimTimeline(model: model).frame(height: 74)
                    Button { model.togglePlay() } label: {
                        Image(systemName: model.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
                            .background(Circle().fill(Color.primary.opacity(0.09)))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                }
                Text(model.details).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            SidePanel {
                VStack(alignment: .leading, spacing: 16) {
                PanelSection(caption: "片段") {
                    HStack {
                        Text(clock(model.start)).font(.system(size: 12).monospacedDigit())
                        Text("→").foregroundStyle(.secondary)
                        Text(clock(model.end)).font(.system(size: 12).monospacedDigit())
                        Spacer(minLength: 4)
                        Text(clock(model.end - model.start)).font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        WideButton(title: "设为起点") { model.start = min(model.current, model.end - 0.1) }
                        WideButton(title: "设为终点") { model.end = max(model.current, model.start + 0.1) }
                    }
                }
                PanelSection(caption: "淡入淡出（各 1 秒）") {
                    HStack(spacing: 6) {
                        Chip(title: "淡入", selected: fadeIn) { fadeIn.toggle() }
                        Chip(title: "淡出", selected: fadeOut) { fadeOut.toggle() }
                    }
                }
                WideButton(title: "保存片段", action: save)
                }
                .disabled(isBatch)
            } footer: {
                HStack {
                    Spacer()
                    Button("关闭", action: close).keyboardShortcut(.cancelAction).buttonStyle(PanelButtonStyle())
                }
            }
        }
        .ignoresSafeArea()
        .tint(Theme.accent)
        .onDisappear { model.shutdown() }
        .task { await model.loadAudio() }
    }

    private func save() {
        let start = model.start, end = model.end
        let fi = fadeIn ? 1.0 : 0, fo = fadeOut ? 1.0 : 0
        let service = ConversionService()
        perform("剪切音频") { source, progress in
            try await service.trimAudio(source: source, start: start, end: end, fadeIn: fi, fadeOut: fo, progress: progress)
        }
        close()
    }
}
