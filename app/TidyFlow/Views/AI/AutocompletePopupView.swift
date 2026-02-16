import SwiftUI

struct AutocompletePopupView: View {
    @ObservedObject var autocomplete: AutocompleteState
    var onSelect: (AutocompleteItem) -> Void

    private var popupBackgroundStyle: AnyShapeStyle {
        #if os(iOS)
        return AnyShapeStyle(Color.black.opacity(0.92))
        #else
        return AnyShapeStyle(.ultraThinMaterial)
        #endif
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(autocomplete.items.enumerated()), id: \.element.id) { index, item in
                        AutocompleteRow(
                            item: item,
                            isSelected: index == autocomplete.selectedIndex,
                            mode: autocomplete.mode
                        )
                        .id(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelect(item)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 400)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: autocomplete.selectedIndex) { _, newIndex in
                guard newIndex >= 0, newIndex < autocomplete.items.count else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(autocomplete.items[newIndex].id, anchor: .center)
                }
            }
        }
        .background(popupBackgroundStyle)
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: -4)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }
}

// MARK: - 单行

private struct AutocompleteRow: View {
    let item: AutocompleteItem
    let isSelected: Bool
    let mode: AutocompleteMode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.icon)
                .font(.system(size: 12))
                .foregroundColor(isSelected ? .white : .white.opacity(0.78))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(isSelected ? .white.opacity(0.86) : .white.opacity(0.68))
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor : Color.clear)
        .cornerRadius(4)
        .padding(.horizontal, 4)
    }

    private var displayTitle: String {
        switch mode {
        case .slashCommand:
            return "/\(item.value)"
        default:
            return item.title
        }
    }
}
