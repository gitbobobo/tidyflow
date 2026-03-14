import Foundation

// MARK: - 编辑器查找替换共享纯值引擎
//
// 此文件属于 TidyFlowShared，不依赖 SwiftUI、AppKit 或 UIKit。
// 提供跨 macOS/iOS 共享的查找替换纯值 API，双端消费同一实现。
//
// 设计约束：
// - 所有 API 均为纯函数/静态方法，输入值 → 输出值，不持有可变状态。
// - 非法正则返回错误字符串而不是抛异常；调用方决定如何展示。
// - 匹配范围使用 Swift 原生 Range<String.Index>，不使用 NSRange。

/// 查找替换纯值引擎，提供匹配查找、替换、索引钳制与高亮目标行解析。
public enum EditorFindReplaceEngine {

    /// 查找结果
    public struct FindResult: Equatable, Sendable {
        /// 所有匹配范围（按出现顺序）
        public let ranges: [Range<String.Index>]
        /// 正则编译错误（非空时表示当前正则无效，ranges 为空）
        public let regexError: String?

        public init(ranges: [Range<String.Index>], regexError: String?) {
            self.ranges = ranges
            self.regexError = regexError
        }
    }

    /// 替换结果
    public struct ReplaceResult: Equatable, Sendable {
        /// 替换后的完整文本
        public let text: String
        /// 替换后重新查找得到的匹配范围
        public let newRanges: [Range<String.Index>]
        /// 替换后的当前匹配索引（已钳制到有效范围）
        public let currentMatchIndex: Int
    }

    // MARK: - 查找匹配

    /// 在文本中查找所有匹配范围。
    ///
    /// - Parameters:
    ///   - text: 被搜索的文本
    ///   - state: 当前查找替换状态（findText、大小写、正则等）
    /// - Returns: 匹配结果，包含范围数组和可能的正则错误
    public static func findMatches(in text: String, state: EditorFindReplaceState) -> FindResult {
        findMatches(in: text, findText: state.findText, isCaseSensitive: state.isCaseSensitive, useRegex: state.useRegex)
    }

