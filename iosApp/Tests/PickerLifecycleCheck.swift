import UIKit
import PhotosUI
@testable import GycMedia

private final class Callback: MediaPickerCallback {
    var cancelled = 0
    var failed = 0
    var onCancel: (() -> Void)?
    func onImage(data: Data, fileName: String, contentType: String) { fatalError("Unexpected image") }
    func onCompleted() { fatalError("Unexpected completion") }
    func onCancelled() { cancelled += 1; onCancel?() }
    func onPermissionDenied() { fatalError("Unexpected permission denial") }
    func onPermissionBlocked() { fatalError("Unexpected permission block") }
    func onPermissionRestricted() { fatalError("Unexpected permission restriction") }
    func onFailed(message: String) { failed += 1 }
}

private final class Presenter: UIViewController {
    var controllers: [UIViewController] = []
    var actuallyPresent = true
    var appeared = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        appeared = false
    }
    override func present(_ controller: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
        controllers.append(controller)
        if actuallyPresent {
            super.present(controller, animated: animated, completion: completion)
        } else {
            completion?()
        }
    }
}

private final class Controller: UIViewController {
    var dismissals = 0
    var presentingWithoutCoordinator = false
    override var isBeingPresented: Bool { presentingWithoutCoordinator || super.isBeingPresented }
    override func dismiss(animated: Bool, completion: (() -> Void)? = nil) {
        dismissals += 1
        super.dismiss(animated: animated, completion: completion)
    }
}

@MainActor
private func eventually(_ message: String, _ condition: () -> Bool) async {
    for _ in 0..<100 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    fatalError(message)
}

@MainActor
private func pick(_ callback: Callback) {
    MediaClient.shared.pickImages(source: 1, maxCount: 1, maxDimension: 0, jpegQuality: 0, callback: callback)
}

