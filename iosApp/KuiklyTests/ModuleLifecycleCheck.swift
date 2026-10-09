import Foundation
import UIKit
@preconcurrency import OpenKuiklyIOSRender
@preconcurrency import GycMediaKuikly

private final class Bridge: NSObject, TDFBridgeDelegate {
    weak var rootView: UIView?
    var pageName: String? { "lifecycle-fixture" }
    var bridgeType: TDF_BRIDGE_TYPE { .KUIKLY }
    var hippyBridge: AnyObject? { nil }
    func send(withEvent event: String, data: [AnyHashable: Any]?) {}
    func module(withName moduleName: String) -> Any? { nil }
    func view(withTag tag: Int) -> UIView? { nil }
    func performCallback(_ callbackId: NSNumber, params: Any) {}
}

@MainActor
private func attached(_ view: UIView) -> GycMedia {
    let receiver = GycMedia()
    let bridge = Bridge()
    bridge.rootView = view
    receiver.delegate = bridge
    // 仅测试 receiver 生命周期；占位 UIView 不启动被排除的实际 Renderer。
    receiver.setValue(view, forKey: "hr_rootView")
    return receiver
}

@MainActor
private func drainMain() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

private final class CallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func receive() {
        precondition(!Thread.isMainThread)
        lock.lock(); value += 1; lock.unlock()
    }
}

@MainActor
private func drainContext() async {
    await withCheckedContinuation { continuation in
        KuiklyRenderThreadManager.performOnContextQueue { continuation.resume() }
    }
}

@MainActor
private func checks() async {
    let root = UIView()
    var created = 0
    var disposed = 0
    var replies: [(String) -> Void] = []
    var duringFactory: (() -> Void)?
    let callbackState = CallbackState()
    GycMedia.configure {
        created += 1
        duringFactory?()
        return (call: { _, _, reply in replies.append(reply) }, dispose: { disposed += 1 })
    }
    let old = attached(root)
    let callback: KuiklyRenderCallback = { _ in callbackState.receive() }
    _ = old.hrv_call(withMethod: "pick", params: "{}", callback: callback)
    precondition(created == 1 && replies.count == 1)
    old.invalidate()
    old.invalidate()
    precondition(disposed == 1)
    replies[0]("{}")
    precondition(callbackState.count == 0)
    let fresh = attached(root)
    _ = fresh.hrv_call(withMethod: "pick", params: "{}", callback: callback)
    replies[0]("{}")
    replies[1]("{}")
    await drainContext()
    precondition(created == 2 && callbackState.count == 1)
    let contextEntered = DispatchSemaphore(value: 0)
    let contextContinue = DispatchSemaphore(value: 0)
    KuiklyRenderThreadManager.performOnContextQueue {
        contextEntered.signal()
        precondition(contextContinue.wait(timeout: .now() + 2) == .success)
    }
    precondition(contextEntered.wait(timeout: .now() + 2) == .success)
    replies[1]("{}")
    fresh.invalidate()
    contextContinue.signal()
    await drainContext()
    precondition(callbackState.count == 1)

    let creating = attached(root)
    duringFactory = {
        let invalidated = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { creating.invalidate(); invalidated.signal() }
        precondition(invalidated.wait(timeout: .now() + 2) == .success)
    }
    _ = creating.hrv_call(withMethod: "pick", params: "{}", callback: callback)
    duringFactory = nil
    precondition(created == 3 && disposed == 3 && replies.count == 2)

    let queued = attached(root)
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        _ = queued.hrv_call(withMethod: "pick", params: "{}", callback: callback)
        queued.invalidate()
        queued.invalidate()
        done.signal()
    }
    // Main 被占用时，worker 必须能立即失效；Main.sync 会在这里失败。
    precondition(done.wait(timeout: .now() + 2) == .success)
    await drainMain()
    precondition(created == 3 && disposed == 3 && callbackState.count == 1)

    final class Holder: @unchecked Sendable { var receiver: GycMedia? }
    let holder = Holder()
    holder.receiver = attached(root)
    weak var released = holder.receiver
    _ = holder.receiver?.hrv_call(withMethod: "pick", params: "{}", callback: callback)
    let releasedOnWorker = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        autoreleasepool { holder.receiver = nil }
        releasedOnWorker.signal()
    }
    precondition(releasedOnWorker.wait(timeout: .now() + 2) == .success)
    await drainMain()
    precondition(released == nil && created == 4 && disposed == 4)
    replies[2]("{}")
    await drainContext()
    precondition(callbackState.count == 1)
    print("PASS: media receiver repeated invalidate, queued call, factory race, Context callback and SDK dealloc")
}

@main
private final class CheckApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Task { @MainActor in
            await checks()
            fflush(stdout)
            exit(0)
        }
        return true
    }
}