    /// 在文本中查找所有匹配范围（参数化版本）。
    public static func findMatches(
        in text: String,
        findText: String,
        isCaseSensitive: Bool = false,
        useRegex: Bool = false
    ) -> FindResult {
        guard !findText.isEmpty else {
            return FindResult(ranges: [], regexError: nil)
        }

        if useRegex {
            do {
                let regex = try NSRegularExpression(
                    pattern: findText,
                    options: isCaseSensitive ? [] : [.caseInsensitive]
                )
                let nsText = text as NSString
                let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
                let ranges = matches.compactMap { Range($0.range, in: text) }
                return FindResult(ranges: ranges, regexError: nil)
            } catch {
                return FindResult(ranges: [], regexError: error.localizedDescription)
            }
        }

        var ranges: [Range<String.Index>] = []
        var searchRange = text.startIndex..<text.endIndex
        let options: String.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]
        while let range = text.range(of: findText, options: options, range: searchRange) {
            ranges.append(range)
            if range.upperBound == text.endIndex { break }
            searchRange = range.upperBound..<text.endIndex
        }
        return FindResult(ranges: ranges, regexError: nil)
    }

    // MARK: - 匹配索引钳制

    /// 在匹配范围变化后钳制当前索引到有效范围。
    ///
    /// - Parameters:
    ///   - currentIndex: 当前匹配索引（可能越界或为 -1）
    ///   - matchCount: 新的匹配总数
    ///   - keepSelection: 是否尝试保持当前选中位置
    /// - Returns: 钳制后的匹配索引，无匹配时返回 -1
    public static func clampMatchIndex(currentIndex: Int, matchCount: Int, keepSelection: Bool) -> Int {
        guard matchCount > 0 else { return -1 }
        if keepSelection, currentIndex >= 0 {
            return min(currentIndex, matchCount - 1)
        }
        return 0
    }

    /// 导航到下一个匹配（环绕）。
    public static func nextMatchIndex(currentIndex: Int, matchCount: Int) -> Int {
        guard matchCount > 0 else { return -1 }
        if currentIndex < 0 { return 0 }
        return (currentIndex + 1) % matchCount
    }

    /// 导航到上一个匹配（环绕）。
    public static func previousMatchIndex(currentIndex: Int, matchCount: Int) -> Int {
        guard matchCount > 0 else { return -1 }
        if currentIndex < 0 { return 0 }
        return (currentIndex - 1 + matchCount) % matchCount
    }

    // MARK: - 替换当前

    /// 替换当前匹配并返回更新后的文本和匹配状态。
    ///
    /// - Parameters:
    ///   - text: 当前文本
    ///   - matchRanges: 当前匹配范围数组
    ///   - currentIndex: 当前匹配索引
    ///   - replaceText: 替换文本
    ///   - state: 查找替换状态（用于重新查找）
    /// - Returns: 替换结果；如果索引无效或有正则错误则返回 nil
    public static func replaceCurrent(
        in text: String,
        matchRanges: [Range<String.Index>],
        currentIndex: Int,
        replaceText: String,
        state: EditorFindReplaceState
    ) -> ReplaceResult? {
        guard currentIndex >= 0, currentIndex < matchRanges.count else { return nil }
        guard state.regexError == nil else { return nil }

        var newText = text
        let range = matchRanges[currentIndex]
        newText.replaceSubrange(range, with: replaceText)

        let newFind = findMatches(in: newText, state: state)
        let newIndex = clampMatchIndex(currentIndex: currentIndex, matchCount: newFind.ranges.count, keepSelection: true)
        return ReplaceResult(text: newText, newRanges: newFind.ranges, currentMatchIndex: newIndex)
    }

    // MARK: - 全部替换

    /// 替换所有匹配并返回更新后的文本和匹配状态。
    ///
    /// - Parameters:
    ///   - text: 当前文本
    ///   - matchRanges: 当前匹配范围数组
    ///   - replaceText: 替换文本
    ///   - state: 查找替换状态（用于重新查找）
    /// - Returns: 替换结果；如果无匹配或有正则错误则返回 nil
    public static func replaceAll(
        in text: String,
        matchRanges: [Range<String.Index>],
        replaceText: String,
        state: EditorFindReplaceState
    ) -> ReplaceResult? {
        guard !matchRanges.isEmpty else { return nil }
        guard state.regexError == nil else { return nil }

        var newText = text
        // 从后向前替换以保持索引有效性
        for range in matchRanges.reversed() {
            newText.replaceSubrange(range, with: replaceText)
        }

        let newFind = findMatches(in: newText, state: state)
        let newIndex = clampMatchIndex(currentIndex: -1, matchCount: newFind.ranges.count, keepSelection: false)
        return ReplaceResult(text: newText, newRanges: newFind.ranges, currentMatchIndex: newIndex)
    }

    // MARK: - 高亮目标行解析

    /// 解析指定匹配范围所在的行号（1-based）。
    ///
    /// - Parameters:
    ///   - text: 完整文本
    ///   - matchRanges: 匹配范围数组
    ///   - currentIndex: 当前匹配索引
    /// - Returns: 匹配所在行号（1-based），无效索引返回 nil
    public static func targetLineForCurrentMatch(
        in text: String,
        matchRanges: [Range<String.Index>],
        currentIndex: Int
    ) -> Int? {
        guard currentIndex >= 0, currentIndex < matchRanges.count else { return nil }
        let range = matchRanges[currentIndex]
        let line = 1 + text[..<range.lowerBound].reduce(into: 0) { partial, char in
            if char == "\n" { partial += 1 }
        }
        return line
    }

    // MARK: - 匹配状态文本

    /// 生成匹配状态文本（如 "3/10" 或 "0/0"）。
    public static func matchStatusText(currentIndex: Int, matchCount: Int) -> String {
        guard matchCount > 0, currentIndex >= 0 else { return "0/0" }
        return "\(currentIndex + 1)/\(matchCount)"
    }
}
