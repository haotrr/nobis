import Foundation
import FamilyDomain

/// Device-local preferences, deliberately excluded from business backups and cloud records.
public struct ReminderPreferences: Codable, Equatable, Sendable {
    public var enabled = true
    public var quietEnabled = false
    public var quietStart = 22 * 60
    public var quietEnd = 8 * 60
    public init() {}
    public func validate() throws {
        guard (0..<1440).contains(quietStart), (0..<1440).contains(quietEnd),
              !quietEnabled || quietStart != quietEnd else {
            throw NobisError.validation("静默开始与结束时间须不同；全天不接收请关闭此设备提醒。")
        }
    }
    public func adjusted(_ date: Date, deviceTimeZone: TimeZone) -> Date? {
        guard quietEnabled else { return date }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = deviceTimeZone
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let inside = quietStart < quietEnd ? minute >= quietStart && minute < quietEnd : minute >= quietStart || minute < quietEnd
        guard inside else { return date }
        // Calendar matching handles missing/repeated clock times without adding fixed 24-hour days.
        return calendar.nextDate(after: date, matching: DateComponents(hour: quietEnd / 60, minute: quietEnd % 60, second: 0), matchingPolicy: .nextTime, repeatedTimePolicy: .first)
    }
}

public struct PlannedReminder: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let originalDate: Date
    public let fireDate: Date
}

public enum ReminderPlanning {
    public static func plan(records: [Record], preferences: ReminderPreferences, now: Date = Date(), deviceTimeZone: TimeZone = .current) throws -> [PlannedReminder] {
        try preferences.validate()
        guard preferences.enabled else { return [] }
        var result: [PlannedReminder] = []
        for record in records where !record.deleted && !record.conflicted && record.body.status == .active && record.body.sharedDestination == nil {
            guard [.task, .subscription].contains(record.body.kind), let day = record.body.date else { continue }
            guard let timeZone = TimeZone(identifier: record.body.timeZone) else { throw NobisError.validation("提醒时区无效：\(record.body.title)") }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
            for offset in Set(record.body.kind == .subscription ? record.body.reminderDays : [0]) {
                let fireDay = day.addingDays(-offset)
                let start = calendar.date(from: DateComponents(year: fireDay.year, month: fireDay.month, day: fireDay.day))!
                guard let original = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: start),
                      let fire = preferences.adjusted(original, deviceTimeZone: deviceTimeZone), fire > now else { continue }
                result.append(PlannedReminder(id: "nobis:\(record.latest.spaceID):\(record.id):\(day):\(offset)", title: record.body.title,
                    body: record.body.kind == .subscription ? "续费待复核，预计日期 \(day)；不代表已扣款。" : "待办日期 \(day)。",
                    originalDate: original, fireDate: fire))
            }
        }
        return result.sorted { $0.fireDate == $1.fireDate ? $0.id < $1.id : $0.fireDate < $1.fireDate }
    }
}
