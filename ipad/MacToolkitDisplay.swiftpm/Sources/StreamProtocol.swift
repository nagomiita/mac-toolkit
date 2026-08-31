import Foundation

/// Mac → iPad 画面配信のワイヤプロトコル定義。
///
/// **重要**: このファイルは Mac 側
/// `Sources/MacToolkit/Modules/iPadDisplay/StreamProtocol.swift` と iPad 側
/// `ipad/MacToolkitDisplay.swiftpm/Sources/StreamProtocol.swift` の 2 箇所にあり、
/// 完全に同一の内容を保つこと（別パッケージのためターゲット共有ができない）。
/// 変更するときは必ず両方を同時に書き換える。
///
/// フレーミングは「ヘッダ 5 バイト（type 1 + payload 長 4、ビッグエンディアン）＋
/// ペイロード」の繰り返し。TCP 上に流す。
enum StreamPacket {
    /// Bonjour のサービスタイプ。Mac が広告し、iPad が検索する。
    static let bonjourServiceType = "_mactoolkit-display._tcp"

    /// ヘッダ長（type 1 バイト + payload 長 4 バイト）。
    static let headerLength = 5

    /// ペイロード長の上限。壊れたヘッダを読んだときの暴走を防ぐ。
    /// 4K Retina のキーフレームでも数 MB に収まる。
    static let maxPayloadLength = 16 * 1024 * 1024

    enum PacketType: UInt8 {
        /// iPad → Mac。接続直後に端末名（UTF-8）を送る。
        case hello = 1
        /// Mac → iPad。コーデック設定（SPS/PPS など）。キーフレームの前に送る。
        case videoConfig = 2
        /// Mac → iPad。エンコード済み映像 1 フレーム。
        case videoFrame = 3
        /// iPad → Mac。時計合わせと遅延計測用。
        case ping = 4
        /// Mac → iPad。ping への応答。
        case pong = 5
        /// iPad → Mac。受信側で計測した遅延と FPS。
        case stats = 6
    }

    /// ヘッダ + ペイロードに組み立てる。
    static func frame(type: PacketType, payload: Data) -> Data {
        var writer = PacketWriter()
        writer.append(type.rawValue)
        writer.append(UInt32(payload.count))
        writer.append(payload)
        return writer.data
    }
}

// MARK: - パケット本体

/// H.264 のデコードに必要な設定。パラメータセットが変わるたびに送り直す。
struct VideoConfigPacket: Sendable, Equatable {
    /// 現状 1 (= H.264) のみ。HEVC 拡張のために持たせている。
    var codec: UInt8 = 1
    var width: Int
    var height: Int
    /// H.264 なら [SPS, PPS]。NAL ユニット長プレフィックスは 4 バイト固定。
    var parameterSets: [Data]

    func payload() -> Data {
        var writer = PacketWriter()
        writer.append(codec)
        writer.append(UInt16(width))
        writer.append(UInt16(height))
        writer.append(UInt8(parameterSets.count))
        for set in parameterSets {
            writer.append(UInt16(set.count))
            writer.append(set)
        }
        return writer.data
    }

    init(width: Int, height: Int, parameterSets: [Data]) {
        self.width = width
        self.height = height
        self.parameterSets = parameterSets
    }

    init?(payload: Data) {
        var reader = PacketReader(payload)
        guard let codec = reader.readUInt8(),
              let width = reader.readUInt16(),
              let height = reader.readUInt16(),
              let count = reader.readUInt8()
        else { return nil }
        var sets: [Data] = []
        for _ in 0..<count {
            guard let length = reader.readUInt16(),
                  let set = reader.readData(Int(length))
            else { return nil }
            sets.append(set)
        }
        self.codec = codec
        self.width = Int(width)
        self.height = Int(height)
        self.parameterSets = sets
    }
}

/// エンコード済み映像 1 フレーム。データは AVCC（4 バイト長プレフィックス）形式。
struct VideoFramePacket: Sendable {
    /// Mac 側の壁時計でのキャプチャ時刻（Unix エポックからのミリ秒）。
    var captureTimeMs: Double
    var isKeyFrame: Bool
    var data: Data

    func payload() -> Data {
        var writer = PacketWriter()
        writer.append(captureTimeMs)
        writer.append(UInt8(isKeyFrame ? 1 : 0))
        writer.append(data)
        return writer.data
    }

    init(captureTimeMs: Double, isKeyFrame: Bool, data: Data) {
        self.captureTimeMs = captureTimeMs
        self.isKeyFrame = isKeyFrame
        self.data = data
    }

