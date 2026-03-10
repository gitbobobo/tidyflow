import SwiftUI

/// iOS 端命令图标：支持 SF Symbol / brand:* / custom:*，失败回退 terminal。
struct MobileCommandIconView: View {
    let iconName: String
    let size: CGFloat

    var body: some View {
        Group {
            if iconName.hasPrefix("brand:") {
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
                let filename = String(iconName.dropFirst(7))
                customIconView(filename)
            } else {
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
        let url = URL(fileURLWithPath: "\(NSHomeDirectory())/.tidyflow/assets/\(filename)")
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
