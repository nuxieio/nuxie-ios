import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum NuxieSystemNotifications {
    static var appDidEnterBackground: Notification.Name {
        #if canImport(UIKit)
        return UIApplication.didEnterBackgroundNotification
        #elseif canImport(AppKit)
        return NSApplication.didResignActiveNotification
        #else
        return Notification.Name("NuxieAppDidEnterBackground")
        #endif
    }

    static var appWillEnterForeground: Notification.Name {
        #if canImport(UIKit)
        return UIApplication.willEnterForegroundNotification
        #elseif canImport(AppKit)
        return NSApplication.willBecomeActiveNotification
        #else
        return Notification.Name("NuxieAppWillEnterForeground")
        #endif
    }

    static var appDidBecomeActive: Notification.Name {
        #if canImport(UIKit)
        return UIApplication.didBecomeActiveNotification
        #elseif canImport(AppKit)
        return NSApplication.didBecomeActiveNotification
        #else
        return Notification.Name("NuxieAppDidBecomeActive")
        #endif
    }
}
