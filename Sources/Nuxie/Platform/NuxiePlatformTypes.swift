import Foundation

#if canImport(UIKit)
import UIKit

public typealias NuxiePlatformViewController = UIViewController
public typealias NuxiePlatformWindow = UIWindow
#elseif canImport(AppKit)
import AppKit

public typealias NuxiePlatformViewController = NSViewController
public typealias NuxiePlatformWindow = NSWindow
#endif
