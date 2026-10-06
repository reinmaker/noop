#if os(iOS)
import SwiftUI
import StrandDesign

/// WHOOP-style "My Memory": what the Coach knows about the wearer. Items come from the Coach itself
/// (a "Memory:" line when the wearer shares something lasting) or are added here. Everything stays on
/// the phone and rides along with the Coach's context.
struct WhoopCoachMemoryView: View {
    @ObservedObject private var store = CoachMemoryStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var tab: CoachMemory.Category? = nil
    @State private var newTitle = ""
    @State private var newDetail = ""
    @State private var newCategory: CoachMemory.Category = .health

    private var shown: [CoachMemory] {
        guard let tab else { return store.items }
        return store.items.filter { $0.category == tab }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    Text("Shape your Yoop experience.")
                        .font(WhoopStyle.sectionTitle)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Help your Coach understand you better.")
                        .font(WhoopStyle.body)
                        .foregroundStyle(StrandPalette.textSecondary)

                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Text("YOUR NAME").font(WhoopStyle.smallLabel).foregroundStyle(StrandPalette.textSecondary)
                        TextField("First name", text: $store.firstName)
                            .textContentType(.givenName)
                            .font(WhoopStyle.body)
                            .padding(NoopMetrics.space3)
                            .background(RoundedRectangle(cornerRadius: 10).fill(WhoopStyle.ringTrack))
                    }
                    .padding(WhoopStyle.compactPadding)
                    .whoopCard()

                    shareCard

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: NoopMetrics.space2) {
                            tabChip(nil, String(localized: "Timeline"))
                            ForEach(CoachMemory.Category.allCases) { c in
                                tabChip(c, c.rawValue)
                            }
                        }
                    }

                    if shown.isEmpty {
                        Text("Nothing here yet. Tell your Coach about an injury, a goal or an event and it will remember.")
                            .font(WhoopStyle.body)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    ForEach(shown) { memory in
                        memoryCard(memory)
                    }
                }
                .padding(NoopMetrics.space4)
            }
            .background(WhoopStyle.sheetFill.ignoresSafeArea())
            .navigationTitle(Text("My Memory"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var shareCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Label("Share something new", systemImage: "sparkles")
                .font(WhoopStyle.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Picker("Type", selection: $newCategory) {
                ForEach(CoachMemory.Category.allCases) { c in Text(c.rawValue).tag(c) }
            }
            .pickerStyle(.menu)
            TextField("Title, e.g. Left calf strain", text: $newTitle)
                .font(WhoopStyle.body)
                .padding(NoopMetrics.space3)
                .background(RoundedRectangle(cornerRadius: 10).fill(WhoopStyle.ringTrack))
            TextField("Details", text: $newDetail, axis: .vertical)
                .font(WhoopStyle.body)
                .lineLimit(1...4)
                .padding(NoopMetrics.space3)
                .background(RoundedRectangle(cornerRadius: 10).fill(WhoopStyle.ringTrack))
            Button {
                let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                let detail = newDetail.trimmingCharacters(in: .whitespacesAndNewlines)
                store.add(CoachMemory(category: newCategory, title: title, detail: detail.isEmpty ? title : detail))
                newTitle = ""
                newDetail = ""
            } label: {
                WhoopActionButtonLabel(title: String(localized: "SAVE TO MEMORY"), systemImage: "plus")
            }
            .buttonStyle(.plain)
            .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(WhoopStyle.compactPadding)
        .whoopCard()
    }

    private func tabChip(_ category: CoachMemory.Category?, _ title: String) -> some View {
        let selected = tab == category
        return Button { tab = category } label: {
            Text(title)
                .font(WhoopStyle.detail)
                .foregroundStyle(selected ? WhoopStyle.chipText : StrandPalette.textPrimary)
                .padding(.horizontal, NoopMetrics.space3)
                .padding(.vertical, NoopMetrics.space2)
                .background(Capsule().fill(selected ? WhoopStyle.chipFill : WhoopStyle.ringTrack))
        }
        .buttonStyle(.plain)
    }

    private func memoryCard(_ memory: CoachMemory) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .top) {
                Text(memory.title)
                    .font(WhoopStyle.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Menu {
                    Button {
                        store.setActive(memory.id, !memory.active)
                    } label: {
                        Label(memory.active ? "Mark as past" : "Mark as active",
                              systemImage: memory.active ? "checkmark.circle" : "arrow.uturn.left")
                    }
                    Button(role: .destructive) {
                        store.remove(memory.id)
                    } label: {
                        Label("Forget", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(WhoopStyle.icon)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 32, height: 32)
                }
            }
            Text(memory.detail)
                .font(WhoopStyle.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: NoopMetrics.space2) {
                Text(memory.active ? "Active" : "Past")
                    .font(WhoopStyle.caption)
                    .foregroundStyle(memory.active ? WhoopStyle.reviewAccent : StrandPalette.textTertiary)
                    .padding(.horizontal, NoopMetrics.space2)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(WhoopStyle.ringTrack))
                Text(memory.category.rawValue)
                    .font(WhoopStyle.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.horizontal, NoopMetrics.space2)
                    .padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(WhoopStyle.cardStroke, lineWidth: 1))
            }
            Text("Since \(memory.start.formatted(date: .abbreviated, time: .omitted))")
                .font(WhoopStyle.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(WhoopStyle.compactPadding)
        .whoopCard()
    }
}
#endif
