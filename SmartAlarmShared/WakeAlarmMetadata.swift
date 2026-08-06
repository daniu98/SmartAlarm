import AlarmKit
import Foundation

/// Travels with the AlarmKit alarm into the Live Activity, so the Lock Screen and Dynamic
/// Island can show *why* this is the wake time without reaching back into the app's store.
/// This is what lets the widget extension stay free of an App Group.
struct WakeAlarmMetadata: AlarmMetadata {
    var leaveByDate: Date
    var arrivalDeadline: Date
    var driveMinutes: Int
    var condition: TrafficCondition
    var destinationLabel: String

    init(
        leaveByDate: Date,
        arrivalDeadline: Date,
        driveMinutes: Int,
        condition: TrafficCondition,
        destinationLabel: String
    ) {
        self.leaveByDate = leaveByDate
        self.arrivalDeadline = arrivalDeadline
        self.driveMinutes = driveMinutes
        self.condition = condition
        self.destinationLabel = destinationLabel
    }
}
