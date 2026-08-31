import Foundation
import VideoToolbox
import CoreMedia

/// VideoToolbox で H.264 にハードウェアエンコードする。
///
/// スレッド安全ではない。DisplayStreamer の専用キュー上でのみ使うこと
/// （生成・encode・invalidate すべて同じキューから呼ぶ前提なのでロックを持たない）。
final class VideoEncoder {
    enum EncoderError: LocalizedError {
        case sessionCreationFailed(OSStatus)
        case configurationFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .sessionCreationFailed(let status):
                return "エンコーダを初期化できません（\(status)）"
            case .configurationFailed(let status):
                return "エンコーダを設定できません（\(status)）"
            }
        }
    }

    /// エンコード済みの 1 フレーム。data は AVCC（4 バイト長プレフィックス）形式。
    struct EncodedFrame {
        var data: Data
        var isKeyFrame: Bool
        /// [SPS, PPS]。フォーマットが変わると中身も変わる。
        var parameterSets: [Data]
    }

    private var session: VTCompressionSession?

    /// エンコードセッションを作る。既存のセッションがあれば破棄して作り直す。
    func prepare(width: Int, height: Int, fps: Int, bitrate: Int) throws {
        invalidate()

        // 低遅延レートコントロール（Apple Silicon で利用可）をまず試し、
        // 使えない環境では通常のセッションにフォールバックする。
        let lowLatencySpec = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue as Any
        ] as CFDictionary

        var created: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: lowLatencySpec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        if status != noErr || created == nil {
            NSLog("iPadDisplay: low-latency encoder unavailable (%d), falling back", status)
            status = VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(width),
                height: Int32(height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &created
            )
        }
        guard status == noErr, let session = created else {
            throw EncoderError.sessionCreationFailed(status)
        }

        // 配信用途なのでリアルタイム優先・並べ替えなし（B フレーム禁止）。
        try set(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        try set(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel)
        try set(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        try set(session, kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        try set(session, kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        // キーフレームは 2 秒に 1 回。接続直後は別途強制キーフレームを打つ。
        try set(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * 2) as CFNumber)
        try set(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    /// 1 フレームをエンコードする。結果はエンコーダ内部のキューから
    /// completion で返るので、受け側で自分のキューに戻すこと。
    /// 失敗（またはドロップ）時は nil を渡す。
    func encode(
        _ imageBuffer: CVImageBuffer,
        presentationTimeStamp: CMTime,
        forceKeyFrame: Bool,
        completion: @escaping (EncodedFrame?) -> Void
    ) {
        guard let session else {
            completion(nil)
            return
        }

        var frameProperties: CFDictionary?
        if forceKeyFrame {
            frameProperties = [
                kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any
            ] as CFDictionary
        }

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { status, infoFlags, sampleBuffer in
            guard status == noErr,
                  !infoFlags.contains(.frameDropped),
                  let sampleBuffer
            else {
                completion(nil)
                return
            }
            completion(Self.convert(sampleBuffer))
        }
        if status != noErr {
            NSLog("iPadDisplay: VTCompressionSessionEncodeFrame failed: %d", status)
            completion(nil)
        }
    }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    deinit {
        invalidate()
    }

    // MARK: - 変換

    /// CMSampleBuffer から AVCC データとパラメータセットを取り出す。
    private static func convert(_ sampleBuffer: CMSampleBuffer) -> EncodedFrame? {
        // キーフレーム判定: notSync 属性が「無い」ことがキーフレーム。
        var isKeyFrame = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[CFString: Any]],
           let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyFrame = !notSync
        }

        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let parameterSets = extractParameterSets(from: format),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return nil }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        let copyStatus = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                blockBuffer, atOffset: 0, dataLength: length, destination: base
            )
        }
        guard copyStatus == noErr else { return nil }

        return EncodedFrame(data: data, isKeyFrame: isKeyFrame, parameterSets: parameterSets)
    }

    /// フォーマット記述から [SPS, PPS] を取り出す。
    private static func extractParameterSets(from format: CMFormatDescription) -> [Data]? {
        // まず個数と NAL 長プレフィックスの長さを確認する。
        var count = 0
        var nalUnitHeaderLength: Int32 = 0
        var status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        // ワイヤ形式は 4 バイト長プレフィックス前提。それ以外は扱わない。
        guard status == noErr, count >= 2, nalUnitHeaderLength == 4 else { return nil }

        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer, size > 0 else { return nil }
            sets.append(Data(bytes: pointer, count: size))
        }
        return sets
    }

    private func set(
        _ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef
    ) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        // 一部のプロパティ（低遅延モードでの MaxKeyFrameInterval など）は
        // 環境によって未対応がありうる。致命的ではないのでログに留める。
        if status == kVTPropertyNotSupportedErr {
            NSLog("iPadDisplay: encoder property %@ not supported", key as String)
            return
        }
        guard status == noErr else {
            throw EncoderError.configurationFailed(status)
        }
    }
}
