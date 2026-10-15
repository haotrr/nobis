import SwiftUI
import FamilyDomain
import FamilyCore

struct AppNavigationView: View {
    let model: AppModel
    @Binding var page: SectionPage
    @Binding var showingSettings: Bool
    @Binding var inspectorUsesSheet: Bool

    var body: some View {
        #if os(macOS)
        GeometryReader { geometry in
        HSplitView {
            NavigationSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Image("BrandLogo", bundle: .main).resizable().scaledToFit()
                            .frame(width: 38, height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Nobis").font(.system(.title2, design: .serif)).fontWeight(.semibold)
                            Text("我们的共同生活").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(20)
                    List(selection: $page) {
                        Section("生活") {
                            ForEach(SectionPage.allCases.filter { $0 != .settings }) { item in
                                Label(item.rawValue, systemImage: item.icon).tag(item).padding(.vertical, 4)
                            }
                        }
                        Section {
                            Label("设置", systemImage: SectionPage.settings.icon).tag(SectionPage.settings).padding(.vertical, 4)
                        }
                    }.listStyle(.sidebar).listItemTint(.monochrome).scrollContentBackground(.hidden)
                    VStack(alignment: .leading, spacing: 8) {
                        spacePicker
                        Label(model.saveStatus, systemImage: model.cloud.enabled ? "icloud" : "internaldrive").font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .nobisGlass(radius: 16).padding(12)
                }.background { LifeBackground() }
                    .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            } detail: {
                NavigationStack { content }
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 520)
            if !inspectorUsesSheet, model.recordPanel.recordID != nil {
                RecordInspector(model: model)
                    .frame(minWidth: 360, idealWidth: 420, maxWidth: 480)
            }
        }
        .onAppear { inspectorUsesSheet = geometry.size.width < 1000 }
        .onChange(of: geometry.size.width) { _, width in
            if model.recordPanel.editingRecord == nil { inspectorUsesSheet = width < 1000 }
        }
        .onChange(of: model.recordPanel.editingRecord == nil) { _, finished in
            if finished { inspectorUsesSheet = geometry.size.width < 1000 }
        }
        .sheet(isPresented: Binding(
            get: { inspectorUsesSheet && model.recordPanel.recordID != nil },
            set: { if !$0 && inspectorUsesSheet { model.recordPanel.close() } }
        )) {
            RecordInspector(model: model)
                .frame(minWidth: 360, idealWidth: 440, minHeight: 500)
                .interactiveDismissDisabled(model.recordPanel.hasChanges)
        }
        }
        .frame(minWidth: model.recordPanel.editingRecord != nil && !inspectorUsesSheet ? 1000 : 720, minHeight: 520)
        #else
        TabView(selection: $page) {
            ForEach(SectionPage.allCases.filter { $0 != .settings }) { item in
                NavigationStack {
                    pageView(item).navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            if item == .overview {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button { showingSettings = true } label: { Label("设置", systemImage: "gearshape") }.tint(Color.primary)
                                }
                            }
                        }
                }.tabItem { Label(item.rawValue, systemImage: item.icon) }.tag(item)
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView(model: model)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingSettings = false } } }
            }
        }
        #endif
    }
    private var spacePicker: some View {
        Group { if let id = model.selectedSpaceID { ResourceOwnership(model: model, spaceID: id, detailed: true) } }
    }
    private var content: some View { pageView(page) }
    @ViewBuilder private func pageView(_ page: SectionPage) -> some View {
        switch page {
        case .overview: TodayWorkspace(model: model)
        case .projects: RecordsView(model: model, fixedKind: .project)
        case .ledger: LedgerWorkspace(model: model)
        case .records: ScheduleWorkspace(model: model)
        case .documents: DocumentsView(model: model)
        case .settings: SettingsView(model: model)
        }
    }
}
