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
        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        if let navigation = controller as? UINavigationController { return navigation.visibleViewController }
        if let tabs = controller as? UITabBarController { return tabs.selectedViewController }
        return controller
    }
    static func dismiss(_ controller: UIViewController, animated: Bool, completion: @escaping () -> Void) {
        controller.dismiss(animated: animated, completion: completion)
    }
}
