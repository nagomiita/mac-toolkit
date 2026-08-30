import Foundation

/// ふたを閉じてもスリープしない設定（`pmset` の SleepDisabled）を読み書きする。
///
/// 読み取りは IOKit のプライベート関数 `IOPMCopySystemPowerSettings` を
/// dlsym で解決して使う（`pmset -g` の「System-wide power settings」と同じ値。
/// root 不要で軽い）。
///
/// 書き込みは root 権限が要るため `sudo -n pmset` に委ねる。パスワードなしで
/// 切り替えられるのは `/etc/sudoers.d/mac-toolkit` に NOPASSWD ルールがある間だけで、
/// ルールは「pmset -a disablesleep 1 / 0」の 2 コマンド完全一致に絞る
/// （worst case でも他プロセスがこの設定を切り替えられるだけに収める）。
/// ルールの導入・解除だけは管理者パスワードのダイアログ（osascript）を経由する。
///
/// Process を同期で待つ関数群なので、呼び出し側は `Task.detached` から使うこと。
enum LidSleepControl {
    // MARK: - 読み取り（プライベート API）

    private typealias CopySettingsFn = @convention(c) () -> Unmanaged<CFDictionary>?

    /// `IOPMCopySystemPowerSettings` を 1 度だけ引く。無ければ nil。
    private static let copySettings: CopySettingsFn? = {
        guard
            let handle = dlopen(
                "/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW
            ),
            let pointer = dlsym(handle, "IOPMCopySystemPowerSettings")
        else { return nil }
        return unsafeBitCast(pointer, to: CopySettingsFn.self)
    }()

    /// 現在の SleepDisabled。シンボルが引けない・読めないときは nil（N/A 扱い）。
    static func readSleepDisabled() -> Bool? {
        guard let copySettings else { return nil }
        guard
            let settings = copySettings()?.takeRetainedValue() as? [String: Any]
        else { return nil }
        // キーが無い＝一度も設定されていない Mac。オフとして扱う。
        guard let value = settings["SleepDisabled"] else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    // MARK: - 書き込み（sudo 経由）

    /// sudoers ルールが入っていて、パスワードなしで切り替えられるか。
    /// `sudo -n -l <コマンド>` は許可されていれば 0 で終了する。
    static func canToggleWithoutPassword() -> Bool {
        run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"])
    }

    /// SleepDisabled を切り替える。sudoers ルールの完全一致を保つため
    /// 引数の形をここで固定する。
    static func setSleepDisabled(_ on: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"])
    }

    // MARK: - セットアップ（管理者パスワードのダイアログ）

    enum SetupResult: Sendable {
        case done
        /// ユーザーがダイアログを閉じた。エラー表示はしない。
        case canceled
        case failed
    }

    /// NOPASSWD ルールを `/etc/sudoers.d/mac-toolkit` に書く。
    /// 壊れた sudoers は sudo 全体を止めるので、必ず visudo -c で検証してから置く。
    static func installSudoersRule() -> SetupResult {
        let user = NSUserName()
        // シェルの単一引用符の中に埋め込むため、記号を含むユーザー名は扱わない。
        let allowed = user.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-"
        }
        guard !user.isEmpty, allowed else { return .failed }

        let line = "\(user) ALL=(root) NOPASSWD: "
            + "/usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
        let shell = "set -e; "
            + "f=$(/usr/bin/mktemp /private/tmp/mac-toolkit-sudoers.XXXXXX); "
            + "echo '\(line)' > $f; "
            + "/usr/sbin/visudo -c -q -f $f; "
            + "/usr/bin/install -m 0440 -o root -g wheel $f /etc/sudoers.d/mac-toolkit; "
            + "/bin/rm -f $f"
        return runWithAdminPrivileges(
            shell,
            prompt: "MacToolkit がスリープ抑止をパスワードなしで切り替える許可を設定します。"
        )
    }

    /// ルールを削除して初回セットアップ前の状態に戻す。
    static func removeSudoersRule() -> SetupResult {
        runWithAdminPrivileges(
            "/bin/rm -f /etc/sudoers.d/mac-toolkit",
            prompt: "MacToolkit がスリープ抑止のセットアップを解除します。"
        )
    }

    // MARK: - プロセス実行

    /// 同期実行して正常終了なら true。出力は使わないので捨てる。
    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// `do shell script ... with administrator privileges` で root として実行する。
    /// shell と prompt には二重引用符・バックスラッシュを含めないこと
    /// （AppleScript の文字列リテラルへそのまま埋め込むため）。
    private static func runWithAdminPrivileges(
        _ shell: String, prompt: String
    ) -> SetupResult {
        let script = "do shell script \"\(shell)\" "
            + "with administrator privileges with prompt \"\(prompt)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return .failed
        }
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 0 { return .done }
        // キャンセルは AppleScript のエラー番号 -128 で区別する。
        let text = String(data: stderrData, encoding: .utf8) ?? ""
        return text.contains("-128") ? .canceled : .failed
    }
}
