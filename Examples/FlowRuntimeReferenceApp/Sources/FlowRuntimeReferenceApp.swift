import SwiftUI
import UIKit
import Nuxie

@main
struct NuxieFlowRuntimeReferenceApp: App {
    var body: some Scene {
        WindowGroup {
            FlowRuntimeReferenceView()
                .ignoresSafeArea()
        }
    }
}

private struct FlowRuntimeReferenceView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        FlowRuntimeReferenceViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

private final class FlowRuntimeReferenceViewController: UIViewController {
    private let fixtureNames = [
        "layout-paint",
        "published-font",
        "pressable-interaction",
    ]
    private var currentViewController: UIViewController?
    private let segmentedControl = UISegmentedControl()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureFixtureControl()
        loadFixture(named: fixtureNames[0])
    }

    private func configureFixtureControl() {
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.accessibilityIdentifier = "nuxie-reference-fixture-selector"
        for (index, fixtureName) in fixtureNames.enumerated() {
            segmentedControl.insertSegment(withTitle: fixtureName, at: index, animated: false)
        }
        segmentedControl.selectedSegmentIndex = 0
        segmentedControl.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        segmentedControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let index = self.segmentedControl.selectedSegmentIndex
            guard self.fixtureNames.indices.contains(index) else { return }
            self.loadFixture(named: self.fixtureNames[index])
        }, for: .valueChanged)

        view.addSubview(segmentedControl)
        NSLayoutConstraint.activate([
            segmentedControl.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            segmentedControl.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            segmentedControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            segmentedControl.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    private func loadFixture(named fixtureName: String) {
        do {
            let viewController = try makeFlowViewController(fixtureName: fixtureName)
            replaceCurrentViewController(with: viewController)
        } catch {
            replaceCurrentViewController(with: FlowRuntimeReferenceErrorViewController(error: error))
        }
    }

    private func makeFlowViewController(fixtureName: String) throws -> UIViewController {
        guard let resourceURL = Bundle.main.resourceURL else {
            throw FlowRuntimeReferenceError.missingResourceRoot
        }

        let fixtureBaseURL = resourceURL
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(fixtureName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: fixtureBaseURL.path) else {
            throw FlowRuntimeReferenceError.missingFixture(fixtureName)
        }

        let cacheRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nuxie-flow-runtime-reference-app", isDirectory: true)
            .appendingPathComponent(fixtureName, isDirectory: true)

        return try FlowRuntimeFixtureHost.makeViewController(
            fixtureBaseURL: fixtureBaseURL,
            cacheRootURL: cacheRootURL,
            flowId: fixtureName
        )
    }

    private func replaceCurrentViewController(with nextViewController: UIViewController) {
        if let currentViewController {
            currentViewController.willMove(toParent: nil)
            currentViewController.view.removeFromSuperview()
            currentViewController.removeFromParent()
        }

        addChild(nextViewController)
        nextViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(nextViewController.view, at: 0)
        NSLayoutConstraint.activate([
            nextViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nextViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            nextViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            nextViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        nextViewController.didMove(toParent: self)
        currentViewController = nextViewController
        view.bringSubviewToFront(segmentedControl)
    }
}

private enum FlowRuntimeReferenceError: LocalizedError {
    case missingResourceRoot
    case missingFixture(String)

    var errorDescription: String? {
        switch self {
        case .missingResourceRoot:
            return "Flow runtime reference app could not resolve Bundle.main.resourceURL"
        case .missingFixture(let fixture):
            return "Flow runtime fixture is missing: \(fixture)"
        }
    }
}

private final class FlowRuntimeReferenceErrorViewController: UIViewController {
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

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .label
        label.text = error.localizedDescription

        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
