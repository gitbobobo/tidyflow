import SwiftUI
import UIKit

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
                if let image = loadCustomIcon(filename) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                } else {
                    fallbackIcon
                }
            } else {
                if UIImage(systemName: iconName) != nil {
                    Image(systemName: iconName)
                        .font(.system(size: size * 0.7))
                        .frame(width: size, height: size)
                } else {
                    fallbackIcon
                }
            }
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: "terminal")
            .font(.system(size: size * 0.7))
            .frame(width: size, height: size)
    }

    private func loadCustomIcon(_ filename: String) -> UIImage? {
        let path = "\(NSHomeDirectory())/.tidyflow/assets/\(filename)"
        return UIImage(contentsOfFile: path)
    }
}
