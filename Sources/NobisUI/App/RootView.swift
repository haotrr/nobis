import SwiftUI
import FamilyDomain
import FamilyCore

public struct NobisRootView: View {
    @State private var model: AppModel
    @State private var page: SectionPage = .overview
    @State private var showingSettings = false
    @State private var inspectorUsesSheet = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    public init(model: AppModel) { _model = State(initialValue: model) }
    public var body: some View {
        Group {
            if model.setupRequired { OnboardingView(model: model) }
            else if !model.ready {
                StartupRecoveryView(model: model)
            } else {
                AppNavigationView(model: model, page: $page,
                                  showingSettings: $showingSettings,
                                  inspectorUsesSheet: $inspectorUsesSheet)
            }
        }
        .id(model.accessEpoch)
        .sheet(isPresented: Binding(get: { model.cloud.invitation != nil }, set: { if !$0 { model.cloud.invitation = nil } })) { FamilyInvitationView(model: model) }
        .tint(NobisTheme.accent)
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("知道了", role: .cancel) { model.error = nil } } message: { Text(model.error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            refreshCalendar()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            refreshCalendar()
        }
        .onChange(of: page) { _, _ in model.recordPanel.close() }
        .onChange(of: model.selectedSpaceID) { _, _ in model.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refresh(); Task { if model.cloud.enabled { await model.cloud.connect() } } } }
    }
    private func refreshCalendar() {
        model.refresh()
    }
}
