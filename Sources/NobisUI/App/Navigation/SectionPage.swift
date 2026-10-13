import SwiftUI
import FamilyDomain
import FamilyCore

enum SectionPage: String, CaseIterable, Identifiable {
    case overview = "今天", projects = "项目", documents = "笔记", records = "安排", ledger = "账本", settings = "设置"
    var id: String { rawValue }
    var icon: String { switch self { case .documents: "doc.text"; case .overview: "house"; case .projects: "square.stack.3d.up"; case .ledger: "creditcard"; case .records: "calendar"; case .settings: "slider.horizontal.3" } }
}
