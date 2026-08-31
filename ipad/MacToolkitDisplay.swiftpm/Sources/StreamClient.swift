import Foundation
import Network
import AVFoundation
import CoreMedia

/// Mac へ接続して H.264 フレームを受信し、AVSampleBufferDisplayLayer に
/// 流し込む。圧縮のままレイヤーに渡すのでデコードはハードウェア任せ。
///
/// 可変状態はすべて専用のシリアルキューに閉じ込める。
/// AVSampleBufferDisplayLayer の enqueue / flush はスレッド安全なので
/// キュー上から直接呼んでよい。
final class StreamClient: @unchecked Sendable {
    enum Event: Sendable {
        case connected
        /// 切断された。自分から切った場合は通知しない。
        case disconnected(reason: String?)
        /// 1 秒ごとの計測値。latencyMs が負なら未計測。
        case stats(latencyMs: Double, fps: Double)
    }

    private let queue = DispatchQueue(label: "com.nagomiita.mac-toolkit.display.client")
    private let layer: AVSampleBufferDisplayLayer

    private var connection: NWConnection?
    private var onEvent: (@Sendable (Event) -> Void)?
    private var pingTimer: DispatchSourceTimer?

    /// videoConfig から作ったデコード設定。届くまでフレームは捨てる。
    private var formatDescription: CMVideoFormatDescription?
    private var currentParameterSets: [Data] = []

    /// Mac の時計 − iPad の時計（ミリ秒）。最小 RTT の ping で更新する。
    private var clockOffsetMs: Double?
    private var bestRTTMs = Double.infinity

