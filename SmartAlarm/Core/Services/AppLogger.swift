import Foundation
import os

enum AppLogger {
    private static let subsystem = "com.danielxiao.SmartAlarm"

    static let planner = Logger(subsystem: subsystem, category: "planner")
    static let traffic = Logger(subsystem: subsystem, category: "traffic")
    static let alarm = Logger(subsystem: subsystem, category: "alarm")
    static let background = Logger(subsystem: subsystem, category: "background")
    static let calendar = Logger(subsystem: subsystem, category: "calendar")
}
