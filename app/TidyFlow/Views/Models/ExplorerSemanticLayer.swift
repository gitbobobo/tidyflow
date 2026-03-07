import SwiftUI

// MARK: - 资源管理器条目展示语义

/// 资源管理器单条目的统一展示快照，平台 UI 直接消费，不在各端各自推导。
/// 输入：FileEntry + 工作区隔离的 GitStatusIndex + 当前交互状态。
struct ExplorerItemPresentation {
    /// SF Symbols 图标名称（特殊文件为空字符串，由 hasSpecialIcon 引导自定义资产渲染）
    let iconName: String
    /// 图标颜色
    let iconColor: Color
    /// 标题颜色（nil 表示平台默认色）
    let titleColor: Color?
    /// Git 状态码（M/A/D/??/R/C/U/!! 等），nil 表示无 Git 变更
    let gitStatus: String?
    /// Git 状态对应的视觉颜色
    let gitStatusColor: Color?
    /// 是否为需要自定义图标资产的特殊文件（CLAUDE.md / AGENTS.md）
    let hasSpecialIcon: Bool
    /// 尾部装饰图标名称（符号链接用 arrow.uturn.backward），nil 表示无
    let trailingIcon: String?
    /// 当前条目是否为活跃高亮编辑项
    let isSelected: Bool
}

// MARK: - 资源管理器语义解析器

/// 从 FileEntry + GitStatusIndex + 交互状态推导 ExplorerItemPresentation，
/// 集中所有图标、颜色、特殊文件与 Git badge 规则，macOS 与 iOS 共用同一套逻辑。
struct ExplorerSemanticResolver {

    /// 解析单条目的展示语义。
    /// - Parameters:
    ///   - entry: 文件条目（来自 Core FileEntryInfo）
    ///   - gitIndex: 当前工作区的 Git 状态索引，必须按工作区键隔离，避免多项目串扰
    ///   - isExpanded: 目录是否已展开（影响文件夹图标）
    ///   - isSelected: 是否为当前高亮编辑文件
    static func resolve(
        entry: FileEntry,
        gitIndex: GitStatusIndex,
        isExpanded: Bool,
        isSelected: Bool
    ) -> ExplorerItemPresentation {
        let gitStatus = gitIndex.getStatus(path: entry.path, isDir: entry.isDir)
        let gitStatusColor = GitStatusIndex.colorForStatus(gitStatus)
        let hasSpecial = isSpecialFile(entry)
        let iconName = resolveIconName(entry: entry, isExpanded: isExpanded)

        let iconColor: Color
        if entry.isIgnored {
            iconColor = Color.gray.opacity(0.5)
        } else if let c = gitStatusColor {
            iconColor = c
        } else if entry.isDir {
            iconColor = .accentColor
        } else {
            iconColor = .secondary
        }

        let titleColor: Color?
        if entry.isIgnored {
            titleColor = Color.gray.opacity(0.5)
        } else {
            titleColor = gitStatusColor
        }

        let trailingIcon: String? = entry.isSymlink ? "arrow.uturn.backward" : nil

        return ExplorerItemPresentation(
            iconName: iconName,
            iconColor: iconColor,
            titleColor: titleColor,
            gitStatus: gitStatus,
            gitStatusColor: gitStatusColor,
            hasSpecialIcon: hasSpecial,
            trailingIcon: trailingIcon,
            isSelected: isSelected
        )
    }

    /// 根据文件条目和展开状态确定 SF Symbol 图标名称
    static func resolveIconName(entry: FileEntry, isExpanded: Bool) -> String {
        if entry.isDir {
            return isExpanded ? "folder.fill" : "folder"
        }
        return fileIconName(for: entry.name)
    }

    /// 判断是否为需要自定义图标资产的特殊文件（CLAUDE.md / AGENTS.md）
    static func isSpecialFile(_ entry: FileEntry) -> Bool {
        guard !entry.isDir else { return false }
        return entry.name == "CLAUDE.md" || entry.name == "AGENTS.md"
    }

    /// 根据文件名（含扩展名）返回对应的 SF Symbol 图标名称
    static func fileIconName(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "swift":
            return "swift"
        case "rs":
            return "gear"
        case "js", "ts", "jsx", "tsx":
            return "j.square"
        case "json", "json5":
            return "curlybraces"
        case "md", "markdown":
            return "doc.richtext"
        case "html", "htm":
            return "globe"
        case "css", "scss", "sass":
            return "paintbrush"
        case "py":
            return "chevron.left.forwardslash.chevron.right"
        case "sh", "bash", "zsh":
            return "terminal"
        case "yml", "yaml", "toml":
            return "doc.badge.gearshape"
        case "erl", "ets":
            return "antenna.radiowaves.left.and.right"
        case "png", "jpg", "jpeg", "gif", "svg", "webp":
            return "photo"
        case "mp3", "wav", "m4a":
            return "music.note"
        case "mp4", "mov", "avi":
            return "video"
        case "zip", "tar", "gz", "rar":
            return "archivebox"
        case "pdf":
            return "doc.fill"
        case "txt":
            return "doc.text"
        case "lock":
            return "lock"
        default:
            return "doc"
        }
    }
}
