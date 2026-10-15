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

/// Shows up in the Shortcuts app as "Set Current App" (iOS 16+). Put it in an "App > Is Opened"
/// automation: copies made from then on are labeled with that app. Runs without opening ClipPiP.
@available(iOS 16.0, *)
struct SetCurrentAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Current App"
    static var description = IntentDescription(
        "Tells ClipPiP which app is open, so the clips you copy there are labeled with it. Use it in an App > Is Opened automation.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "App name")
    var app: String

    static var parameterSummary: some ParameterSummary {
        Summary("Clips now come from \(\.$app)")
    }

    func perform() async throws -> some IntentResult {
        ClipOrigin.setCurrentApp(app)
        return .result()
    }
}

/// Shows up in the Shortcuts app as "Clear Current App" (iOS 16+). Put it in an "App > Is Closed"
/// automation with the same name as its "Set Current App" twin.
@available(iOS 16.0, *)
struct ClearCurrentAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Clear Current App"
    static var description = IntentDescription(
        "Tells ClipPiP that an app was closed. Use it in an App > Is Closed automation, with the same name as in Set Current App.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "App name")
    var app: String

    static var parameterSummary: some ParameterSummary {
        Summary("Clips no longer come from \(\.$app)")
    }

    func perform() async throws -> some IntentResult {
        ClipOrigin.clearCurrentApp(app)
        return .result()
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
