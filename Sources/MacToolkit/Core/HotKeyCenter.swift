import AppKit
import Carbon.HIToolbox

/// グローバルホットキーの登録をまとめる。
///
/// Carbon の `RegisterEventHotKey` を使う。古い API だが現役で、
/// `NSEvent.addGlobalMonitorForEvents` や CGEventTap と違い
/// **「入力監視」権限が要らない**（キーを他アプリに渡さず消費もできる）。
/// 権限なしで動くことを優先してこちらを選んでいる。
///
/// Carbon のコールバックは C 関数なのでコンテキストを捕まえられない。
/// 発火した id を頼りにここのハンドラ表を引く。コールバックはメインの
/// ランループ上で呼ばれるため MainActor として扱ってよい。
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// 修飾キーの組み合わせ。Carbon の定数をそのまま使わずに包む。
    struct Modifiers: OptionSet {
        let rawValue: UInt32
        static let command = Modifiers(rawValue: UInt32(cmdKey))
        static let option = Modifiers(rawValue: UInt32(optionKey))
        static let control = Modifiers(rawValue: UInt32(controlKey))
        static let shift = Modifiers(rawValue: UInt32(shiftKey))
    }

    private struct Entry {
        let ref: EventHotKeyRef
        let handler: () -> Void
    }

    /// 発火 id → 登録内容。id は登録順の連番。
    private var entries: [UInt32: Entry] = [:]
    /// 名前（モジュール側の識別子）→ 発火 id。二重登録の解除に使う。
    private var idsByName: [String: UInt32] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    private init() {}

    /// 登録する。既に同じ名前で登録されていれば置き換える。
    ///
    /// 他アプリが同じキーを押さえている場合は登録に失敗するので、
    /// 呼び出し側が結果を見てユーザーに伝えられるよう Bool を返す。
    @discardableResult
    func register(
        name: String,
        keyCode: UInt32,
        modifiers: Modifiers,
        handler: @escaping () -> Void
    ) -> Bool {
        unregister(name: name)
        guard installEventHandlerIfNeeded() else { return false }

        let id = nextID
        nextID += 1

        // signature は 4 文字コード。他アプリと衝突しない任意の値でよい。
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers.rawValue,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            NSLog("[hotkey] failed to register \(name): OSStatus \(status)")
            return false
        }

        entries[id] = Entry(ref: ref, handler: handler)
        idsByName[name] = id
        return true
    }

    func unregister(name: String) {
        guard let id = idsByName.removeValue(forKey: name),
              let entry = entries.removeValue(forKey: id)
        else { return }
        // 登録したままプロセスに残すとキーが他アプリへ渡らなくなる。必ず解除する。
        UnregisterEventHotKey(entry.ref)
    }

    /// コールバックから呼ばれる。
    fileprivate func fire(id: UInt32) {
        entries[id]?.handler()
    }

    // MARK: - Carbon への橋渡し

    private static let signature: OSType = 0x4D_54_4B_54  // 'MTKT'

    /// ホットキー押下のディスパッチャを 1 度だけ入れる。
    private func installEventHandlerIfNeeded() -> Bool {
        guard eventHandler == nil else { return true }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyEventHandler,
            1,
            &spec,
            nil,
            &ref
        )
        guard status == noErr else {
            NSLog("[hotkey] failed to install event handler: OSStatus \(status)")
            return false
        }
        eventHandler = ref
        return true
    }
}

/// Carbon から呼ばれる C コールバック。メインのランループ上で呼ばれる。
private let hotKeyEventHandler: EventHandlerUPP = { _, event, _ in
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    MainActor.assumeIsolated {
        HotKeyCenter.shared.fire(id: hotKeyID.id)
    }
    return noErr
}
