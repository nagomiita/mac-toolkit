import Foundation
import Network

/// Bonjour で自分を広告し、iPad からの TCP 接続を受け付けて
/// パケットを送受信する。同時接続は 1 台のみ（後勝ち）。
///
/// スレッド安全ではない。DisplayStreamer の専用キュー上でのみ使い、
/// コールバックもすべて同じキューで呼ばれる。
final class StreamServer {
    enum ServerError: LocalizedError {
        case listenerCreationFailed

        var errorDescription: String? {
            "配信の待ち受けを開始できません"
        }
    }

    /// すべて init 時に渡したキュー上で呼ばれる。
    var onClientConnected: (() -> Void)?
    var onClientDisconnected: (() -> Void)?
    var onPacket: ((StreamPacket.PacketType, Data) -> Void)?
    var onListenerFailed: ((String) -> Void)?

    private let queue: DispatchQueue
    private var listener: NWListener?
    private var connection: NWConnection?
    /// 送信済みで完了コールバックが返っていないパケット数。背圧の判定に使う。
    private var inFlightSends = 0

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    var hasClient: Bool {
        connection?.state == .ready
    }

    /// 送信が滞っているか。これが真の間は新しいフレームを積まない
    /// （TCP のバッファに映像を溜めると遅延が雪だるま式に増える）。
    var isBacklogged: Bool {
        inFlightSends >= 4
    }

    // MARK: - 待ち受け

    func start(serviceName: String) throws {
        stop()

        // 映像のような小刻みな送信では Nagle が遅延源になるため無効化する。
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol
            as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw ServerError.listenerCreationFailed
        }
        listener.service = NWListener.Service(
            name: serviceName, type: StreamPacket.bonjourServiceType
        )

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                NSLog("iPadDisplay: listener failed: %@", "\(error)")
                self.onListenerFailed?("待ち受けが停止しました")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] newConnection in
            self?.accept(newConnection)
        }

        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        dropClient()
    }

    func dropClient() {
        connection?.cancel()
        connection = nil
        inFlightSends = 0
    }

    // MARK: - 接続

    private func accept(_ newConnection: NWConnection) {
        // 先に差し替えてから古い接続を切る。逆順にすると、古い接続の
        // .cancelled ハンドラ（c === connection のガード付き）が
        // 新しい接続を巻き添えに「切断」を通知してしまう。
        let old = connection
        connection = newConnection
        inFlightSends = 0
        old?.cancel()

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection,
                  newConnection === self.connection
            else { return }
            switch state {
            case .ready:
                self.onClientConnected?()
                self.receiveHeader(on: newConnection)
            case .failed, .cancelled:
                self.connection = nil
                self.inFlightSends = 0
                self.onClientDisconnected?()
            default:
                break
            }
        }
        newConnection.start(queue: queue)
    }

    // MARK: - 受信

    private func receiveHeader(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: StreamPacket.headerLength,
            maximumLength: StreamPacket.headerLength
        ) { [weak self] data, _, isComplete, error in
            guard let self, connection === self.connection else { return }
            guard error == nil, !isComplete,
                  let data, data.count == StreamPacket.headerLength
            else {
                self.dropCurrent(connection)
                return
            }

            var reader = PacketReader(data)
            guard let rawType = reader.readUInt8(),
                  let length = reader.readUInt32(),
                  Int(length) <= StreamPacket.maxPayloadLength
            else {
                // ヘッダが壊れている＝以降のストリーム位置が信用できない。切る。
                NSLog("iPadDisplay: corrupt packet header, dropping client")
                self.dropCurrent(connection)
                return
            }

            if length == 0 {
                self.dispatch(rawType: rawType, payload: Data())
                self.receiveHeader(on: connection)
            } else {
                self.receivePayload(on: connection, rawType: rawType, length: Int(length))
            }
        }
    }

    private func receivePayload(on connection: NWConnection, rawType: UInt8, length: Int) {
        connection.receive(
            minimumIncompleteLength: length, maximumLength: length
        ) { [weak self] data, _, isComplete, error in
            guard let self, connection === self.connection else { return }
            guard error == nil, !isComplete, let data, data.count == length else {
                self.dropCurrent(connection)
                return
            }
            self.dispatch(rawType: rawType, payload: data)
            self.receiveHeader(on: connection)
        }
    }

    private func dispatch(rawType: UInt8, payload: Data) {
        // 未知のタイプは将来の拡張とみなして黙って読み飛ばす。
        guard let type = StreamPacket.PacketType(rawValue: rawType) else { return }
        onPacket?(type, payload)
    }

    private func dropCurrent(_ connection: NWConnection) {
        guard connection === self.connection else { return }
        self.connection = nil
        inFlightSends = 0
        connection.cancel()
        onClientDisconnected?()
    }

    // MARK: - 送信

    func send(type: StreamPacket.PacketType, payload: Data) {
        guard let connection, connection.state == .ready else { return }
        inFlightSends += 1
        let framed = StreamPacket.frame(type: type, payload: payload)
        connection.send(
            content: framed,
            completion: .contentProcessed { [weak self, weak connection] error in
                guard let self else { return }
                if connection === self.connection {
                    self.inFlightSends = max(0, self.inFlightSends - 1)
                }
                if error != nil, let connection, connection === self.connection {
                    self.dropCurrent(connection)
                }
            }
        )
    }
}
