//
//  SceneDelegate.swift
//  MoodLog
//
//  Scene delegate for managing app UI lifecycle.
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = (scene as? UIWindowScene) else { return }

        print("[MoodLog] Setting up window...")

        // Create window
        window = UIWindow(windowScene: windowScene)

        // Create root view controller
        let todayViewController = TodayViewController()
        let navigationController = UINavigationController(rootViewController: todayViewController)

        // Configure navigation bar appearance
        configureNavigationBar(navigationController)

        // Set root and make key
        window?.rootViewController = navigationController
        window?.makeKeyAndVisible()

        print("[MoodLog] Window setup complete")
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Called when the scene is being released by the system
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Called when the scene has moved from inactive to active state
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Called when the scene will move from active to inactive state
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions from background to foreground
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Called as the scene transitions from foreground to background
    }

    // MARK: - Navigation Bar Configuration

    private func configureNavigationBar(_ navigationController: UINavigationController) {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .moodBackground
        appearance.titleTextAttributes = [
            .foregroundColor: UIColor.moodTextPrimary,
            .font: UIFont.systemFont(ofSize: 18, weight: .semibold)
        ]
        appearance.largeTitleTextAttributes = [
            .foregroundColor: UIColor.moodTextPrimary,
            .font: UIFont.systemFont(ofSize: 34, weight: .bold)
        ]

        // Remove separator line
        appearance.shadowColor = .clear

        navigationController.navigationBar.standardAppearance = appearance
        navigationController.navigationBar.scrollEdgeAppearance = appearance
        navigationController.navigationBar.compactAppearance = appearance
        navigationController.navigationBar.tintColor = .moodPrimary

        // Configure toolbar appearance
        let toolbarAppearance = UIToolbarAppearance()
        toolbarAppearance.configureWithOpaqueBackground()
        toolbarAppearance.backgroundColor = .moodBackground
        navigationController.toolbar.standardAppearance = toolbarAppearance
        navigationController.toolbar.compactAppearance = toolbarAppearance
    }
}
