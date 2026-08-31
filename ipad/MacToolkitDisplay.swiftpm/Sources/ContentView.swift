import SwiftUI

struct ContentView: View {
    @State private var model = ViewerModel()
    /// 視聴中の情報オーバーレイ。タップで出し入れする。
    @State private var showsOverlay = true

    var body: some View {
        Group {
            switch model.phase {
            case .browsing:
                browsingView
            case .connecting:
                connectingView
            case .streaming:
                streamingView
            }
        }
        .onAppear { model.startBrowsing() }
    }

    // MARK: - 探索

    private var browsingView: some View {
        NavigationStack {
            List {
                if let reason = model.disconnectReason {
                    Section {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                Section("見つかった Mac") {
                    if model.browser.macs.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("検索中…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(model.browser.macs) { mac in
                            Button {
                                model.connect(to: mac)
                            } label: {
                                Label(mac.name, systemImage: "desktopcomputer")
                            }
                        }
                    }
                }

                Section {
                    Text("Mac 側で MacToolkit の「iPad ディスプレイ」から配信を開始すると、ここに表示される")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("MacToolkit Display")
        }
    }

    // MARK: - 接続中

    private var connectingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("\(model.macName ?? "Mac") に接続中…")
                .foregroundStyle(.secondary)
            Button("キャンセル") {
                model.disconnect()
            }
        }
    }

    // MARK: - 視聴

    private var streamingView: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            VideoSurfaceView(layer: model.displayLayer)
                .ignoresSafeArea()
            if showsOverlay {
                overlay
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                showsOverlay.toggle()
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    private var overlay: some View {
        HStack(spacing: 14) {
            Label(model.macName ?? "Mac", systemImage: "desktopcomputer")
                .lineLimit(1)
            Text("遅延 \(model.latencyText)")
            Text(model.fpsText)
            Button("切断", role: .destructive) {
                model.disconnect()
            }
        }
        .font(.footnote.monospacedDigit())
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 24)
    }
}
