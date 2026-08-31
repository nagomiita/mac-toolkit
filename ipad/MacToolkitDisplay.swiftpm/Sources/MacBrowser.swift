import Foundation
import Network
import Observation

/// Bonjour で配信中の Mac を探す。
@MainActor
@Observable
final class MacBrowser {
    /// 見つかった Mac 1 台分。
    struct Endpoint: Identifiable, Hashable {
        /// サービス名（＝Mac 本体の名前）。同名は同一とみなす。
        var id: String { name }
        let name: String
        let endpoint: NWEndpoint
    }

    private(set) var macs: [Endpoint] = []
    private var browser: NWBrowser?

    func start() {
        stop()
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: StreamPacket.bonjourServiceType, domain: nil),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Endpoint? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return Endpoint(name: name, endpoint: result.endpoint)
            }
            .sorted { $0.name < $1.name }
            Task { @MainActor [weak self] in
                self?.macs = found
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            // 失敗したら一覧を空に戻す。次の start でやり直す。
            if case .failed = state {
                Task { @MainActor [weak self] in
                    self?.macs = []
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        macs = []
    }
}
