import Foundation
import FactoryKit

#if canImport(UIKit)
import UIKit
#endif

#if DEBUG && canImport(UIKit)
public enum FlowRuntimeFixtureHost {
    private static let fixtureBaseURLToken = "__NUXIE_FIXTURE_BASE_URL__"

    @MainActor
    public static func makeViewController(
        fixtureBaseURL: URL,
        cacheRootURL: URL,
        flowId: String = "flow-runtime-fixture"
    ) throws -> UIViewController {
        registerFixtureConfiguration(cacheRootURL: cacheRootURL)

        let fixtureBaseURL = try prepareFixtureBaseURL(
            fixtureBaseURL,
            cacheRootURL: cacheRootURL
        )
        let manifestURL = fixtureBaseURL.appendingPathComponent(FlowArtifactStore.manifestPath)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(FlowArtifactManifest.self, from: manifestData)
        let fixtureFlowDescription = try loadFixtureFlowDescription(fixtureBaseURL: fixtureBaseURL)

        let buildFiles = try buildFiles(
            for: manifest,
            manifestData: manifestData,
            fixtureBaseURL: fixtureBaseURL
        )
        let buildManifest = BuildManifest(
            totalFiles: buildFiles.count,
            totalSize: buildFiles.reduce(0) { $0 + $1.size },
            contentHash: contentHash(for: manifest, manifestData: manifestData, fixtureBaseURL: fixtureBaseURL),
            files: buildFiles
        )
        let remoteFlow = RemoteFlow(
            id: flowId,
            flowArtifact: FlowArtifact(
                url: fixtureBaseURL.absoluteString,
                buildId: manifest.buildId,
                manifest: buildManifest
            ),
            screens: fixtureFlowDescription.screens ?? manifest.screens.map {
                RemoteFlowScreen(
                    id: $0.screenId,
                    defaultViewModelId: nil,
                    defaultInstanceId: nil
                )
            },
            interactions: fixtureFlowDescription.interactions ?? [:],
            viewModels: [],
            viewModelInstances: nil,
            converters: nil
        )

        let runtimeAssetStore = RuntimeAssetStore(
            cacheDirectory: cacheRootURL.appendingPathComponent("runtime-assets")
        )
        let artifactStore = FlowArtifactStore(
            cacheDirectory: cacheRootURL.appendingPathComponent("artifacts"),
            runtimeAssetStore: runtimeAssetStore
        )

        let flow = Flow(remoteFlow: remoteFlow, products: [])
        let flowViewController = FlowViewController(
            flow: flow,
            artifactStore: artifactStore
        )

        if fixtureFlowDescription.interactions?.isEmpty == false {
            return FlowRuntimeFixtureContainerViewController(
                flowViewController: flowViewController,
                flow: flow
            )
        }

        return flowViewController
    }

