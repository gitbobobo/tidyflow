import Foundation

// MARK: - 共享消息适配器骨架
// 不承载领域逻辑，只承载弱引用持有和主线程转发。
// macOS AppState 与 iOS MobileAppState 均通过此骨架统一消息入口，
// 消除各领域适配器中重复的 weak var + init + dispatch 模板代码。
// Settings 领域保持现状，不纳入本轮共享抽象。

/// 主线程调度协议 — 统一定义消息从 WS 解码队列切到主执行域的入口。
/// macOS 与 iOS 使用相同的默认实现；测试可注入同步调度器以实现确定性验证。
public protocol MainThreadMessageDispatching {
    func dispatch(_ work: @escaping @MainActor () -> Void)
}

/// 默认调度器：DispatchQueue.main.async + MainActor.assumeIsolated。
/// macOS 和 iOS 均可安全使用此实现。
public struct DefaultMainThreadDispatcher: MainThreadMessageDispatching {
    public init() {}

    public func dispatch(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                work()
            }
        }
    }
}

/// 共享消息适配器骨架 — 统一弱引用目标生命周期与主线程调度。
///
/// - Target: 平台侧状态对象类型（AppState / MobileAppState）
/// - 持有 weak var target，避免循环引用
/// - 提供统一的 `dispatchToTarget`，将消息安全切到主线程
/// - 目标释放后，消息静默丢弃，不崩溃也不继续写状态
///
/// Settings 领域保持现状，不纳入本轮共享抽象。
open class WeakTargetMessageAdapter<Target: AnyObject> {
    public weak var target: Target?
    public let dispatcher: MainThreadMessageDispatching

    public init(target: Target, dispatcher: MainThreadMessageDispatching = DefaultMainThreadDispatcher()) {
        self.target = target
        self.dispatcher = dispatcher
    }

    /// 在主线程安全执行针对目标对象的操作。
    /// 如果目标已释放，静默丢弃消息，不会崩溃也不继续写状态。
    public func dispatchToTarget(_ action: @escaping @MainActor (Target) -> Void) {
        dispatcher.dispatch { [weak self] in
            guard let target = self?.target else { return }
            action(target)
        }
    }
}
