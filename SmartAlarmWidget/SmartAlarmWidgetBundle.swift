import SwiftUI
import WidgetKit

@main
struct SmartAlarmWidgetBundle: WidgetBundle {
    var body: some Widget {
        WakeAlarmLiveActivity()
        WakeTimeWidget()
    }
}
