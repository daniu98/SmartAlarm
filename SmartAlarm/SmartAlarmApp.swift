import SwiftUI

@main
struct SmartAlarmApp: App {
    @State private var appEnvironment: AppEnvironment

    init() {
        let environment = AppEnvironment()
        // BGTaskScheduler requires every identifier to be registered before the app finishes
        // launching, so this cannot move into `.task` or `onAppear`.
        environment.background.registerTasks()
        _appEnvironment = State(initialValue: environment)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appEnvironment)
        }
        .modelContainer(appEnvironment.modelContainer)
    }
}
