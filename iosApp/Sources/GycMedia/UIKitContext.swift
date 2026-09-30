import UIKit
enum UIKitExecutionContext {
    static func run(_ action: @escaping () -> Void) {
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }
}
enum UIKitPresentationContext {
    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return topViewController(from: scene?.windows.first { $0.isKeyWindow }?.rootViewController)
    }

    static func topViewController(from controller: UIViewController?) -> UIViewController? {
        guard let controller else { return nil }
        let child: UIViewController?
        if let presented = controller.presentedViewController {
            child = presented
        } else if let navigation = controller as? UINavigationController {
            child = navigation.visibleViewController
        } else if let tabs = controller as? UITabBarController {
            child = tabs.selectedViewController
        } else if let split = controller as? UISplitViewController {
            child = split.viewControllers.last { $0.viewIfLoaded?.window != nil } ?? split.viewControllers.last
        } else {
            child = controller.children.last {
                guard let view = $0.viewIfLoaded else { return false }
                return view.window != nil && !view.isHidden && view.alpha > 0
            }
        }
        if let child { return topViewController(from: child) }
        return controller
    }
    static func dismiss(_ controller: UIViewController, animated: Bool, completion: @escaping () -> Void) {
        // 转场结束后下一轮主队列再检查；只关闭捕获的旧页面，不从 presenter 关闭新 Picker。
        if controller.isBeingPresented || controller.isBeingDismissed {
            let retry = {
                DispatchQueue.main.async { dismiss(controller, animated: animated, completion: completion) }
            }
            if let coordinator = controller.transitionCoordinator,
               coordinator.animate(alongsideTransition: nil, completion: { _ in retry() }) { return }
            retry()
            return
        }
        guard controller.presentingViewController != nil else {
            completion()
            return
        }
        controller.dismiss(animated: animated, completion: completion)
    }
}
