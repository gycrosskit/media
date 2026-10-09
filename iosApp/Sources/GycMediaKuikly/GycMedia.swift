import Foundation
import OpenKuiklyIOSRender

/// 原生 SDK 通过确切 Objective-C 名称为每个 Renderer 创建 receiver。
@objc(GycMedia)
public final class GycMedia: KRBaseModule {
    public typealias Handler = (call: (String, String, @escaping (String) -> Void) -> Void, dispose: () -> Void)
    private static var makeHandler: (() -> Handler)?
    private let lifecycleLock = NSLock()
    private var invalidated = false
    private var handler: Handler?

    /// 在创建 Renderer 前于 Main 配置；工厂每次创建新的 Kotlin handler，复用原生能力 owner。
    public static func configure(makeHandler: @escaping () -> Handler) {
        precondition(Thread.isMainThread)
        self.makeHandler = makeHandler
        precondition(NSClassFromString("GycMedia") == GycMedia.self)
    }

    // typed callback 保留 SDK 的 Objective-C block 桥接，不经 NSDictionary 动态转换。
    public override func hrv_call(withMethod method: String, params: Any?, callback: KuiklyRenderCallback?) -> Any? {
        let params = params as? String ?? ""
        let perform = { [weak self] in
            guard let self, self.hr_rootView != nil else { return }
            self.lifecycleLock.lock()
            let active = !self.invalidated
            let existing = self.handler
            self.lifecycleLock.unlock()
            guard active else { return }
            let current: Handler
            if let existing {
                current = existing
            } else {
                guard let created = Self.makeHandler?() else {
                    self.deliver("{\"status\":\"error\"}", callback: callback)
                    return
                }
                self.lifecycleLock.lock()
                let accepted = !self.invalidated
                if accepted { self.handler = created }
                self.lifecycleLock.unlock()
                guard accepted else { created.dispose(); return }
                current = created
            }
            current.call(method, params) { [weak self] response in
                self?.deliver(response, callback: callback)
            }
        }
        if Thread.isMainThread { perform() } else { DispatchQueue.main.async(execute: perform) }
        return nil
    }

    private func deliver(_ response: String, callback: KuiklyRenderCallback?) {
        KuiklyRenderThreadManager.performOnContextQueue { [weak self] in
            guard let self else { return }
            self.lifecycleLock.lock()
            let active = !self.invalidated
            self.lifecycleLock.unlock()
            if active, self.hr_rootView != nil { callback?(response) }
        }
    }

    public override func invalidate() {
        lifecycleLock.lock()
        invalidated = true
        let dispose = handler?.dispose
        handler = nil
        lifecycleLock.unlock()
        // SDK 线程可能正被 Main 等待；禁止 Main.sync，先失效再异步释放。
        if Thread.isMainThread { dispose?() } else { DispatchQueue.main.async { dispose?() } }
        super.invalidate()
    }
}
