import UIKit
import Nuxie

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        print("[AppDelegate] didFinishLaunchingWithOptions called")
        
        // Configure Nuxie SDK for Photo Editor Pro demo
        let config = NuxieConfiguration(apiKey: "pk_live_odfbiUwK7nhlzWBLk8vPwQly6hBLokibNl4eUzGrd097HjaXqIpB2ZbcMw3BeRJn1wIkmeGAxRsOa12jPnEL7WwPfEI5")
        config.apiEndpoint = URL(string: "http://localhost:3000")!
        config.environment = .development
        config.logLevel = .debug
        
        // Enable console logging for demo purposes
        config.enableConsoleLogging = true
        
        // Configure sync settings
        config.syncInterval = 1800 // 30 minutes for demo
        config.eventBatchSize = 25
        
        // AppLifecyclePlugin is included by default and will track:
        // - App Installed (first launch)
        // - App Updated (version changes)  
        // - App Opened (every launch + foreground)
        // - App Backgrounded (when app goes to background)
        
        do {
            try NuxieSDK.shared.setup(with: config)
            print("[Photo Editor Pro] Nuxie SDK initialized successfully")
            // Campaign sync happens automatically based on syncInterval
            
        } catch {
            print("[Photo Editor Pro] SDK setup failed: \(error.localizedDescription)")
        }
        
        print("[AppDelegate] didFinishLaunchingWithOptions completed")
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
    }
}