    init?(payload: Data) {
        var reader = PacketReader(payload)
        guard let time = reader.readDouble(),
              let flags = reader.readUInt8()
        else { return nil }
        captureTimeMs = time
        isKeyFrame = flags & 1 != 0
        data = reader.readRemaining()
    }
}

/// 時計合わせ。iPad が自分の時刻を入れて送る。
struct PingPacket: Sendable {
    /// iPad 側の壁時計（ミリ秒）。
    var clientTimeMs: Double

    func payload() -> Data {
        var writer = PacketWriter()
        writer.append(clientTimeMs)
        return writer.data
    }

    init(clientTimeMs: Double) {
        self.clientTimeMs = clientTimeMs
    }

    init?(payload: Data) {
        var reader = PacketReader(payload)
        guard let time = reader.readDouble() else { return nil }
        clientTimeMs = time
    }
}

/// ping への応答。Mac が受信した瞬間の自分の時刻を足して返す。
struct PongPacket: Sendable {
    /// ping に入っていた iPad 側の時刻をそのまま返す。
    var clientTimeMs: Double
    /// Mac 側の壁時計（ミリ秒）。
    var serverTimeMs: Double

    func payload() -> Data {
        var writer = PacketWriter()
        writer.append(clientTimeMs)
        writer.append(serverTimeMs)
        return writer.data
    }

    init(clientTimeMs: Double, serverTimeMs: Double) {
        self.clientTimeMs = clientTimeMs
        self.serverTimeMs = serverTimeMs
    }

    init?(payload: Data) {
        var reader = PacketReader(payload)
        guard let client = reader.readDouble(),
              let server = reader.readDouble()
        else { return nil }
        clientTimeMs = client
        serverTimeMs = server
    }
}

/// iPad 側で計測した受信品質。1 秒ごとに送られてくる。
struct StatsPacket: Sendable {
    /// キャプチャから表示手前までの遅延。計測できていない間は負値。
    var latencyMs: Double
    var fps: Double

    func payload() -> Data {
        var writer = PacketWriter()
        writer.append(Float(latencyMs))
        writer.append(Float(fps))
        return writer.data
    }

    init(latencyMs: Double, fps: Double) {
        self.latencyMs = latencyMs
        self.fps = fps
    }

    init?(payload: Data) {
        var reader = PacketReader(payload)
        guard let latency = reader.readFloat(),
              let fps = reader.readFloat()
        else { return nil }
        latencyMs = Double(latency)
        self.fps = Double(fps)
    }
}

// MARK: - バイト列の読み書き

/// ビッグエンディアン固定のバイナリライタ。
struct PacketWriter {
    private(set) var data = Data()

    mutating func append(_ value: UInt8) {
        data.append(value)
    }

    mutating func append(_ value: UInt16) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: Double) {
        withUnsafeBytes(of: value.bitPattern.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: Float) {
        withUnsafeBytes(of: value.bitPattern.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(_ bytes: Data) {
        data.append(bytes)
    }
}

/// ビッグエンディアン固定のバイナリリーダ。範囲外は nil を返す（クラッシュさせない）。
struct PacketReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    mutating func readUInt8() -> UInt8? {
        guard let bytes = readData(1) else { return nil }
        return bytes[bytes.startIndex]
    }

    mutating func readUInt16() -> UInt16? {
        readInteger(UInt16.self)
    }

    mutating func readUInt32() -> UInt32? {
        readInteger(UInt32.self)
    }

    mutating func readDouble() -> Double? {
        guard let bits = readInteger(UInt64.self) else { return nil }
        return Double(bitPattern: bits)
    }

    mutating func readFloat() -> Float? {
        guard let bits = readInteger(UInt32.self) else { return nil }
        return Float(bitPattern: bits)
    }

    mutating func readData(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else { return nil }
        // Data のスライスは元の index を引き継ぐため、必ず startIndex 起点で切る。
        let start = data.startIndex + offset
        offset += count
        return data.subdata(in: start..<(start + count))
    }

    mutating func readRemaining() -> Data {
        readData(data.count - offset) ?? Data()
    }

    private mutating func readInteger<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        guard let bytes = readData(MemoryLayout<T>.size) else { return nil }
        var value: T = 0
        _ = withUnsafeMutableBytes(of: &value) { bytes.copyBytes(to: $0) }
        return T(bigEndian: value)
    }
}
