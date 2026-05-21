import Foundation
#if canImport(CoreText)
import CoreText
#endif

enum FlowRuntimeFontRegistry {
    private static let lock = NSLock()
    private static var postScriptNamesByRiveUniqueName: [String: String] = [:]

    @discardableResult
    static func registerFont(riveUniqueName: String, data: Data) -> String? {
        #if canImport(CoreText)
        lock.lock()
        if let postScriptName = postScriptNamesByRiveUniqueName[riveUniqueName] {
            lock.unlock()
            return postScriptName
        }
        lock.unlock()

        guard let provider = CGDataProvider(data: data as CFData),
              let font = CGFont(provider),
              let postScriptName = font.postScriptName as String? else {
            return nil
        }

        var registerError: Unmanaged<CFError>?
        if CTFontManagerRegisterGraphicsFont(font, &registerError) {
            lock.lock()
            postScriptNamesByRiveUniqueName[riveUniqueName] = postScriptName
            lock.unlock()
            return postScriptName
        }

        if let error = registerError?.takeRetainedValue() {
            if isDuplicateFontRegistrationError(error) {
                lock.lock()
                postScriptNamesByRiveUniqueName[riveUniqueName] = postScriptName
                lock.unlock()
                return postScriptName
            }
            LogWarning("FlowRuntimeFontRegistry: failed to register font \(riveUniqueName): \(CFErrorCopyDescription(error) as String)")
        }
        return nil
        #else
        return nil
        #endif
    }

    static func postScriptName(forRiveUniqueName riveUniqueName: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return postScriptNamesByRiveUniqueName[riveUniqueName]
    }

    #if canImport(CoreText)
    private static func isDuplicateFontRegistrationError(_ error: CFError) -> Bool {
        [105, 305].contains(CFErrorGetCode(error))
    }
    #endif
}
