import Foundation
import Observation
import SwiftUI
import UserNotifications

/// ふたを閉じてもスリープしない状態（`pmset` の SleepDisabled）を
/// メニューバーから切り替える。
///
/// この設定はオンのまま持ち歩くとロックされず、盗難時にパスワードなしで
/// 中身に入られてしまう。そのため単なるトグルではなく、
/// 「今オンであることが見える」（メニューバーの警告アイコン）ことと
/// 「消し忘れても自動で戻る」（自動オフのタイマー）ことを主眼にする。
///
/// 設定変更の公開通知は無いので、クリップボードと同様に `tick()` で
/// 読み直す（読み取りは軽い）。ターミナルなど外部での変更にも表示が追従する。
@MainActor
@Observable
final class LidSleepModule: ToolModule {
    let id = "lidsleep"
    let title = "スリープ抑止"
    let systemImage = "cup.and.saucer"

    /// 現在の SleepDisabled。読めないときは nil（N/A 扱い）。
    private(set) var sleepDisabled: Bool?
    /// sudoers ルールが未導入で、切り替えに初回セットアップが要る状態。
    private(set) var needsSetup = false
    /// 切り替え・セットアップの実行中。二重操作を防ぐ。
    private(set) var isBusy = false
    private(set) var message: String?

    /// オンを最初に検知した時刻。自動オフの起点。
    ///
    /// アプリを再起動しても消し忘れを戻せるよう UserDefaults に持つ。
    /// 外部（ターミナルなど）でオンにされた場合も検知時点から数え始める。
    private(set) var enabledAt: Date?

    /// 自動オフを最後に実行した時刻。黙って状態が変わったことを
    /// 後から確認できるようにポップオーバーへ残す。
    private(set) var lastAutoOffAt: Date?

    /// 自動でオフに戻すまでの分数。0 は自動オフなし。
    var autoOffMinutes: Int {
        didSet {
            UserDefaults.standard.set(autoOffMinutes, forKey: Self.autoOffKey)
        }
    }

    private static let autoOffKey = "lidsleep.autoOffMinutes"
    private static let enabledAtKey = "lidsleep.enabledAt"
    private static let lastAutoOffKey = "lidsleep.lastAutoOffAt"

    init() {
        if UserDefaults.standard.object(forKey: Self.autoOffKey) != nil {
            autoOffMinutes = UserDefaults.standard.integer(forKey: Self.autoOffKey)
        } else {
            // 消し忘れが主リスクなので、既定は 1 時間で自動的に戻す。
            autoOffMinutes = 60
        }
        let saved = UserDefaults.standard.double(forKey: Self.enabledAtKey)
        enabledAt = saved > 0 ? Date(timeIntervalSinceReferenceDate: saved) : nil
        let lastOff = UserDefaults.standard.double(forKey: Self.lastAutoOffKey)
        lastAutoOffAt = lastOff > 0 ? Date(timeIntervalSinceReferenceDate: lastOff) : nil
    }

    func start() {
        sleepDisabled = LidSleepControl.readSleepDisabled()
        refreshSetupState()
    }

    func tick() {
        sleepDisabled = LidSleepControl.readSleepDisabled()
        guard let sleepDisabled else { return }

        if !sleepDisabled {
            // 外部でオフにされた場合も含め、起点を消して次回に備える。
            if enabledAt != nil { setEnabledAt(nil) }
            return
        }

        // 外部でオンにされた場合はここで検知して起点を作る。
        if enabledAt == nil { setEnabledAt(Date()) }

        // needsSetup の間は試みない（失敗する sudo を毎秒叩き続けないため）。
        if let deadline = autoOffDeadline, Date() >= deadline, !isBusy, !needsSetup {
            autoOff()
        }
    }

    // MARK: - 操作

    func setSleepDisabled(_ on: Bool) {
        guard !isBusy, sleepDisabled != on else { return }
        isBusy = true
        message = nil
        Task { @MainActor in
            defer { isBusy = false }
            if await performSet(on) {
                // 手動でオンにし直したら前回の自動オフの表示は役目を終える。
                if on { setLastAutoOff(nil) }
                return
            }
            // 失敗の典型は sudoers ルール未導入（または解除された）。
            message = "切り替えられませんでした"
            refreshSetupState()
        }
    }

