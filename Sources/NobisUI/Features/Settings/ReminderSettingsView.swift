import SwiftUI
import FamilyCore

struct ReminderSettingsView: View {
    let model: AppModel
    @State private var error: String?
    private var preferences: ReminderPreferences { model.reminderPreferences }
    private var device: String {
        #if os(macOS)
        "这台 Mac"
        #else
        "这台 iPhone / iPad"
        #endif
    }
    var body: some View {
        LifeDetail {
            LifeSection(title: "接收设备", icon: "bell") {
                Toggle("在\(device) 接收提醒", isOn: binding(\.enabled))
                Text("设置仅保存在此设备。只想在手机接收时，请在 Mac 关闭、在手机开启；不会远程修改其他设备。").font(.caption).foregroundStyle(.secondary)
                Text(model.notificationStatus).font(.caption)
                if preferences.enabled && !model.isReminderPreviewOnly {
                    Button("检查系统权限并更新提醒") { Task { await model.updateNotifications(requestPermission: true) } }
                }
            }
            LifeSection(title: "静默时段", icon: "moon") {
                Toggle("启用静默时段", isOn: binding(\.quietEnabled))
                if preferences.quietEnabled {
                    DatePicker("开始", selection: timeBinding(\.quietStart), displayedComponents: .hourAndMinute)
                    DatePicker("结束", selection: timeBinding(\.quietEnd), displayedComponents: .hourAndMinute)
                }
                Text("按此设备时区（\(TimeZone.current.identifier)）每天生效，可跨午夜。落入静默时段的提醒延后到结束时刻；结束时刻允许提醒。开始和结束不能相同。").font(.caption).foregroundStyle(.secondary)
            }
            if let error = error ?? model.reminderSettingsError { InlineIssue(message: error) }
            LifeSection(title: "接下来会提醒", icon: "clock") {
                Text("待办与订阅按记录时区的 09:00 计算，再应用此设备静默时段。这里只预览计划，系统权限、休眠与后台限制仍会影响实际送达。").font(.caption).foregroundStyle(.secondary)
                if model.isReminderPreviewOnly { Text("隔离验证模式：可保存本地设置，不请求权限、不发送系统通知。").font(.caption) }
                preview
            }
        }.navigationTitle("日常提醒")
        .task { await model.updateNotifications(requestPermission: false) }
    }
    @ViewBuilder private var preview: some View {
        let result = Result { try model.reminderPreview() }
        switch result {
        case .failure(let failure): InlineIssue(message: failure.localizedDescription)
        case .success(let items):
            if !preferences.enabled { Text("此设备已关闭提醒，待办和订阅内容不受影响。") }
            else if items.isEmpty { Text("暂无未来提醒。添加有日期的待办或订阅后，会显示在这里。") }
            else {
                Text("共 \(items.count) 条，系统最多安排最近 60 条，打开应用时更新。以下显示最近 10 条。").font(.caption)
                ForEach(Array(items.prefix(10))) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline)
                        Text(item.fireDate.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month().day().hour().minute()))
                        if item.fireDate != item.originalDate { Text("因静默时段延后").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
    private func save(_ value: ReminderPreferences, requestPermission: Bool = false) {
        do {
            try model.saveReminderPreferences(value); error = nil
            Task { await model.updateNotifications(requestPermission: requestPermission) }
        } catch { self.error = error.localizedDescription }
    }
    private func binding(_ path: WritableKeyPath<ReminderPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { preferences[keyPath: path] }, set: { value in
            var updated = preferences; updated[keyPath: path] = value
            save(updated, requestPermission: path == \.enabled && value)
        })
    }
    private func timeBinding(_ path: WritableKeyPath<ReminderPreferences, Int>) -> Binding<Date> {
        Binding(get: {
            let minute = preferences[keyPath: path]
            return Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 15, hour: minute / 60, minute: minute % 60))!
        }, set: { date in
            var updated = preferences
            updated[keyPath: path] = Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date)
            save(updated)
        })
    }
}
