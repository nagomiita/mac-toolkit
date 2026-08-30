import Carbon.HIToolbox

/// macOS の入力ソース（IME）を Text Input Source API で切り替える。
///
/// 入力ソース ID は OS バージョンや利用中の IME（Kotoeri / Google 日本語入力 /
/// ATOK）で変わるため、既知の ID の候補リストで探し、無ければ属性（ASCII 対応の
/// キーボードレイアウト、言語が ja）で探す。それでも見つからなければ何もしない。
///
/// TIS API はメインスレッドから呼ぶ前提なので MainActor に置く。
@MainActor
enum InputSourceSwitcher {

    /// ABC（英数）へ切り替える。切り替えられたら true。
    static func selectABC() -> Bool {
        let candidates = [
            "com.apple.keylayout.ABC",
            "com.apple.keylayout.US",
            "com.apple.keylayout.USExtended",
        ]
        if selectFirst(matchingIDs: candidates) { return true }
        // 候補に無ければ、有効な ASCII 対応のキーボードレイアウトで代用する。
        return selectFirst { source in
            boolProperty(source, kTISPropertyInputSourceIsASCIICapable)
                && stringProperty(source, kTISPropertyInputSourceType)
                    == (kTISTypeKeyboardLayout as String)
        }
    }

    /// 日本語入力へ切り替える。切り替えられたら true。
    static func selectJapanese() -> Bool {
        let candidates = [
            "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",  // macOS 13 以降
            "com.apple.inputmethod.Kotoeri.Japanese",  // それ以前
        ]
        if selectFirst(matchingIDs: candidates) { return true }
        // かな入力や Google 日本語入力・ATOK は言語で拾う。
        // 50音パレット（TISTypeCharacterPalette）も langs=[ja] なので、
        // キーボード系カテゴリに限定しないと誤ってパレットを開いてしまう。
        return selectFirst { source in
            languages(of: source).contains("ja")
                && stringProperty(source, kTISPropertyInputSourceCategory)
                    == (kTISCategoryKeyboardInputSource as String)
        }
    }

    // MARK: - 探索と選択

    /// 有効（入力メニューに出ている）かつ選択可能な入力ソース。
    private static func selectableSources() -> [TISInputSource] {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue(),
              let sources = list as? [TISInputSource]
        else { return [] }
        return sources.filter { boolProperty($0, kTISPropertyInputSourceIsSelectCapable) }
    }

    /// ID の候補を先頭から順に探し、最初に選択できたところで止める。
    private static func selectFirst(matchingIDs ids: [String]) -> Bool {
        let sources = selectableSources()
        for id in ids {
            guard let source = sources.first(
                where: { stringProperty($0, kTISPropertyInputSourceID) == id }
            ) else { continue }
            if select(source) { return true }
        }
        return false
    }

    private static func selectFirst(where predicate: (TISInputSource) -> Bool) -> Bool {
        for source in selectableSources() where predicate(source) {
            if select(source) { return true }
        }
        return false
    }

    private static func select(_ source: TISInputSource) -> Bool {
        TISSelectInputSource(source) == noErr
    }

    // MARK: - プロパティの読み出し

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }

    private static func languages(of source: TISInputSource) -> [String] {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
        else { return [] }
        let array = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue()
        return (array as? [String]) ?? []
    }
}