    /// 自動オフ。手動と違い、いつ黙って切り替えたかを記録し通知センターにも残す。
    private func autoOff() {
        guard !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            if await performSet(false) {
                setLastAutoOff(Date())
                LidSleepNotifier.notifyAutoOff()
            } else {
                // 再試行のループは tick 側の needsSetup ガードが止める。
                refreshSetupState()
            }
        }
    }

    private func performSet(_ on: Bool) async -> Bool {
        let ok = await Task.detached { LidSleepControl.setSleepDisabled(on) }.value
        if ok {
            sleepDisabled = on
            setEnabledAt(on ? Date() : nil)
        }
        return ok
    }

    /// NOPASSWD ルールの導入。管理者パスワードのダイアログが 1 回だけ出る。
    func runSetup() {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        Task { @MainActor in
            defer { isBusy = false }
            let result = await Task.detached { LidSleepControl.installSudoersRule() }.value
            switch result {
            case .done:
                needsSetup = false
                // セットアップ中に期限が切れていても直後に発火させない。
                // カウントダウンはこの時点から取り直す。
                if sleepDisabled == true { setEnabledAt(Date()) }
            case .canceled:
                break
            case .failed:
                message = "セットアップに失敗しました"
            }
        }
    }

    private func refreshSetupState() {
        Task { @MainActor in
            let ok = await Task.detached { LidSleepControl.canToggleWithoutPassword() }.value
            needsSetup = !ok
        }
    }

    private func setEnabledAt(_ date: Date?) {
        enabledAt = date
        if let date {
            UserDefaults.standard.set(
                date.timeIntervalSinceReferenceDate, forKey: Self.enabledAtKey
            )
        } else {
            UserDefaults.standard.removeObject(forKey: Self.enabledAtKey)
        }
    }

    private func setLastAutoOff(_ date: Date?) {
        lastAutoOffAt = date
        if let date {
            UserDefaults.standard.set(
                date.timeIntervalSinceReferenceDate, forKey: Self.lastAutoOffKey
            )
        } else {
            UserDefaults.standard.removeObject(forKey: Self.lastAutoOffKey)
        }
    }

    // MARK: - 表示用

    /// 自動オフの期限。自動オフなし・オフ状態のときは nil。
    var autoOffDeadline: Date? {
        guard autoOffMinutes > 0, let enabledAt else { return nil }
        return enabledAt.addingTimeInterval(TimeInterval(autoOffMinutes * 60))
    }

    /// 「42 分」「1 時間 12 分」。期限が無い・過ぎているときは nil。
    var autoOffRemainingText: String? {
        guard sleepDisabled == true, let deadline = autoOffDeadline else { return nil }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        let minutes = Int((remaining / 60).rounded(.up))
        if minutes >= 60 {
            return "\(minutes / 60) 時間 \(minutes % 60) 分"
        }
        return "\(minutes) 分"
    }

    /// 「17:26」。今日でなければ「8/30 17:26」。
    var lastAutoOffText: String? {
        guard let lastAutoOffAt else { return nil }
        let time = lastAutoOffAt.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(lastAutoOffAt) { return time }
        return "\(lastAutoOffAt.formatted(.dateTime.month().day())) \(time)"
    }

    // MARK: - View

    /// オンの間だけメニューバーに警告として出す。平常時は幅を取らない（録画と同じ）。
    func statusItemView() -> AnyView? {
        guard sleepDisabled == true else { return nil }
        return AnyView(
            Image(systemName: "cup.and.saucer.fill")
                .foregroundStyle(.orange)
                .menuBarValueStyle()
        )
    }

    func detailView() -> AnyView {
        AnyView(LidSleepSectionView(module: self))
    }
}

// MARK: - 通知

/// 自動オフを通知センターに残す。
///
/// ふたが閉じている間に切り替わるとバナーは見えないので、目的は
/// 「後から確認できる記録」。承認は provisional（ダイアログを出さず
/// 通知センターにのみ静かに届く）で取り、権限の要求画面を増やさない。
/// `swift run`（非バンドル）では UNUserNotificationCenter が使えないため何もしない。
private enum LidSleepNotifier {
    static func notifyAutoOff() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .provisional]
        ) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "スリープ抑止を自動でオフにしました"
            content.body = "ふたを閉じるとスリープします"
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: "lidsleep.autooff", content: content, trigger: nil
                )
            )
        }
    }
}

// MARK: - ポップオーバー

private struct LidSleepSectionView: View {
    @Bindable var module: LidSleepModule

    var body: some View {
        ModuleSection(
            title: module.title,
            systemImage: module.systemImage,
            summary: module.sleepDisabled == true ? "オン" : nil
        ) {
            Toggle("ふたを閉じてもスリープしない", isOn: Binding(
                get: { module.sleepDisabled == true },
                set: { module.setSleepDisabled($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(module.isBusy || module.needsSetup || module.sleepDisabled == nil)

            if module.sleepDisabled == nil {
                Text("状態を取得できません").metricCaptionStyle()
            } else if module.sleepDisabled == true {
                // オンのまま持ち歩く事故がこの機能の一番のリスク。目立たせる。
                Label("ロックされないため、持ち歩く前にオフにする",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(.orange)

                if let remaining = module.autoOffRemainingText {
                    MetricRow(label: "自動オフまで", value: remaining)
                } else {
                    Text("自動オフなし（手動で戻すまでオンのまま）")
                        .metricCaptionStyle()
                }
            } else {
                Text("オンの間はふたを閉じても処理が続く")
                    .metricCaptionStyle()
                if let last = module.lastAutoOffText {
                    // 黙って切り替わった事実を後から追えるようにする。
                    Text("前回 \(last) に自動でオフ")
                        .metricCaptionStyle()
                }
            }

            autoOffPicker

            if let message = module.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if module.needsSetup {
                Text("切り替えには初回セットアップが必要（管理者パスワードを 1 回使う）")
                    .metricCaptionStyle()
                Button("セットアップ…") {
                    module.runSetup()
                }
                .buttonStyle(.accessoryBar)
                .disabled(module.isBusy)
            }
        }
    }

    private var autoOffPicker: some View {
        HStack {
            Text("自動でオフ").metricLabelStyle()
            Spacer(minLength: 12)
            Picker("自動でオフ", selection: $module.autoOffMinutes) {
                Text("しない").tag(0)
                Text("30 分後").tag(30)
                Text("1 時間後").tag(60)
                Text("3 時間後").tag(180)
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}
