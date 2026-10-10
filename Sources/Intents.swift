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

@available(iOS 16.0, *)
struct ClipPiPShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartPiPIntent(),
                    phrases: ["Start PiP in \(.applicationName)"],
                    shortTitle: "Start PiP",
                    systemImageName: "pip.enter")
    }
}
