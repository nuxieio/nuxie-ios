import SwiftUI
import UIKit
import Nuxie

@main
struct NuxieFlowRuntimeHostApp: App {
    var body: some Scene {
        WindowGroup {
            FlowRuntimeHostView()
                .ignoresSafeArea()
        }
    }
}

private struct FlowRuntimeHostView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        do {
            return try makeFlowViewController()
        } catch {
            return FlowRuntimeHostErrorViewController(error: error)
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    private func makeFlowViewController() throws -> UIViewController {
        let fixtureName = launchArgumentValue(named: "--nuxie-fixture") ?? "layout-paint"
        guard let resourceURL = Bundle.main.resourceURL else {
            throw FlowRuntimeHostError.missingResourceRoot
        }

        let fixtureBaseURL = resourceURL
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(fixtureName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: fixtureBaseURL.path) else {
            throw FlowRuntimeHostError.missingFixture(fixtureName)
        }

        let cacheRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nuxie-flow-runtime-host", isDirectory: true)
            .appendingPathComponent(fixtureName, isDirectory: true)

        return try FlowRuntimeFixtureHost.makeViewController(
            fixtureBaseURL: fixtureBaseURL,
            cacheRootURL: cacheRootURL,
            flowId: fixtureName
        )
    }

    private func launchArgumentValue(named name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private enum FlowRuntimeHostError: LocalizedError {
    case missingResourceRoot
    case missingFixture(String)

    var errorDescription: String? {
        switch self {
        case .missingResourceRoot:
            return "Flow runtime host could not resolve Bundle.main.resourceURL"
        case .missingFixture(let fixture):
            return "Flow runtime fixture is missing: \(fixture)"
        }
    }
}

private final class FlowRuntimeHostErrorViewController: UIViewController {
    private let error: Error

    init(error: Error) {
        self.error = error
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "nuxie-flow-host-error"

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .label
        label.text = error.localizedDescription
        label.accessibilityIdentifier = "nuxie-flow-host-error-label"

        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
