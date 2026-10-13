import SwiftUI
import FamilyDomain

/// Initials are a local fallback, not an Apple Account photo or proof of membership.
struct IdentityAvatar: View {
    let name: String
    let identity: String
    var avatarData: Data? = nil
    @ScaledMetric(relativeTo: .caption) private var diameter = 24.0
    private var initials: String {
        let words = name.split(whereSeparator: \.isWhitespace)
        if words.count > 1 { return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
        return String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
    }
    private var color: Color {
        let palette: [Color] = [.teal, .indigo, .brown, .purple, .blue, .orange]
        let index = identity.utf8.reduce(0) { ($0 * 31 + Int($1)) % palette.count }
        return palette[index]
    }
    var body: some View {
        Group {
            if let avatarData, let image = avatarImage(avatarData) { image.resizable().scaledToFill() }
            else { Text(initials.isEmpty ? "?" : initials).font(.caption.weight(.semibold)).foregroundStyle(.primary)
            .frame(width: diameter, height: diameter)
            .background(color.opacity(0.18), in: Circle())
            .overlay { Circle().strokeBorder(color.opacity(0.45), lineWidth: 1) }
            .accessibilityHidden(true) }
        }.frame(width: diameter, height: diameter).clipShape(Circle()).accessibilityHidden(true)
    }
}

struct MemberIdentityBadge: View {
    let name: String
    let identity: String
    var role: String? = nil
    var avatarData: Data? = nil
    var showsAvatar = false
    init(member: Member, role: String? = nil, showsAvatar: Bool = false) {
        self.showsAvatar = showsAvatar
        name = member.name; identity = member.id.uuidString; self.role = role; avatarData = member.avatarData
    }
    init(name: String, identity: String, role: String? = nil, avatarData: Data? = nil, showsAvatar: Bool = false) {
        self.showsAvatar = showsAvatar
        self.name = name; self.identity = identity; self.role = role; self.avatarData = avatarData
    }
    var body: some View {
        HStack(spacing: 7) {
            if showsAvatar { IdentityAvatar(name: name, identity: identity, avatarData: avatarData) }
            Text(name).font(.caption.weight(.medium)).lineLimit(2)
            if let role { Text(role).font(.caption).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .ignore).accessibilityLabel([role, name].compactMap { $0 }.joined(separator: "："))
    }
}

/// Ownership is the authorized space, never the record's latest editor or payer.
struct ResourceOwnership: View {
    let model: AppModel
    let spaceID: UUID
    var detailed = false
    private var space: Space? { model.spaces.first { $0.id == spaceID } }
    private var name: String {
        guard let space else { return "归属不可用" }
        if space.kind == .personal { return space.members.first { $0.id == space.ownerID }?.name ?? space.name }
        return space.name
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(name).font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    Image(systemName: space?.kind == .personal ? "lock" : "person.2").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                if detailed { Text(model.visibility(for: spaceID)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("归属：\(name)，\(model.visibility(for: spaceID))")
            .help("归属：\(name) · \(model.visibility(for: spaceID))")
    }
}

struct RecordCreator: View {
    let model: AppModel
    let record: Record
    var body: some View {
        if let first = (try? model.core?.history(record.id, spaceID: record.latest.spaceID))?.last {
            let member = model.space(for: record)?.members.first { $0.id == first.actorID }
            MemberIdentityBadge(name: member?.name ?? "历史成员 · \(first.actorID.uuidString.prefix(4))", identity: first.actorID.uuidString, role: "创建者", avatarData: member?.avatarData)
        }
    }
}

/// Financial ownership remains distinct from where a resource is stored.
struct FinancialOwnershipBadge: View {
    let model: AppModel
    let record: Record
    var body: some View {
        if let owner = record.body.financialOwner {
            if owner.kind == .joint {
                Text("共同持有").font(.caption)
            } else if let id = owner.memberID {
                MemberIdentityBadge(name: model.space(for: record)?.members.first { $0.id == id }?.name ?? "历史成员 · \(id.uuidString.prefix(4))", identity: id.uuidString, avatarData: model.space(for: record)?.members.first { $0.id == id }?.avatarData)
            } else { Text("归属待确认").font(.caption).foregroundStyle(.secondary) }
        } else { Label("原整体范围／待确认", systemImage: "questionmark.circle").font(.caption).foregroundStyle(.secondary) }
    }
}

#if os(macOS)
import AppKit
private func avatarImage(_ data: Data) -> Image? { NSImage(data: data).map { Image(nsImage: $0) } }
#else
import UIKit
private func avatarImage(_ data: Data) -> Image? { UIImage(data: data).map { Image(uiImage: $0) } }
#endif
