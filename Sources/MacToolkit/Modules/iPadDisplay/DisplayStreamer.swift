import AppKit
import ScreenCaptureKit
import CoreMedia

/// 画面を ScreenCaptureKit で取り込み、H.264 にエンコードして
/// iPad へ配信する。ScreenRecorder と同じく専用のシリアルキューに
/// 可変状態を閉じ込めて `@unchecked Sendable` にしている。
///
/// ライフサイクル: `start` で Bonjour の待ち受けだけを開始し、
/// iPad が接続してきたらキャプチャを起こす。切断されたらキャプチャを
/// 止めて待ち受けに戻る（誰も見ていないのに撮り続けない）。
final class DisplayStreamer: NSObject, @unchecked Sendable {
    enum StreamerError: LocalizedError {
        case noPermission
        case targetNotFound

        var errorDescription: String? {
            switch self {
            case .noPermission: "画面収録の権限が必要です"
            case .targetNotFound: "配信する画面が見つかりません"
            }
        }
    }

    /// 配信対象。
    enum Target: Equatable, Sendable {
        /// メインディスプレイ全体。
        case display
        /// 特定のウインドウ。
        case window(CGWindowID)
    }

    struct Configuration: Sendable {
        var target: Target
        var fps: Int
        /// ビット毎秒。
        var bitrate: Int
        /// Retina の実ピクセルで送るか。false ならポイント解像度
        /// （データ量が 1/4 になり、iPad 側の描画も軽い）。
        var usesRetina: Bool
    }

    /// すべて streamer 内部のキューから `@Sendable` コールバックで通知される。
    enum Event: Sendable {
        /// iPad が TCP 接続してきた（端末名はまだ不明）。
        case clientConnected
        /// hello で端末名が分かった。
        case clientNamed(String)
        case clientDisconnected
        /// iPad 側で計測した遅延と受信 FPS。
        case stats(latencyMs: Double, receivedFPS: Double)
        case captureFailed(String)
        case serverFailed(String)
    }

    /// キャプチャ・エンコード・送信の可変状態を扱う唯一のキュー。
    private let queue = DispatchQueue(label: "com.nagomiita.mac-toolkit.ipad-display")

    private let server: StreamServer
    private let encoder = VideoEncoder()

    private var configuration = Configuration(
        target: .display, fps: 60, bitrate: 8_000_000, usesRetina: false
    )
    private var onEvent: (@Sendable (Event) -> Void)?

    private var stream: SCStream?
    /// beginCapture の起動中も含む「キャプチャが生きているか」。
    private var captureActive = false
    /// 次にエンコードするフレームでキーフレームを強制するか。
    private var needsKeyFrame = false
    /// 最初のキーフレームを送るまで通常フレームを止めるゲート。
    /// 途中から受信を始めたデコーダに差分フレームを食わせないため。
    private var waitingForKeyFrame = true
    private var lastSentParameterSets: [Data]?
    /// エンコード後の実寸。videoConfig に載せる。
    private var videoWidth = 0
    private var videoHeight = 0

    override init() {
        server = StreamServer(queue: queue)
        super.init()
        server.onClientConnected = { [weak self] in self?.clientDidConnect() }
        server.onClientDisconnected = { [weak self] in self?.clientDidDisconnect() }
        server.onPacket = { [weak self] type, payload in self?.handle(type, payload) }
        server.onListenerFailed = { [weak self] message in
            guard let self else { return }
            self.onEvent?(.serverFailed(message))
        }
    }

    // MARK: - 開始 / 停止

    /// Bonjour の広告と待ち受けを始める。キャプチャはまだ始めない。
    func start(
        configuration: Configuration,
        serviceName: String,
        onEvent: @escaping @Sendable (Event) -> Void
    ) throws {
        guard ScreenCapturer.hasPermission else { throw StreamerError.noPermission }
        try queue.sync {
            self.configuration = configuration
            self.onEvent = onEvent
            try self.server.start(serviceName: serviceName)
        }
    }

    /// 待ち受けとキャプチャを完全に止める。
    func stop() async {
        queue.sync {
            server.stop()
            onEvent = nil
        }
        await endCapture()
    }

    // MARK: - 接続イベント（queue 上）

    private func clientDidConnect() {
        dispatchPrecondition(condition: .onQueue(queue))
        needsKeyFrame = true
        waitingForKeyFrame = true
        lastSentParameterSets = nil
        onEvent?(.clientConnected)

        if !captureActive {
            captureActive = true
            Task { await self.beginCapture() }
        }
    }

    private func clientDidDisconnect() {
        dispatchPrecondition(condition: .onQueue(queue))
        onEvent?(.clientDisconnected)
        if captureActive {
            Task { await self.endCapture() }
        }
    }

    private func handle(_ type: StreamPacket.PacketType, _ payload: Data) {
        dispatchPrecondition(condition: .onQueue(queue))
        switch type {
        case .hello:
            let name = String(decoding: payload.prefix(128), as: UTF8.self)
            if !name.isEmpty {
                onEvent?(.clientNamed(name))
            }
        case .ping:
            // 時計合わせは往復時間が命なので、その場で即返す。
            guard let ping = PingPacket(payload: payload) else { return }
            let pong = PongPacket(
                clientTimeMs: ping.clientTimeMs,
                serverTimeMs: Date().timeIntervalSince1970 * 1000
            )
            server.send(type: .pong, payload: pong.payload())
        case .stats:
            guard let stats = StatsPacket(payload: payload) else { return }
            onEvent?(.stats(latencyMs: stats.latencyMs, receivedFPS: stats.fps))
        default:
            break
        }
    }