    /// 遅延の指数移動平均。フレームごとの揺れをならす。
    private var latencyEMAMs: Double?
    private var frameCount = 0
    private var windowStart = Date()

    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
    }

    // MARK: - 接続 / 切断

    /// - Parameter deviceName: hello で Mac に伝える端末名。
    ///   UIDevice はメインスレッド前提なので呼び出し側で読んで渡す。
    func connect(
        to endpoint: NWEndpoint,
        deviceName: String,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        queue.async {
            self.teardown(notifyReason: nil)
            self.onEvent = onEvent

            // 映像の小刻みな送受信では Nagle が遅延源になるため無効化する。
            let parameters = NWParameters.tcp
            if let tcp = parameters.defaultProtocolStack.transportProtocol
                as? NWProtocolTCP.Options {
                tcp.noDelay = true
            }
            parameters.includePeerToPeer = true

            let connection = NWConnection(to: endpoint, using: parameters)
            self.connection = connection

            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection,
                      connection === self.connection
                else { return }
                switch state {
                case .ready:
                    self.didConnect(deviceName: deviceName)
                case .failed(let error):
                    self.teardown(notifyReason: error.localizedDescription)
                case .cancelled:
                    self.teardown(notifyReason: "接続が切れました")
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }
    }

    /// 自分から切る。イベントは飛ばさない。
    func disconnect() {
        queue.async {
            self.onEvent = nil
            self.teardown(notifyReason: nil)
        }
    }

    private func didConnect(deviceName: String) {
        onEvent?(.connected)
        send(type: .hello, payload: Data(deviceName.utf8))
        receiveHeader()
        startPingTimer()
    }

    private func teardown(notifyReason: String?) {
        pingTimer?.cancel()
        pingTimer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        formatDescription = nil
        currentParameterSets = []
        clockOffsetMs = nil
        bestRTTMs = .infinity
        latencyEMAMs = nil
        frameCount = 0
        if let notifyReason {
            onEvent?(.disconnected(reason: notifyReason))
            onEvent = nil
        }
    }

    // MARK: - 受信ループ

    private func receiveHeader() {
        guard let connection else { return }
        connection.receive(
            minimumIncompleteLength: StreamPacket.headerLength,
            maximumLength: StreamPacket.headerLength
        ) { [weak self] data, _, isComplete, error in
            guard let self, connection === self.connection else { return }
            guard error == nil, !isComplete,
                  let data, data.count == StreamPacket.headerLength
            else {
                self.teardown(notifyReason: "接続が切れました")
                return
            }

            var reader = PacketReader(data)
            guard let rawType = reader.readUInt8(),
                  let length = reader.readUInt32(),
                  Int(length) <= StreamPacket.maxPayloadLength
            else {
                self.teardown(notifyReason: "不正なデータを受信しました")
                return
            }

            if length == 0 {
                self.handle(rawType: rawType, payload: Data())
                self.receiveHeader()
            } else {
                self.receivePayload(rawType: rawType, length: Int(length))
            }
        }
    }

    private func receivePayload(rawType: UInt8, length: Int) {
        guard let connection else { return }
        connection.receive(
            minimumIncompleteLength: length, maximumLength: length
        ) { [weak self] data, _, isComplete, error in
            guard let self, connection === self.connection else { return }
            guard error == nil, !isComplete, let data, data.count == length else {
                self.teardown(notifyReason: "接続が切れました")
                return
            }
            self.handle(rawType: rawType, payload: data)
            self.receiveHeader()
        }
    }

    private func handle(rawType: UInt8, payload: Data) {
        guard let type = StreamPacket.PacketType(rawValue: rawType) else { return }
        switch type {
        case .videoConfig:
            guard let config = VideoConfigPacket(payload: payload) else { return }
            applyConfig(config)
        case .videoFrame:
            guard let frame = VideoFramePacket(payload: payload) else { return }
            display(frame)
        case .pong:
            guard let pong = PongPacket(payload: payload) else { return }
            updateClock(pong)
        default:
            break
        }
    }

    // MARK: - 映像

    private func applyConfig(_ config: VideoConfigPacket) {
        guard config.codec == 1 else { return }
        guard config.parameterSets != currentParameterSets else { return }
        guard let format = Self.makeFormatDescription(config.parameterSets) else {
            NSLog("display: failed to create format description")
            return
        }
        // 設定が変わった＝ストリームが作り直された。古い絵は残さない。
        layer.flush()
        formatDescription = format
        currentParameterSets = config.parameterSets
    }

    private func display(_ frame: VideoFramePacket) {
        // 設定が届く前のフレームはデコードできない（Mac 側は必ず
        // videoConfig → キーフレームの順で送ってくる）。
        guard formatDescription != nil else { return }
        guard let sampleBuffer = makeSampleBuffer(frame.data) else { return }

        if layer.status == .failed || layer.requiresFlushToResumeDecoding {
            layer.flush()
        }
        layer.enqueue(sampleBuffer)

        frameCount += 1
        if let clockOffsetMs {
            let nowMs = Date().timeIntervalSince1970 * 1000
            // キャプチャ時刻（Mac の時計）を iPad の時計に直してから引く。
            let oneWay = nowMs - (frame.captureTimeMs - clockOffsetMs)
            let clamped = max(0, oneWay)
            if let ema = latencyEMAMs {
                latencyEMAMs = ema * 0.8 + clamped * 0.2
            } else {
                latencyEMAMs = clamped
            }
        }
    }

    private static func makeFormatDescription(
        _ parameterSets: [Data]
    ) -> CMVideoFormatDescription? {
        guard parameterSets.count >= 2 else { return nil }

        // CoreMedia にはポインタの配列で渡す必要があるため、
        // 各セットを安定したメモリへコピーしてから組み立てる。
        let buffers = parameterSets.map { [UInt8]($0) }
        let allocated = buffers.map { bytes -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
            pointer.initialize(from: bytes, count: bytes.count)
            return pointer
        }
        defer {
            for (pointer, bytes) in zip(allocated, buffers) {
                pointer.deinitialize(count: bytes.count)
                pointer.deallocate()
            }
        }

        var pointers = allocated.map { UnsafePointer($0) }
        var sizes = buffers.map(\.count)
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: pointers.count,
            parameterSetPointers: &pointers,
            parameterSetSizes: &sizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &format
        )
        guard status == noErr else { return nil }
        return format
    }

    /// AVCC のフレームデータを、レイヤーに渡せる CMSampleBuffer に包む。
    private func makeSampleBuffer(_ data: Data) -> CMSampleBuffer? {
        guard let formatDescription else { return nil }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        status = data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: data.count
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = data.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return nil }

        // タイムスタンプ同期はせず、届いたら即表示する（遅延最優先）。
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }

    // MARK: - 時計合わせと計測

    private func startPingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.timerFired()
        }
        timer.resume()
        pingTimer = timer
    }

    private func timerFired() {
        let nowMs = Date().timeIntervalSince1970 * 1000
        send(type: .ping, payload: PingPacket(clientTimeMs: nowMs).payload())

        let now = Date()
        let elapsed = now.timeIntervalSince(windowStart)
        let fps = elapsed > 0 ? Double(frameCount) / elapsed : 0
        frameCount = 0
        windowStart = now

        let latency = latencyEMAMs ?? -1
        // Mac 側のポップオーバーにも同じ値を出すために送り返す。
        send(type: .stats, payload: StatsPacket(latencyMs: latency, fps: fps).payload())
        onEvent?(.stats(latencyMs: latency, fps: fps))
    }

    private func updateClock(_ pong: PongPacket) {
        let nowMs = Date().timeIntervalSince1970 * 1000
        let rtt = nowMs - pong.clientTimeMs
        guard rtt >= 0 else { return }
        // 最小 RTT のサンプルが最も対称に近い＝時計差の推定が正確。
        if rtt < bestRTTMs {
            bestRTTMs = rtt
            clockOffsetMs = pong.serverTimeMs - (pong.clientTimeMs + nowMs) / 2
        }
    }

    // MARK: - 送信

    private func send(type: StreamPacket.PacketType, payload: Data) {
        guard let connection, connection.state == .ready else { return }
        connection.send(
            content: StreamPacket.frame(type: type, payload: payload),
            completion: .contentProcessed { _ in }
        )
    }
}