    private static func loadFixtureFlowDescription(
        fixtureBaseURL: URL
    ) throws -> FixtureFlowDescription {
        let url = fixtureBaseURL.appendingPathComponent("flow-description.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return FixtureFlowDescription()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FixtureFlowDescription.self, from: data)
    }

    private struct FixtureFlowDescription: Decodable {
        var screens: [RemoteFlowScreen]? = nil
        var interactions: [String: [Interaction]]? = nil
    }

    private final class FlowRuntimeFixtureContainerViewController: UIViewController {
        private let flowViewController: FlowViewController
        private let statusLabel = UILabel()
        private let runtime: FlowRuntimeFixtureExecutionRuntime

        init(flowViewController: FlowViewController, flow: Flow) {
            self.flowViewController = flowViewController
            self.runtime = FlowRuntimeFixtureExecutionRuntime(
                flow: flow,
                flowViewController: flowViewController
            )
            super.init(nibName: nil, bundle: nil)
            self.runtime.statusLabel = statusLabel
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidLoad() {
            super.viewDidLoad()

            addChild(flowViewController)
            flowViewController.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(flowViewController.view)
            flowViewController.didMove(toParent: self)

            statusLabel.translatesAutoresizingMaskIntoConstraints = false
            statusLabel.accessibilityIdentifier = "nuxie-flow-event-log"
            statusLabel.text = "ready"
            statusLabel.textColor = .label
            statusLabel.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
            statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
            statusLabel.textAlignment = .center
            statusLabel.numberOfLines = 1
            view.addSubview(statusLabel)

            NSLayoutConstraint.activate([
                flowViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                flowViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                flowViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
                flowViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

                statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
                statusLabel.heightAnchor.constraint(equalToConstant: 32),
            ])
        }
    }

    private actor FlowRuntimeFixtureRunnerBridge {
        private let runner: FlowJourneyRunner
        private var didHandleReady = false
        private var currentScreenId: String?

        init(runner: FlowJourneyRunner) {
            self.runner = runner
        }

        func handleReady() async -> FlowJourneyRunner.RunOutcome? {
            guard !didHandleReady else { return nil }
            didHandleReady = true
            return await runner.handleRuntimeReady()
        }

        func handleScreenChanged(_ screenId: String) async -> FlowJourneyRunner.RunOutcome? {
            currentScreenId = screenId
            return await runner.handleScreenChanged(screenId)
        }

        func handleInteraction(_ interaction: FlowRendererInteraction) async -> FlowJourneyRunner.RunOutcome? {
            await runner.dispatchTrigger(
                trigger: interaction.trigger,
                screenId: interaction.screenId ?? currentScreenId,
                componentId: interaction.componentId,
                instanceId: interaction.instanceId,
                event: nil
            )
        }
    }

    private final class FlowRuntimeFixtureExecutionRuntime: FlowRuntimeDelegate {
        private let bridge: FlowRuntimeFixtureRunnerBridge
        private weak var flowViewController: FlowViewController?
        weak var statusLabel: UILabel?

        init(flow: Flow, flowViewController: FlowViewController) {
            let campaign = Campaign(
                id: "fixture-campaign",
                name: "Fixture Campaign",
                flowId: flow.remoteFlow.id,
                flowNumber: 1,
                flowName: "Fixture Flow",
                reentry: .everyTime,
                publishedAt: ISO8601DateFormatter().string(from: Date()),
                trigger: .event(EventTriggerConfig(eventName: "fixture", condition: nil)),
                goal: nil,
                exitPolicy: nil,
                conversionAnchor: nil,
                campaignType: nil
            )
            let journey = Journey(
                id: "fixture-journey",
                campaign: campaign,
                distinctId: "fixture-distinct-id"
            )
            let runner = FlowJourneyRunner(
                journey: journey,
                campaign: campaign,
                flow: flow
            )
            runner.attach(viewController: flowViewController)
            self.flowViewController = flowViewController
            self.bridge = FlowRuntimeFixtureRunnerBridge(runner: runner)
            runner.onShowScreen = { [weak self] screenId, transition in
                await self?.showScreen(screenId, transition: transition?.value)
            }
            flowViewController.runtimeDelegate = self
        }

        func flowViewControllerDidBecomeReady(_ controller: FlowViewController) {
            Task { [bridge, weak self] in
                guard let self else { return }
                await self.handleOutcome(await bridge.handleReady())
            }
        }

        func flowViewController(
            _ controller: FlowViewController,
            didChangeScreen screenId: String
        ) {
            setStatus("screen:\(screenId)")
            Task { [bridge, weak self] in
                guard let self else { return }
                await self.handleOutcome(await bridge.handleScreenChanged(screenId))
            }
        }

        func flowViewController(
            _ controller: FlowViewController,
            didEmitInteraction interaction: FlowRendererInteraction
        ) {
            setStatus("interaction:\(interaction.componentId ?? "unknown")")
            Task { [bridge, weak self] in
                guard let self else { return }
                await self.handleOutcome(await bridge.handleInteraction(interaction))
            }
        }

        func flowViewControllerDidRequestDismiss(_ controller: FlowViewController, reason: CloseReason) {
            setStatus("dismissed:\(String(describing: reason))")
        }

        private func setStatus(_ text: String) {
            Task { @MainActor [weak self] in
                self?.appendStatus(text)
            }
        }

        @MainActor
        private func showScreen(_ screenId: String, transition: Any?) {
            flowViewController?.navigate(to: screenId, transition: transition)
            appendStatus("navigated:\(screenId)")
        }

        @MainActor
        private func appendStatus(_ text: String) {
            guard let statusLabel else { return }
            let currentText = statusLabel.text ?? ""
            if currentText.isEmpty || currentText == "ready" {
                statusLabel.text = text
            } else {
                statusLabel.text = "\(currentText) | \(text)"
            }
        }

        @MainActor
        private func handleOutcome(_ outcome: FlowJourneyRunner.RunOutcome?) {
            guard let outcome else { return }
            switch outcome {
            case .paused:
                appendStatus("paused")
            case .exited(let reason):
                appendStatus("exited:\(reason.rawValue)")
            }
        }
    }

    private static func prepareFixtureBaseURL(
        _ fixtureBaseURL: URL,
        cacheRootURL: URL
    ) throws -> URL {
        let manifestURL = fixtureBaseURL.appendingPathComponent(FlowArtifactStore.manifestPath)
        let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
        guard manifestText.contains(fixtureBaseURLToken) else {
            return fixtureBaseURL
        }

        let preparedBaseURL = cacheRootURL.appendingPathComponent(
            "prepared-fixture",
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: preparedBaseURL)
        try FileManager.default.createDirectory(
            at: preparedBaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: fixtureBaseURL, to: preparedBaseURL)

        let replacementBaseURL = preparedBaseURL.absoluteString.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        let preparedManifestText = manifestText.replacingOccurrences(
            of: fixtureBaseURLToken,
            with: replacementBaseURL
        )
        try preparedManifestText.write(
            to: preparedBaseURL.appendingPathComponent(FlowArtifactStore.manifestPath),
            atomically: true,
            encoding: .utf8
        )
        return preparedBaseURL
    }

    private static func registerFixtureConfiguration(cacheRootURL: URL) {
        Container.shared.manager.reset(scope: .sdk)

        let configuration = NuxieConfiguration(apiKey: "flow-runtime-fixture")
        configuration.environment = .development
        configuration.customStoragePath = cacheRootURL.appendingPathComponent("sdk-storage")
        configuration.logLevel = .debug
        configuration.enableConsoleLogging = true
        configuration.enableFileLogging = false
        configuration.enablePlugins = false

        Container.shared.sdkConfiguration.register { configuration }
    }

    private static func buildFiles(
        for manifest: FlowArtifactManifest,
        manifestData: Data,
        fixtureBaseURL: URL
    ) throws -> [BuildFile] {
        var files = [
            BuildFile(
                path: FlowArtifactStore.manifestPath,
                size: manifestData.count,
                contentType: "application/json"
            ),
            BuildFile(
                path: manifest.riv.path,
                size: try fileSize(forRelativePath: manifest.riv.path, fixtureBaseURL: fixtureBaseURL),
                contentType: "application/octet-stream"
            ),
        ]

        for image in manifest.assets.images {
            files.append(
                BuildFile(
                    path: image.path,
                    size: try fileSize(forRelativePath: image.path, fixtureBaseURL: fixtureBaseURL),
                    contentType: image.contentType
                )
            )
        }

        return files
    }

    private static func contentHash(
        for manifest: FlowArtifactManifest,
        manifestData: Data,
        fixtureBaseURL: URL
    ) -> String {
        var data = Data()
        data.append(manifestData)
        if let rivData = try? Data(contentsOf: fixtureBaseURL.appendingPathComponent(manifest.riv.path)) {
            data.append(rivData)
        }
        for image in manifest.assets.images {
            if let imageData = try? Data(contentsOf: fixtureBaseURL.appendingPathComponent(image.path)) {
                data.append(imageData)
            }
        }
        return FlowArtifactStore.sha256Hex(data)
    }

    private static func fileSize(forRelativePath path: String, fixtureBaseURL: URL) throws -> Int {
        let safePath = try FlowArtifactStore.validateRelativePath(path)
        return try Data(contentsOf: fixtureBaseURL.appendingPathComponent(safePath)).count
    }
}
#endif
