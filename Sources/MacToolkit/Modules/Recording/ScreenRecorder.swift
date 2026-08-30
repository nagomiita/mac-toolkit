import AVFoundation
import AppKit
import ScreenCaptureKit

/// 画面とシステム音声を録画して .mov に書き出す。
///
/// `screencapture -v` を使わないのは、あれがマイク入力しか録れないため。
/// 会議相手の声（＝システム音声）を入れるには ScreenCaptureKit の
/// `capturesAudio` が要る。仮想オーディオデバイスは不要。
///
/// SCStream のコールバックは専用のシリアルキュー上で呼ばれる。
/// writer 周りの可変状態は全て `queue` の上でだけ触るので、
/// ロックを持たずに `@unchecked Sendable` にしている。
/// この約束が破れると壊れた .mov ができるため、
/// 外から触れる API は `start` / `stop` の 2 つだけに絞っている。
final class ScreenRecorder: NSObject, @unchecked Sendable {
    enum RecorderError: LocalizedError {
        case noPermission
        case displayNotFound
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noPermission: "画面収録の権限が必要です"
            case .displayNotFound: "録画するディスプレイが見つかりません"
            case .writerFailed(let detail): "書き出せません（\(detail)）"
            }
        }
    }

    /// 音声・映像のサンプルを扱う唯一のキュー。
    private let queue = DispatchQueue(label: "com.nagomiita.mac-toolkit.recorder")

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    /// システム音声（会議相手の声、再生中の動画など）。
    private var systemAudioInput: AVAssetWriterInput?
    /// 自分のマイク。macOS 15 以降のみ。
    private var micInput: AVAssetWriterInput?

    /// 最初の映像フレームでセッションを開始したか。
    /// 音声だけ先に来ることがあるので、開始前の音声は捨てる。
    private var sessionStarted = false
    /// 停止処理に入ったか。停止後に来たサンプルを弾く。
    private var finishing = false
    private var outputURL: URL?

    /// ストリーム側の異常でと録画が落ちたときに呼ばれる。
    private var onUnexpectedStop: (@Sendable (Error) -> Void)?

    // MARK: - 開始

    /// 録画を始める。戻り値は書き出し先。
    ///
    /// - Parameters:
    ///   - screen: 録画するスクリーン。
    ///   - capturesMicrophone: マイクも録るか。macOS 14 では無視される。
    ///   - onUnexpectedStop: ストリームが自分から止まったときの通知。
    func start(
        screen: NSScreen,
        capturesMicrophone: Bool,
        onUnexpectedStop: @escaping @Sendable (Error) -> Void
    ) async throws -> URL {
        guard CGPreflightScreenCaptureAccess() else { throw RecorderError.noPermission }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let displayID = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == displayID })
        else { throw RecorderError.displayNotFound }

        let url = Self.makeOutputURL()
        // Retina の実ピクセルで録ると 3000px 超になりファイルが膨らむ。
        // ポイント寸法（＝見た目どおりの大きさ）で十分に読める。
        // H.264 は偶数の縦横しか受け付けないので切り下げる。
        let width = display.width & ~1
        let height = display.height & ~1

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // 何をクリックしたか分かるようカーソルは写す（撮影と違い操作の記録が目的）。
        configuration.showsCursor = true
        // フレームを取りこぼしても落とさないよう少し余裕を持たせる。
        configuration.queueDepth = 6
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // 自分の声がスピーカー経由で二重に入らないようにする。
        configuration.excludesCurrentProcessAudio = true

        var recordsMicrophone = false
        if capturesMicrophone, #available(macOS 15.0, *) {
            configuration.captureMicrophone = true
            recordsMicrophone = true
        }

        try setUpWriter(url: url, width: width, height: height, recordsMicrophone: recordsMicrophone)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        if recordsMicrophone, #available(macOS 15.0, *) {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }

        queue.sync { self.onUnexpectedStop = onUnexpectedStop }

        do {
            try await stream.startCapture()
        } catch {
            // 開始に失敗したら writer を残さない。次回の start が汚れる。
            await tearDown()
            throw error
        }

        self.stream = stream
        return url
    }

    /// AVAssetWriter と各トラックを用意する。
    private func setUpWriter(
        url: URL, width: Int, height: Int, recordsMicrophone: Bool
    ) throws {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw RecorderError.writerFailed(error.localizedDescription)
        }

        let video = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    // 画面録画は動きが少ないのでこの程度で足りる。
                    AVVideoAverageBitRateKey: 6_000_000,
                    AVVideoMaxKeyFrameIntervalKey: 60,
                ],
            ]
        )
        // ライブ入力なので、届いたサンプルをその場で受けられる状態にしておく。
        video.expectsMediaDataInRealTime = true

        let systemAudio = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)
        systemAudio.expectsMediaDataInRealTime = true

        var mic: AVAssetWriterInput?
        if recordsMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)
            input.expectsMediaDataInRealTime = true
            mic = input
        }

        for input in [video, systemAudio, mic].compactMap({ $0 }) {
            guard writer.canAdd(input) else {
                throw RecorderError.writerFailed("トラックを追加できません")
            }
            writer.add(input)
        }

        guard writer.startWriting() else {
            throw RecorderError.writerFailed(
                writer.error?.localizedDescription ?? "不明"
            )
        }

        queue.sync {
            self.writer = writer
            self.videoInput = video
            self.systemAudioInput = systemAudio
            self.micInput = mic
            self.sessionStarted = false
            self.finishing = false
            self.outputURL = url
        }
    }

    private static let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128_000,
    ]

    /// `~/Movies/MacToolkit/画面収録 2026-08-09 14.03.22.mov`
    private static func makeOutputURL() -> URL {
        let directory = FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacToolkit", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        let formatter = DateFormatter()
        // ファイル名なので、環境の暦や言語に左右されない固定の書式にする。
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return directory
            .appendingPathComponent("画面収録 \(formatter.string(from: Date())).mov")
    }

    // MARK: - 停止

    /// 録画を止めてファイルを閉じる。戻り値は書き出せたファイル。
    ///
    /// ここを途中で投げ出すと再生できない .mov が残るので、
    /// 失敗しても最後まで通してから nil を返す。
    func stop() async -> URL? {
        guard let stream else { return nil }
        self.stream = nil

        try? await stream.stopCapture()

        let url = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            queue.async {
                self.finishing = true
                guard let writer = self.writer else {
                    continuation.resume(returning: nil)
                    return
                }
                // 1 フレームも来ていない（＝セッション未開始）なら中身が無い。
                guard self.sessionStarted else {
                    writer.cancelWriting()
                    continuation.resume(returning: nil)
                    return
                }

                for input in [self.videoInput, self.systemAudioInput, self.micInput]
                    .compactMap({ $0 }) {
                    input.markAsFinished()
                }

                let url = self.outputURL
                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume(returning: url)
                    } else {
                        NSLog("[recorder] finishWriting failed: \(String(describing: writer.error))")
                        continuation.resume(returning: nil)
                    }
                }
            }
        }

        await tearDown()
        return url
    }

    /// 参照を落とす。stop からも、開始失敗時からも呼ぶ。
    private func tearDown() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.writer = nil
                self.videoInput = nil
                self.systemAudioInput = nil
                self.micInput = nil
                self.onUnexpectedStop = nil
                self.sessionStarted = false
                self.finishing = false
                self.outputURL = nil
                continuation.resume()
            }
        }
    }
}

// MARK: - サンプルの受け取り

extension ScreenRecorder: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        // このコールバックは `queue` 上で呼ばれる（addStreamOutput でそう指定した）。
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finishing, let writer, writer.status == .writing else { return }
        guard sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }

        switch type {
        case .screen:
            // 画面に変化が無いフレームは中身が空で届く。書くと壊れる。
            guard isCompleteFrame(sampleBuffer) else { return }

            if !sessionStarted {
                // 最初の映像フレームを時刻の原点にする。
                writer.startSession(
                    atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                )
                sessionStarted = true
            }
            append(sampleBuffer, to: videoInput)

        case .audio:
            // 映像より先に来た音声は原点が決まっていないので捨てる。
            guard sessionStarted else { return }
            append(sampleBuffer, to: systemAudioInput)

        default:
            // .microphone（macOS 15+）。case で書くと macOS 14 でビルドが通らない。
            guard sessionStarted else { return }
            append(sampleBuffer, to: micInput)
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
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

extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[recorder] stream stopped: \(error)")
        queue.async {
            self.onUnexpectedStop?(error)
        }
    }
}