    // MARK: - キャプチャ

    private func beginCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )

            let filter: SCContentFilter
            let scalesToFit: Bool
            switch configuration.target {
            case .display:
                let mainID = CGMainDisplayID()
                guard let display = content.displays.first(where: { $0.displayID == mainID })
                    ?? content.displays.first
                else { throw StreamerError.targetNotFound }
                filter = SCContentFilter(display: display, excludingWindows: [])
                scalesToFit = false
            case .window(let windowID):
                guard let window = content.windows.first(where: { $0.windowID == windowID })
                else { throw StreamerError.targetNotFound }
                filter = SCContentFilter(desktopIndependentWindow: window)
                // ウインドウはあとからリサイズされうるので枠に収める。
                scalesToFit = true
            }

            // NSScreen を介さず、フィルタ自身が知っているポイント寸法と
            // 倍率から実寸を出す。H.264 は偶数寸法しか受けない。
            let scale = configuration.usesRetina ? CGFloat(filter.pointPixelScale) : 1
            let width = max(2, Int(filter.contentRect.width * scale) & ~1)
            let height = max(2, Int(filter.contentRect.height * scale) & ~1)

            let streamConfiguration = SCStreamConfiguration()
            streamConfiguration.width = width
            streamConfiguration.height = height
            streamConfiguration.minimumFrameInterval = CMTime(
                value: 1, timescale: CMTimeScale(configuration.fps)
            )
            // エンコーダに直結するので最初から 4:2:0 で受け取る。
            streamConfiguration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            streamConfiguration.showsCursor = true
            // 深いキューは遅延になる。取りこぼしはドロップで受け入れる。
            streamConfiguration.queueDepth = 3
            streamConfiguration.scalesToFit = scalesToFit

            try queue.sync {
                try encoder.prepare(
                    width: width, height: height,
                    fps: configuration.fps, bitrate: configuration.bitrate
                )
                videoWidth = width
                videoHeight = height
            }

            let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()

            let clientStillHere = queue.sync {
                self.stream = stream
                return server.hasClient
            }
            // セットアップ中に切断されていたら撮り続けない。
            if !clientStillHere {
                await endCapture()
            }
        } catch {
            let message = error.localizedDescription
            queue.async {
                self.captureActive = false
                self.encoder.invalidate()
                self.onEvent?(.captureFailed(message))
            }
        }
    }

    private func endCapture() async {
        let stream = queue.sync {
            let stream = self.stream
            self.stream = nil
            self.captureActive = false
            self.encoder.invalidate()
            return stream
        }
        guard let stream else { return }
        try? await stream.stopCapture()
    }

    // MARK: - 送信（queue 上）

    private func sendFrame(_ frame: VideoEncoder.EncodedFrame, captureTimeMs: Double) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard server.hasClient else { return }

        if waitingForKeyFrame {
            guard frame.isKeyFrame else { return }
            waitingForKeyFrame = false
        }

        // デコード設定はキーフレームの直前に送る。切断→再接続や
        // セッション作り直しでパラメータセットが変わることがある。
        if frame.isKeyFrame, frame.parameterSets != lastSentParameterSets {
            let config = VideoConfigPacket(
                width: videoWidth, height: videoHeight,
                parameterSets: frame.parameterSets
            )
            server.send(type: .videoConfig, payload: config.payload())
            lastSentParameterSets = frame.parameterSets
        }

        let packet = VideoFramePacket(
            captureTimeMs: captureTimeMs, isKeyFrame: frame.isKeyFrame, data: frame.data
        )
        server.send(type: .videoFrame, payload: packet.payload())
    }
}

// MARK: - フレームの受け取り

extension DisplayStreamer: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        // addStreamOutput で指定したとおり `queue` 上で呼ばれる。
        dispatchPrecondition(condition: .onQueue(queue))
        guard type == .screen, server.hasClient else { return }
        guard isCompleteFrame(sampleBuffer),
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        // 背圧: 送信が滞っている間はエンコード前に捨てる。
        // エンコード後に捨てると参照フレームが欠けてデコーダが壊れる。
        if server.isBacklogged { return }

        let captureTimeMs = Date().timeIntervalSince1970 * 1000
        let force = needsKeyFrame
        needsKeyFrame = false

        encoder.encode(
            imageBuffer,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            forceKeyFrame: force
        ) { [weak self] frame in
            // エンコーダ内部のキューから呼ばれるので自分のキューへ戻す。
            guard let self else { return }
            self.queue.async {
                guard let frame else {
                    // 強制キーフレームが失敗で消えたら次のフレームで打ち直す。
                    if force { self.needsKeyFrame = true }
                    return
                }
                self.sendFrame(frame, captureTimeMs: captureTimeMs)
            }
        }
    }

    /// 変化のあった完全なフレームか。
    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }
}

extension DisplayStreamer: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("iPadDisplay: stream stopped: %@", "\(error)")
        let message = error.localizedDescription
        queue.async {
            guard stream === self.stream else { return }
            self.stream = nil
            self.captureActive = false
            self.encoder.invalidate()
            self.server.dropClient()
            self.onEvent?(.captureFailed(message))
        }
    }
}
