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
        FlowRuntimeHostRootViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

private final class FlowRuntimeHostRootViewController: UIViewController {
    private var currentViewController: UIViewController?
    private let fixtureNames: [String]
    private let currentFixtureLabel = UILabel()
    private let fixtureSelector = UIStackView()

    init() {
        let fixtureList = Self.launchArgumentValue(named: "--nuxie-fixtures")
            .map { value in
                value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        let singleFixture = Self.launchArgumentValue(named: "--nuxie-fixture") ?? "layout-paint"
        let fixtures = fixtureList?.isEmpty == false ? fixtureList! : [singleFixture]
        self.fixtureNames = fixtures
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        configureFixtureSelector()
        loadFixture(named: fixtureNames.first ?? "layout-paint")
    }

    private func configureFixtureSelector() {
        guard fixtureNames.count > 1 else { return }

        fixtureSelector.translatesAutoresizingMaskIntoConstraints = false
        fixtureSelector.axis = .horizontal
        fixtureSelector.spacing = 8
        fixtureSelector.distribution = .fillEqually
        fixtureSelector.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.86)
        fixtureSelector.layer.cornerRadius = 12
        fixtureSelector.layoutMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        fixtureSelector.isLayoutMarginsRelativeArrangement = true
        fixtureSelector.accessibilityIdentifier = "nuxie-fixture-selector"

        for fixtureName in fixtureNames {
            let button = UIButton(type: .system)
            button.setTitle(fixtureName, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
            button.accessibilityIdentifier = "nuxie-fixture-\(fixtureName)"
            button.addAction(UIAction { [weak self] _ in
                self?.loadFixture(named: fixtureName)
            }, for: .touchUpInside)
            fixtureSelector.addArrangedSubview(button)
        }

        currentFixtureLabel.translatesAutoresizingMaskIntoConstraints = false
        currentFixtureLabel.accessibilityIdentifier = "nuxie-current-fixture"
        currentFixtureLabel.isAccessibilityElement = true
        currentFixtureLabel.textColor = .clear

        view.addSubview(fixtureSelector)
        view.addSubview(currentFixtureLabel)
        NSLayoutConstraint.activate([
            fixtureSelector.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            fixtureSelector.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            fixtureSelector.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            fixtureSelector.heightAnchor.constraint(equalToConstant: 44),

            currentFixtureLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            currentFixtureLabel.topAnchor.constraint(equalTo: view.topAnchor),
            currentFixtureLabel.widthAnchor.constraint(equalToConstant: 1),
            currentFixtureLabel.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func loadFixture(named fixtureName: String) {
        do {
            let viewController = try makeFlowViewController(fixtureName: fixtureName)
            replaceCurrentViewController(with: viewController)
            currentFixtureLabel.text = fixtureName
            currentFixtureLabel.accessibilityLabel = fixtureName
        } catch {
            replaceCurrentViewController(with: FlowRuntimeHostErrorViewController(error: error))
            currentFixtureLabel.text = "error:\(fixtureName)"
            currentFixtureLabel.accessibilityLabel = "error:\(fixtureName)"
        }
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

        if fixtureSelector.superview != nil {
            view.bringSubviewToFront(fixtureSelector)
            view.bringSubviewToFront(currentFixtureLabel)
        }
    }

    private func makeFlowViewController(fixtureName: String) throws -> UIViewController {
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

    private static func launchArgumentValue(named name: String) -> String? {
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
