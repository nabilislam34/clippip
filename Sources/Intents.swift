import AppIntents

/// Shows up in the Shortcuts app as "Start PiP" (iOS 16+). Opens the app and starts PiP.
@available(iOS 16.0, *)
struct StartPiPIntent: AppIntent {
    static var title: LocalizedStringResource = "Start PiP"
    static var description = IntentDescription("Starts the ClipPiP background clipboard monitor.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PiPManager.shared.requestStart()
        return .result()
    }
}

/// Shows up in the Shortcuts app as "Toggle PC Clips" (iOS 16+). Runs without opening the app:
/// it tells the PC server to stop or resume sending PC copies to the phone.
@available(iOS 16.0, *)
struct TogglePCClipsIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle PC Clips"
    static var description = IntentDescription("Turns receiving clips from the PC on or off.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        var base = (UserDefaults.standard.string(forKey: "server") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let token = (UserDefaults.standard.string(forKey: "token") ?? "")
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard !base.isEmpty, let url = URL(string: base + "/pc/receive?on=toggle&token=" + token) else {
            return .result(dialog: "Set the PC server in ClipPiP first")
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if let enabled = obj?["enabled"] as? Bool {
                let dialog: IntentDialog = enabled ? "PC clips ON" : "PC clips OFF"
                return .result(dialog: dialog)
            }
            return .result(dialog: "The PC server gave an unexpected answer")
        } catch {
            return .result(dialog: "The PC server did not answer")
        }
    }
}

@available(iOS 16.0, *)
struct ClipPiPShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartPiPIntent(),
                    phrases: ["Start PiP in \(.applicationName)"],
                    shortTitle: "Start PiP",
                    systemImageName: "pip.enter")
        AppShortcut(intent: TogglePCClipsIntent(),
                    phrases: ["Toggle PC clips in \(.applicationName)"],
                    shortTitle: "Toggle PC Clips",
                    systemImageName: "desktopcomputer")
    }
}
