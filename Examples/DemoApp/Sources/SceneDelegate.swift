import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        print("[SceneDelegate] willConnectTo called")
        
        guard let windowScene = (scene as? UIWindowScene) else {
            print("[SceneDelegate] Failed to get windowScene")
            return
        }
        
        print("[SceneDelegate] Creating window and view controller")
        
        window = UIWindow(windowScene: windowScene)
        
        let mainViewController = ViewController()
        let navigationController = UINavigationController(rootViewController: mainViewController)
        
        window?.rootViewController = navigationController
        window?.makeKeyAndVisible()
        
        print("[SceneDelegate] Window setup completed")
        print("[SceneDelegate] Root view controller: \(String(describing: window?.rootViewController))")
    }

    func sceneDidDisconnect(_ scene: UIScene) {
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
    }

    func sceneWillResignActive(_ scene: UIScene) {
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
    }
}