@MainActor
private func runChecks(window: UIWindow) async {
    let unused = Controller()
    var completed = 0
    UIKitPresentationContext.dismiss(unused, animated: true) { completed += 1 }
    precondition(completed == 1 && unused.dismissals == 0, "Unpresented dismissal must complete immediately")

    unused.presentingWithoutCoordinator = true
    UIKitPresentationContext.dismiss(unused, animated: true) { completed += 1 }
    precondition(completed == 1, "A transition without a coordinator must defer")
    unused.presentingWithoutCoordinator = false
    await eventually("Deferred dismissal did not complete") { completed == 2 }

    var root = Presenter()
    window.rootViewController = root
    window.makeKeyAndVisible()
    let appearing = Controller()
    root.present(appearing, animated: true)
    precondition(appearing.isBeingPresented && appearing.transitionCoordinator != nil)
    UIKitPresentationContext.dismiss(appearing, animated: true) { completed += 1 }
    precondition(completed == 2 && appearing.dismissals == 0, "Do not dismiss during presentation")
    await eventually("Presentation then dismissal did not finish") { completed == 3 }
    precondition(appearing.dismissals == 1 && root.presentedViewController == nil)

    let disappearing = Controller()
    await withCheckedContinuation { continuation in
        root.present(disappearing, animated: false) { continuation.resume() }
    }
    disappearing.dismiss(animated: true)
    precondition(disappearing.isBeingDismissed && disappearing.transitionCoordinator != nil)
    UIKitPresentationContext.dismiss(disappearing, animated: true) { completed += 1 }
    precondition(completed == 3, "Do not finish during dismissal")
    await eventually("Existing dismissal did not finish") { completed == 4 }
    precondition(disappearing.dismissals == 1, "Do not dismiss an already dismissed controller twice")

    let child = UIViewController()
    let tabs = UITabBarController()
    tabs.viewControllers = [UINavigationController(rootViewController: child)]
    let split = UISplitViewController()
    split.viewControllers = [UIViewController(), tabs]
    precondition(UIKitPresentationContext.topViewController(from: split) === child)
    split.viewControllers = [UIViewController()]
    await withCheckedContinuation { continuation in
        root.present(tabs, animated: false) { continuation.resume() }
    }
    precondition(UIKitPresentationContext.topViewController(from: root) === child)
    await withCheckedContinuation { continuation in
        UIKitPresentationContext.dismiss(tabs, animated: false) { continuation.resume() }
    }

    let custom = Presenter()
    let hidden = UIViewController()
    let active = UIViewController()
    custom.addChild(hidden)
    custom.addChild(active)
    custom.view.addSubview(hidden.view)
    custom.view.addSubview(active.view)
    hidden.didMove(toParent: custom)
    active.didMove(toParent: custom)
    hidden.view.isHidden = true
    window.rootViewController = custom
    await eventually("Custom container is not visible") { custom.appeared }
    precondition(UIKitPresentationContext.topViewController(from: custom) === active)

    root = Presenter()
    window.rootViewController = root
    root.controllers = []
    root.actuallyPresent = false
    MediaClient.shared.presenterResolver = { root }
    let unshown = Callback()
    pick(unshown)
    MediaClient.shared.cancelImagePicker()
    precondition(unshown.cancelled == 1, "Unpresented Picker cancellation must terminate")
    let afterUnshown = Callback()
    pick(afterUnshown)
    precondition(root.controllers.count == 2, "Unpresented cancellation must unlock the next Picker")
    MediaClient.shared.cancelImagePicker()

    root.controllers = []
    root.actuallyPresent = true
    await eventually("Presenter is not visible") { root.appeared }
    let first = Callback(), second = Callback(), third = Callback()
    pick(first)
    let oldPicker = root.controllers[0] as! PHPickerViewController
    pick(second)
    pick(third)
    precondition(second.cancelled == 1 && root.controllers.count == 1)
    await eventually("Newest Picker did not present") { first.cancelled == 1 && root.controllers.count == 2 }
    let newest = root.controllers.last as! PHPickerViewController
    await eventually("Newest Picker is still transitioning") {
        newest.presentingViewController != nil && !newest.isBeingPresented
    }
    MediaClient.shared.picker(oldPicker, didFinishPicking: [])
    precondition(third.cancelled == 0 && newest.presentingViewController != nil, "Old delegate must not cancel the newest Picker")
    MediaClient.shared.cancelImagePicker()
    await eventually("Newest Picker did not cancel") { third.cancelled == 1 }
    precondition(first.cancelled == 1 && second.cancelled == 1)

    let movingPresenter = Presenter()
    root.present(movingPresenter, animated: true)
    let waiting = Callback(), latestWaiting = Callback()
    pick(waiting)
    pick(latestWaiting)
    precondition(waiting.cancelled == 1 && movingPresenter.controllers.isEmpty,
                 "A presenting host must defer and retain only its newest request")
    await eventually("Host transition did not start the latest Picker") { movingPresenter.controllers.count == 1 }
    MediaClient.shared.cancelImagePicker()
    await eventually("Picker on a transitioning host did not cancel") { latestWaiting.cancelled == 1 }

    movingPresenter.dismiss(animated: true)
    root.controllers = []
    root.actuallyPresent = false
    let afterHostDismissal = Callback()
    pick(afterHostDismissal)
    precondition(root.controllers.isEmpty, "A dismissing host must finish before a new Picker presents")
    await eventually("Dismissed host was not replaced with its visible parent") { root.controllers.count == 1 }
    MediaClient.shared.cancelImagePicker()
    precondition(afterHostDismissal.cancelled == 1)

    root.controllers = []
    root.actuallyPresent = false
    let beforeReentry = Callback(), outer = Callback(), reentered = Callback()
    pick(beforeReentry)
    beforeReentry.onCancel = { pick(reentered) }
    pick(outer)
    precondition(outer.cancelled == 1 && reentered.cancelled == 0, "Callback reentry must retain the newer request")
    MediaClient.shared.cancelImagePicker()
    precondition(reentered.cancelled == 1)

    MediaClient.shared.presenterResolver = { nil }
    let unavailable = Callback()
    pick(unavailable)
    precondition(unavailable.failed == 1, "A nil resolver must not fall back to a different scene")
    MediaClient.shared.presenterResolver = { UIViewController() }
    let invisible = Callback()
    pick(invisible)
    precondition(invisible.failed == 1, "An off-window presenter must fail without blocking the Picker")
    MediaClient.shared.presenterResolver = { root }
    root.view.isHidden = true
    let hiddenPage = Callback()
    pick(hiddenPage)
    precondition(hiddenPage.failed == 1, "A hidden presenter must fail without retrying")
    root.view.isHidden = false
    MediaClient.shared.presenterResolver = nil
    print("PASS: Picker ownership, cancellation, UIKit transitions and presenter containers")
}

@main
private final class CheckApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window
        Task { @MainActor in
            await runChecks(window: window)
            fflush(stdout)
            exit(0)
        }
        return true
    }
}
