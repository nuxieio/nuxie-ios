#if canImport(AppKit)
import AppKit

public extension NSApplication {
    /// Returns the best candidate window for SDK presentation.
    var activeWindow: NSWindow? {
        if let keyWindow {
            return keyWindow
        }

        if let mainWindow {
            return mainWindow
        }

        return windows.first(where: { $0.isVisible }) ?? windows.first
    }
}
#endif
