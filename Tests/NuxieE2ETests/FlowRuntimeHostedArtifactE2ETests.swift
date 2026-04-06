import Foundation
import Quick
import Nimble
import UIKit
import WebKit
import FactoryKit
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private struct HostedArtifactLaunchConfig: Decodable {
    let schemaVersion: Int
    let scenarioId: String
    let source: String
    let profile: String
    let targetEnv: String
    let publicApiKey: String?
    let ingestUrl: String?
    let flowId: String?
    let campaignId: String?
    let runtimeBuildId: String?
    let distinctId: String?
    let appId: String?
    let appName: String?
    let orgSlug: String?
    let appSlug: String?
}

private struct HostedRuntimeScript: Decodable {
    let schemaVersion: Int
    let label: String?
    let steps: [HostedRuntimeScriptStep]
}

private struct HostedRuntimeScriptStep: Decodable {
    let type: String
    let ms: Int?
    let screenId: String?
    let componentId: String?
    let value: String?
    let experimentKey: String?
    let variantKey: String?
    let isHoldout: Bool?
}

private struct HostedScenarioArtifact {
    let launchConfig: HostedArtifactLaunchConfig
    let runtimeScript: HostedRuntimeScript
}

final class FlowRuntimeHostedArtifactE2ESpec: QuickSpec {
    override class func spec() {
        describe("Flow Runtime Hosted Artifact E2E") {
            var artifact: HostedScenarioArtifact?
            var flowViewController: FlowViewController?
            var window: UIWindow?
            var lastScreenId: LockedValue<String?>?
            var readySeen: LockedValue<Bool>?

            beforeEach {
                artifact = try? loadHostedArtifactFromEnvironment()
                flowViewController = nil
                window = nil
                lastScreenId = LockedValue(nil)
                readySeen = LockedValue(false)
            }

            it("runs runtime-script.json against the hosted SDK flow") {
                guard let artifact else { return }
                guard let apiKey = artifact.launchConfig.publicApiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let ingestUrlString = artifact.launchConfig.ingestUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let flowId = artifact.launchConfig.flowId?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let baseURL = URL(string: ingestUrlString),
                      !apiKey.isEmpty,
                      !flowId.isEmpty else {
                    fail("Hosted artifact launch-config.json is missing apiKey / ingestUrl / flowId")
                    return
                }

                waitUntil(timeout: .seconds(150)) { done in
                    var finished = false

                    func finishOnce() {
                        guard !finished else { return }
                        finished = true
                        done()
                    }

                    Task {
                        do {
                            Container.shared.reset()

                            let config = NuxieConfiguration(apiKey: apiKey)
                            config.apiEndpoint = baseURL
                            config.enablePlugins = false
                            config.customStoragePath = FileManager.default.temporaryDirectory
                                .appendingPathComponent("nuxie-e2e-hosted-\(UUID().uuidString)", isDirectory: true)
                            Container.shared.sdkConfiguration.register { config }

                            let identityService = Container.shared.identityService()
                            let distinctId = artifact.launchConfig.distinctId?.isEmpty == false
                                ? artifact.launchConfig.distinctId!
                                : "scenario-\(artifact.launchConfig.scenarioId)"
                            identityService.setDistinctId(distinctId)

                            let contextBuilder = NuxieContextBuilder(identityService: identityService, configuration: config)
                            let networkQueue = NuxieNetworkQueue(
                                flushAt: 1_000_000,
                                flushIntervalSeconds: config.flushInterval,
                                maxQueueSize: config.maxQueueSize,
                                maxBatchSize: config.eventBatchSize,
                                maxRetries: config.retryCount,
                                baseRetryDelay: config.retryDelay,
                                apiClient: Container.shared.nuxieApi()
                            )
                            let eventService = Container.shared.eventService()
                            try await eventService.configure(
                                networkQueue: networkQueue,
                                journeyService: nil,
                                contextBuilder: contextBuilder,
                                configuration: config
                            )

                            let profileService = Container.shared.profileService()
                            let profile = try await profileService.fetchProfile(distinctId: distinctId)

                            let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
                            let remoteFlow = try await api.fetchFlow(flowId: flowId)
                            let flow = Flow(remoteFlow: remoteFlow, products: [])

                            let archiveService = FlowArchiver()
                            await archiveService.removeArchive(for: flow.id)

                            let vc = await MainActor.run { () -> FlowViewController in
                                let vc = FlowViewController(flow: flow, archiveService: archiveService)
                                let publishedAt = ISO8601DateFormatter().string(from: Date())
                                let campaign = Campaign(
                                    id: artifact.launchConfig.campaignId ?? "camp-e2e-hosted",
                                    name: "Hosted Artifact E2E",
                                    flowId: flowId,
                                    flowNumber: 1,
                                    flowName: nil,
                                    reentry: .oneTime,
                                    publishedAt: publishedAt,
                                    trigger: .event(EventTriggerConfig(eventName: "test_event", condition: nil)),
                                    goal: nil,
                                    exitPolicy: nil,
                                    conversionAnchor: nil,
                                    campaignType: nil
                                )
                                let journey = Journey(campaign: campaign, distinctId: distinctId)
                                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
                                runner.attach(viewController: vc)

                                let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
                                let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge) { type, payload, _ in
                                    if type == "runtime/ready" {
                                        readySeen?.set(true)
                                    }
                                    if type == "runtime/screen_changed" {
                                        lastScreenId?.set(payload["screenId"] as? String)
                                    }
                                }
                                vc.runtimeDelegate = delegate

                                let testWindow = UIWindow(frame: UIScreen.main.bounds)
                                testWindow.rootViewController = vc
                                testWindow.makeKeyAndVisible()
                                _ = vc.view
                                flowViewController = vc
                                window = testWindow
                                return vc
                            }

                            guard let webView = await MainActor.run(body: { vc.flowWebView }) else {
                                fail("Hosted artifact E2E: FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }

                            guard await waitUntil(timeoutSeconds: 30, condition: { readySeen?.get() == true }) else {
                                fail("Hosted artifact E2E: runtime/ready was not observed")
                                finishOnce()
                                return
                            }

                            for step in artifact.runtimeScript.steps {
                                switch step.type {
                                case "wait_ms":
                                    try await Task.sleep(nanoseconds: UInt64(max(step.ms ?? 0, 0)) * 1_000_000)

                                case "assert_experiment_assignment":
                                    guard let experimentKey = step.experimentKey else {
                                        fail("Hosted artifact E2E: assert_experiment_assignment is missing experimentKey")
                                        finishOnce()
                                        return
                                    }
                                    let assignment = profile.experiments?[experimentKey]
                                    guard let assignment else {
                                        fail("Hosted artifact E2E: missing experiment assignment for key '\(experimentKey)'")
                                        finishOnce()
                                        return
                                    }
                                    if let variantKey = step.variantKey {
                                        guard assignment.variantKey == variantKey else {
                                            fail("Hosted artifact E2E: expected variantKey '\(variantKey)' but got '\(String(describing: assignment.variantKey))'")
                                            finishOnce()
                                            return
                                        }
                                    }
                                    if let isHoldout = step.isHoldout {
                                        guard assignment.isHoldout == isHoldout else {
                                            fail("Hosted artifact E2E: expected isHoldout=\(isHoldout) but got \(String(describing: assignment.isHoldout))")
                                            finishOnce()
                                            return
                                        }
                                    }

                                case "assert_screen":
                                    guard let expectedScreenId = step.screenId else {
                                        fail("Hosted artifact E2E: assert_screen is missing screenId")
                                        finishOnce()
                                        return
                                    }
                                    guard await waitUntil(timeoutSeconds: 30, condition: { lastScreenId?.get() == expectedScreenId }) else {
                                        fail("Hosted artifact E2E: expected current screen '\(expectedScreenId)' but last screen was '\(lastScreenId?.get() ?? "nil")'")
                                        finishOnce()
                                        return
                                    }

                                case "press_button":
                                    guard let componentId = step.componentId else {
                                        fail("Hosted artifact E2E: press_button is missing componentId")
                                        finishOnce()
                                        return
                                    }
                                    let screenId = step.screenId ?? lastScreenId?.get() ?? ""
                                    let escapedComponent = componentId.replacingOccurrences(of: "'", with: "\\'")
                                    let escapedScreen = screenId.replacingOccurrences(of: "'", with: "\\'")
                                    let pressScript = """
                                    (() => {
                                      const selectors = [
                                        '#\(escapedComponent)',
                                        `[data-component-id="\(escapedComponent)"]`,
                                        `[data-nuxie-id="\(escapedComponent)"]`,
                                        `[data-testid="\(escapedComponent)"]`
                                      ];
                                      for (const selector of selectors) {
                                        const node = document.querySelector(selector);
                                        if (node && typeof node.click === 'function') {
                                          node.click();
                                          return 'dom';
                                        }
                                      }
                                      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) {
                                        window.webkit.messageHandlers.bridge.postMessage({
                                          type: 'action/press',
                                          payload: { componentId: '\(escapedComponent)', screenId: '\(escapedScreen)' }
                                        });
                                        return 'bridge';
                                      }
                                      return 'missing';
                                    })()
                                    """
                                    let result = try await evaluateJavaScript(webView, script: pressScript) as? String
                                    guard result == "dom" || result == "bridge" else {
                                        fail("Hosted artifact E2E: button '\(componentId)' was not clickable")
                                        finishOnce()
                                        return
                                    }

                                case "edit_text":
                                    guard let componentId = step.componentId,
                                          let value = step.value else {
                                        fail("Hosted artifact E2E: edit_text is missing componentId or value")
                                        finishOnce()
                                        return
                                    }
                                    let escapedComponent = componentId.replacingOccurrences(of: "'", with: "\\'")
                                    let escapedValue = value.replacingOccurrences(of: "'", with: "\\'")
                                    let editScript = """
                                    (() => {
                                      const selectors = [
                                        '#\(escapedComponent)',
                                        `[data-component-id="\(escapedComponent)"]`,
                                        `[data-nuxie-id="\(escapedComponent)"]`,
                                        `[data-testid="\(escapedComponent)"]`
                                      ];
                                      for (const selector of selectors) {
                                        const node = document.querySelector(selector);
                                        if (node instanceof HTMLInputElement || node instanceof HTMLTextAreaElement) {
                                          node.focus();
                                          node.value = '\(escapedValue)';
                                          node.dispatchEvent(new Event('input', { bubbles: true }));
                                          node.dispatchEvent(new Event('change', { bubbles: true }));
                                          return true;
                                        }
                                      }
                                      return false;
                                    })()
                                    """
                                    let success = try await evaluateJavaScript(webView, script: editScript) as? Bool
                                    guard success == true else {
                                        fail("Hosted artifact E2E: input '\(componentId)' was not editable")
                                        finishOnce()
                                        return
                                    }

                                case "assert_component_visible":
                                    guard let componentId = step.componentId else {
                                        fail("Hosted artifact E2E: assert_component_visible is missing componentId")
                                        finishOnce()
                                        return
                                    }
                                    let escapedComponent = componentId.replacingOccurrences(of: "'", with: "\\'")
                                    let visibleScript = """
                                    (() => {
                                      const selectors = [
                                        '#\(escapedComponent)',
                                        `[data-component-id="\(escapedComponent)"]`,
                                        `[data-nuxie-id="\(escapedComponent)"]`,
                                        `[data-testid="\(escapedComponent)"]`
                                      ];
                                      return selectors.some((selector) => document.querySelector(selector) != null);
                                    })()
                                    """
                                    let isVisible = try await evaluateJavaScript(webView, script: visibleScript) as? Bool
                                    guard isVisible == true else {
                                        fail("Hosted artifact E2E: component '\(componentId)' was not visible")
                                        finishOnce()
                                        return
                                    }

                                case "flush_events":
                                    await eventService.drain()
                                    let didFlush = await eventService.flushEvents()
                                    guard didFlush else {
                                        fail("Hosted artifact E2E: expected flushEvents() to initiate a flush")
                                        finishOnce()
                                        return
                                    }

                                default:
                                    fail("Hosted artifact E2E: unsupported runtime script step '\(step.type)'")
                                    finishOnce()
                                    return
                                }
                            }

                            finishOnce()
                        } catch {
                            fail("Hosted artifact E2E failed: \(error)")
                            finishOnce()
                        }
                    }
                }
            }
        }
    }
}

private func loadHostedArtifactFromEnvironment(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> HostedScenarioArtifact? {
    guard let rawPath = environment["NUXIE_E2E_ARTIFACT_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawPath.isEmpty else {
        return nil
    }

    let rootURL = URL(fileURLWithPath: rawPath)
    let isDirectory = (try? rootURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    let launchConfigURL: URL
    let runtimeScriptURL: URL

    if isDirectory {
        launchConfigURL = rootURL.appendingPathComponent("runtime/launch-config.json")
        runtimeScriptURL = rootURL.appendingPathComponent("runtime/runtime-script.json")
    } else {
        launchConfigURL = rootURL
        runtimeScriptURL = rootURL.deletingLastPathComponent().appendingPathComponent("runtime-script.json")
    }

    let launchData = try Data(contentsOf: launchConfigURL)
    let runtimeScriptData = try Data(contentsOf: runtimeScriptURL)

    return HostedScenarioArtifact(
        launchConfig: try JSONDecoder().decode(HostedArtifactLaunchConfig.self, from: launchData),
        runtimeScript: try JSONDecoder().decode(HostedRuntimeScript.self, from: runtimeScriptData)
    )
}

@MainActor
private func evaluateJavaScript(_ webView: WKWebView, script: String) async throws -> Any? {
    try await withCheckedThrowingContinuation { continuation in
        webView.evaluateJavaScript(script) { result, error in
            if let error {
                continuation.resume(throwing: error)
                return
            }
            continuation.resume(returning: result)
        }
    }
}

private func waitUntil(
    timeoutSeconds: Double,
    condition: @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return false
}

private final class LockedValue<T> {
    private let lock = NSLock()
    private var value: T

    init(_ initialValue: T) {
        value = initialValue
    }

    func set(_ nextValue: T) {
        lock.lock()
        value = nextValue
        lock.unlock()
    }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
