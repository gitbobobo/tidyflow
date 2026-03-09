import SwiftUI
import Foundation

enum SwiftUIHotspot: String {
    case macSidebar = "mac_sidebar"
    case macAIChat = "mac_ai_chat"
    case macBottomPanel = "mac_bottom_panel"
    case macEvolution = "mac_evolution"
    case iosProjectList = "ios_project_list"
    case iosWorkspaceDetail = "ios_workspace_detail"
    case iosAIChat = "ios_ai_chat"
}

@MainActor
private final class SwiftUIHotspotHitchSampler {
    private let hotspot: SwiftUIHotspot
    private let metadata: [String: String]
    private var tickTask: Task<Void, Never>?
    private var lastTickAt: ContinuousClock.Instant?
    private let clock = ContinuousClock()
    private(set) var hitchCount: Int = 0
    private(set) var maxDelayMs: Double = 0

    init(hotspot: SwiftUIHotspot, metadata: [String: String]) {
        self.hotspot = hotspot
        self.metadata = metadata
    }

    func start() {
        guard tickTask == nil else { return }
        lastTickAt = clock.now
        tickTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                let now = self.clock.now
                if let lastTickAt {
                    let components = lastTickAt.duration(to: now).components
                    let delayMs =
                        (Double(components.seconds) * 1000) +
                        (Double(components.attoseconds) / 1_000_000_000_000_000)
                    let extraDelay = max(0, delayMs - 16)
                    if extraDelay >= 20 {
                        self.hitchCount += 1
                    }
                    self.maxDelayMs = max(self.maxDelayMs, extraDelay)
                }
                self.lastTickAt = now
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }
}

@MainActor
private final class SwiftUIHotspotBaselineSession {
    let hotspot: SwiftUIHotspot
    let metadata: [String: String]
    let startedAt = Date()
    let renderCountAtStart: Int
    private let hitchSampler: SwiftUIHotspotHitchSampler
    private var didRecordFirstPaint = false

    init(hotspot: SwiftUIHotspot, metadata: [String: String], renderCountAtStart: Int) {
        self.hotspot = hotspot
        self.metadata = metadata
        self.renderCountAtStart = renderCountAtStart
        self.hitchSampler = SwiftUIHotspotHitchSampler(hotspot: hotspot, metadata: metadata)
    }

    func start() {
        hitchSampler.start()
        recordPhase("begin", extra: [:])
    }

    func markFirstPaintIfNeeded() {
        guard !didRecordFirstPaint else { return }
        didRecordFirstPaint = true
        let firstPaintMs = Date().timeIntervalSince(startedAt) * 1000
        recordPhase("first_paint", extra: [
            "first_paint_ms": Self.format(firstPaintMs)
        ])
    }

    func finish(renderCountAtEnd: Int) {
        hitchSampler.stop()
        let visibleDurationMs = Date().timeIntervalSince(startedAt) * 1000
        recordPhase("end", extra: [
            "visible_ms": Self.format(visibleDurationMs),
            "render_count_delta": String(max(0, renderCountAtEnd - renderCountAtStart)),
            "hitch_count": String(hitchSampler.hitchCount),
            "max_hitch_delay_ms": Self.format(hitchSampler.maxDelayMs)
        ])
    }

    private func recordPhase(_ phase: String, extra: [String: String]) {
        let payload = (metadata.merging(extra) { _, new in new })
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        TFLog.perf.info(
            "perf swiftui_hotspot hotspot=\(self.hotspot.rawValue, privacy: .public) phase=\(phase, privacy: .public) \(payload, privacy: .public)"
        )
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

private struct SwiftUIHotspotBaselineModifier: ViewModifier {
    let hotspot: SwiftUIHotspot
    let renderProbeName: String
    let metadata: [String: String]

    @State private var session: SwiftUIHotspotBaselineSession?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard session == nil else {
                    session?.markFirstPaintIfNeeded()
                    return
                }
                let renderCount = SwiftUIRenderDiagnostics.renderCount(name: renderProbeName, metadata: metadata)
                let nextSession = SwiftUIHotspotBaselineSession(
                    hotspot: hotspot,
                    metadata: metadata,
                    renderCountAtStart: renderCount
                )
                session = nextSession
                nextSession.start()
                DispatchQueue.main.async {
                    nextSession.markFirstPaintIfNeeded()
                }
            }
            .onDisappear {
                guard let session else { return }
                let renderCount = SwiftUIRenderDiagnostics.renderCount(name: renderProbeName, metadata: metadata)
                session.finish(renderCountAtEnd: renderCount)
                self.session = nil
            }
    }
}

extension View {
    func tfHotspotBaseline(
        _ hotspot: SwiftUIHotspot,
        renderProbeName: String,
        metadata: [String: String] = [:]
    ) -> some View {
        modifier(
            SwiftUIHotspotBaselineModifier(
                hotspot: hotspot,
                renderProbeName: renderProbeName,
                metadata: metadata
            )
        )
    }
}
