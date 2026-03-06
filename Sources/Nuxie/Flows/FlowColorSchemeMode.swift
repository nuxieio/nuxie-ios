import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum FlowColorSchemeMode: String, CaseIterable, Codable {
    case light
    case dark
    case system
}

enum ResolvedFlowColorScheme: String {
    case light
    case dark
}

#if canImport(UIKit)
extension FlowColorSchemeMode {
    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .light:
            return .light
        case .dark:
            return .dark
        case .system:
            return .unspecified
        }
    }
}
#endif

#if canImport(AppKit)
extension FlowColorSchemeMode {
    var appearance: NSAppearance? {
        switch self {
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        case .system:
            return nil
        }
    }
}
#endif
