import SwiftUI

// MARK: - 图标选择器

struct IconPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedIcon: String
    
    // 内置 SF Symbol 图标
    private let builtInIcons = [
        "terminal",
        "terminal.fill",
        "apple.terminal",
        "apple.terminal.fill",
        "chevron.left.forwardslash.chevron.right",
        "cursorarrow.rays",
        "sparkles",
        "brain",
        "brain.head.profile",
        "cpu",
        "server.rack",
        "network",
        "externaldrive",
        "doc.text",
        "folder",
        "gear",
        "wrench.and.screwdriver",
        "hammer",
        "ant",
        "ladybug",
        "play.circle",
        "bolt",
        "wand.and.stars"
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题
            HStack {
                Text("settings.iconPicker.title".localized)
                    .font(.headline)
                Spacer()
                Button("common.done".localized) { dismiss() }
            }
            .padding()
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 内置图标
                    VStack(alignment: .leading, spacing: 8) {
                        Text("settings.iconPicker.system".localized)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 8), count: 8), spacing: 8) {
                            ForEach(builtInIcons, id: \.self) { icon in
                                iconButton(icon: icon)
                            }
                        }
                    }
                    
                    Divider()
                    
                    // 品牌图标
                    VStack(alignment: .leading, spacing: 8) {
                        Text("settings.iconPicker.brand".localized)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 8), count: 8), spacing: 8) {
                            ForEach(BrandIcon.allCases, id: \.rawValue) { brand in
                                brandIconButton(brand: brand)
                            }
                        }
                    }
                    
                }
                .padding()
            }
        }
        .frame(width: 450, height: 400)
    }
    
    private func iconButton(icon: String) -> some View {
        Button(action: {
            selectedIcon = icon
            dismiss()
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedIcon == icon
                          ? Color.accentColor.opacity(0.2)
                          : Color.secondary.opacity(0.12))
                    .frame(width: 40, height: 40)
                
                Image(systemName: icon)
                    .font(.system(size: 18))
            }
        }
        .buttonStyle(.plain)
    }
    
    private func brandIconButton(brand: BrandIcon) -> some View {
        Button(action: {
            selectedIcon = "brand:\(brand.rawValue)"
            dismiss()
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedIcon == "brand:\(brand.rawValue)"
                          ? Color.accentColor.opacity(0.2)
                          : Color.secondary.opacity(0.12))
                    .frame(width: 40, height: 40)
                
                Image(brand.assetName)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
            }
        }
        .buttonStyle(.plain)
        .help(brand.displayName)
    }
    
}

// MARK: - 命令图标视图

struct CommandIconView: View {
    let iconName: String
    let size: CGFloat
    
    var body: some View {
        Group {
            if iconName.hasPrefix("brand:") {
                // 品牌图标
                let brandName = String(iconName.dropFirst(6))
                if let brand = BrandIcon(rawValue: brandName) {
                    Image(brand.assetName)
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                } else {
                    fallbackIcon
                }
            } else if iconName.hasPrefix("custom:") {
                // 自定义图标
                let filename = String(iconName.dropFirst(7))
                customIconView(filename)
            } else {
                // SF Symbol
                Image(systemName: iconName)
                    .font(.system(size: size * 0.7))
                    .frame(width: size, height: size)
            }
        }
    }
    
    private var fallbackIcon: some View {
        Image(systemName: "terminal")
            .font(.system(size: size * 0.7))
            .frame(width: size, height: size)
    }

    @ViewBuilder
    private func customIconView(_ filename: String) -> some View {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tidyflow/assets/\(filename)")
        if FileManager.default.fileExists(atPath: url.path) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                default:
                    fallbackIcon
                }
            }
        } else {
            fallbackIcon
        }
    }
}
