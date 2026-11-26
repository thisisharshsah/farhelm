import CompanionBoard
import SwiftUI

struct BoardFilters {
    var statuses: Set<WorkStatus> = []
    var priorities: Set<WorkPriority> = []
    var models: Set<ModelChoice?> = []

    var activeCount: Int {
        statuses.count + priorities.count + models.count
    }

    func matches(_ item: WorkItem) -> Bool {
        (statuses.isEmpty || statuses.contains(item.status))
            && (priorities.isEmpty || priorities.contains(item.priority))
            && (models.isEmpty || models.contains(item.assignment?.model))
    }
}

struct BoardFilterControl: View {
    let items: [WorkItem]
    @Binding var filters: BoardFilters
    @State private var isPresented = false

    private var modelOptions: [FilterOption<ModelChoice?>] {
        var seen: Set<ModelChoice> = []
        var options: [FilterOption<ModelChoice?>] = []
        for item in items {
            if let assignment = item.assignment, seen.insert(assignment.model).inserted {
                options.append(FilterOption(id: assignment.model, title: assignment.label))
            }
        }
        options.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if items.contains(where: { $0.assignment == nil }) || filters.models.contains(nil) {
            options.append(FilterOption(id: nil, title: "No model", symbol: "questionmark.circle"))
        }
        return options
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: Design.Space.xxs) {
                Label("Filters", systemImage: "line.3.horizontal.decrease")
                if filters.activeCount > 0 {
                    Text("\(filters.activeCount) active")
                        .textRole(.number, .secondary)
                }
            }
        }
        .glassButton(.glass)
        .popover(isPresented: $isPresented) {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.m) {
                    FilterChips("Status", options: WorkStatus.allCases.map {
                        FilterOption(id: $0, title: $0.title, symbol: $0.icon)
                    }, selection: $filters.statuses)
                    FilterChips("Priority", options: WorkPriority.allCases.reversed().map {
                        FilterOption(id: $0, title: $0.title, symbol: $0.icon)
                    }, selection: $filters.priorities)
                    FilterChips("Model", options: modelOptions, selection: $filters.models)
                }
                .padding(Design.Space.m)
            }
            .frame(width: 320)
            .frame(maxHeight: 420)
        }
    }
}