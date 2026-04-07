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
    let eventName: String?
    let properties: [String: AnyCodable]?
    let ms: Int?
    let screenId: String?
    let componentId: String?
    let clickStrategy: String?
    let value: String?
    let experimentKey: String?
    let variantKey: String?
    let isHoldout: Bool?
}

private struct HostedScenarioArtifact {
    let rootURL: URL
    let launchConfig: HostedArtifactLaunchConfig
    let runtimeScript: HostedRuntimeScript
}

private let hostedArtifactPathFallbackURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent(".hosted-e2e-artifact-path")

private struct HostedArtifactDiagnostics: Encodable {
    let generatedAt: String
    let scenarioId: String
    let expectedCampaignId: String?
    let expectedFlowId: String?
    let profileSummary: HostedProfileSummary?
    let triggerDecision: String?
    let triggerError: String?
    let presentedCampaignId: String?
    let presentedFlowId: String?
    let runtimeMessages: [HostedRuntimeMessageTrace]
    let screenTransitions: [String]
    let clickResults: [HostedClickTrace]
    let dismissalReason: String?
    let readySeen: Bool
    let usedJourneyRuntimeDelegate: Bool
}

private struct HostedProfileSummary: Encodable {
    let campaignsCount: Int
    let flowsCount: Int
    let hasExpectedCampaign: Bool
    let hasExpectedFlow: Bool
}

private struct HostedRuntimeMessageTrace: Encodable {
    let type: String
    let screenId: String?
}

private struct HostedClickTrace: Encodable {
    let componentId: String
    let strategy: String
}

final class FlowRuntimeHostedArtifactE2ESpec: QuickSpec {
    override class func spec() {
        describe("Flow Runtime Hosted Artifact E2E") {
            var artifact: HostedScenarioArtifact?
            var artifactLoadError: Error?

            beforeEach {
                artifact = nil
                artifactLoadError = nil
                do {
                    artifact = try loadHostedArtifactFromEnvironment()
                } catch {
                    artifactLoadError = error
                }
            }

            afterEach {
                waitUntil(timeout: .seconds(30)) { done in
                    Task {
                        await NuxieSDK.shared.shutdown()
                        Container.shared.reset()
                        done()
                    }
                }
            }

            it("runs runtime-script.json through the real hosted SDK path") {
                if let artifactLoadError {
                    fail("Hosted artifact E2E failed to load artifact: \(artifactLoadError)")
                    return
                }
                let envArtifactPath = resolveHostedArtifactPath(ProcessInfo.processInfo.environment)
                guard let envArtifactPath, !envArtifactPath.isEmpty else {
                    fail("Hosted artifact E2E requires NUXIE_E2E_ARTIFACT_PATH")
                    return
                }
                guard let artifact else {
                    fail("Hosted artifact E2E could not load artifact at '\(envArtifactPath)'")
                    return
                }
                guard let apiKey = artifact.launchConfig.publicApiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let ingestUrlString = artifact.launchConfig.ingestUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let expectedFlowId = artifact.launchConfig.flowId?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let expectedCampaignId = artifact.launchConfig.campaignId?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let baseURL = URL(string: ingestUrlString),
                      !apiKey.isEmpty,
                      !expectedFlowId.isEmpty,
                      !expectedCampaignId.isEmpty else {
                    fail("Hosted artifact launch-config.json is missing apiKey / ingestUrl / flowId / campaignId")
                    return
                }

                waitUntil(timeout: .seconds(180)) { done in
                    var finished = false

                    func finishOnce() {
                        guard !finished else { return }
                        finished = true
                        done()
                    }

                    Task {
                        let presentationObserver = HostedPresentationObserver()
                        let diagnosticsRecorder = HostedDiagnosticsRecorder()
                        do {
                            await NuxieSDK.shared.shutdown()
                            Container.shared.reset()

                            let windowProvider = HostedArtifactWindowProvider(
                                observer: presentationObserver,
                                recorder: diagnosticsRecorder
                            )

                            func persistDiagnostics() async {
                                await writeHostedDiagnostics(
                                    artifact: artifact,
                                    observer: presentationObserver,
                                    recorder: diagnosticsRecorder
                                )
                            }

                            func failAndFinish(_ message: String) async {
                                await persistDiagnostics()
                                fail(message)
                                finishOnce()
                            }

                            let config = NuxieConfiguration(apiKey: apiKey)
                            config.apiEndpoint = baseURL
                            config.enablePlugins = false
                            config.customStoragePath = FileManager.default.temporaryDirectory
                                .appendingPathComponent("nuxie-e2e-hosted-\(UUID().uuidString)", isDirectory: true)

                            let purchaseDelegate = MockPurchaseDelegate()
                            purchaseDelegate.simulatedDelay = 0
                            purchaseDelegate.purchaseOutcomeOverride = PurchaseOutcome(
                                result: .success,
                                transactionJws: "test-jws",
                                transactionId: "tx-1",
                                originalTransactionId: "otx-1",
                                productId: "hosted-purchase"
                            )
                            config.purchaseDelegate = purchaseDelegate

                            let productService = MockProductService()

                            await MainActor.run {
                                Container.shared.flowPresentationService.register { @MainActor in
                                    FlowPresentationService(windowProvider: windowProvider)
                                }
                            }
                            Container.shared.productService.register { productService }

                            try NuxieSDK.shared.setup(with: config)

                            let distinctId = artifact.launchConfig.distinctId?.isEmpty == false
                                ? artifact.launchConfig.distinctId!
                                : "scenario-\(artifact.launchConfig.scenarioId)"
                            NuxieSDK.shared.identify(distinctId)

                            _ = await Container.shared.eventService().getRecentEvents(limit: 1)

                            let profile = try await NuxieSDK.shared.refreshProfile()
                            diagnosticsRecorder.profileSummary.set(
                                HostedProfileSummary(
                                    campaignsCount: profile.campaigns.count,
                                    flowsCount: profile.flows.count,
                                    hasExpectedCampaign: profile.campaigns.contains(where: { $0.id == expectedCampaignId && $0.flowId == expectedFlowId }),
                                    hasExpectedFlow: profile.flows.contains(where: { $0.id == expectedFlowId })
                                )
                            )
                            guard profile.campaigns.contains(where: { $0.id == expectedCampaignId && $0.flowId == expectedFlowId }) else {
                                await failAndFinish("Hosted artifact E2E: /profile did not contain campaign '\(expectedCampaignId)' for flow '\(expectedFlowId)'")
                                return
                            }

                            guard let hostedFlow = profile.flows.first(where: { $0.id == expectedFlowId }) else {
                                await failAndFinish("Hosted artifact E2E: /profile did not contain flow '\(expectedFlowId)'")
                                return
                            }

                            let productIds = extractPurchaseActionProductIds(from: hostedFlow)
                            productService.mockProducts = productIds.map { productId in
                                MockStoreProduct(
                                    id: productId,
                                    displayName: productId,
                                    price: 9.99,
                                    displayPrice: "$9.99",
                                    productType: .autoRenewable
                                )
                            }
                            if let firstProductId = productIds.first {
                                purchaseDelegate.purchaseOutcomeOverride = PurchaseOutcome(
                                    result: .success,
                                    transactionJws: "test-jws",
                                    transactionId: "tx-1",
                                    originalTransactionId: "otx-1",
                                    productId: firstProductId
                                )
                            }

                            for step in artifact.runtimeScript.steps {
                                switch step.type {
                                case "wait_ms":
                                    try await Task.sleep(nanoseconds: UInt64(max(step.ms ?? 0, 0)) * 1_000_000)

                                case "trigger_event":
                                    guard let eventName = step.eventName, !eventName.isEmpty else {
                                        await failAndFinish("Hosted artifact E2E: trigger_event is missing eventName")
                                        return
                                    }
                                    let observedDecision = LockedValue<String?>(nil)
                                    let observedFlowShown = LockedValue<JourneyRef?>(nil)
                                    let properties = step.properties?.mapValues(\.value)
                                    let handle = NuxieSDK.shared.trigger(eventName, properties: properties)
                                    let updatesTask = Task {
                                        for await update in handle {
                                            switch update {
                                            case .decision(let decision):
                                                switch decision {
                                                case .noMatch:
                                                    observedDecision.set("no_match")
                                                case .suppressed:
                                                    observedDecision.set("suppressed")
                                                case .flowShown(let ref):
                                                    observedDecision.set("flow_shown")
                                                    observedFlowShown.set(ref)
                                                case .journeyStarted(let ref):
                                                    observedDecision.set("journey_started")
                                                    observedFlowShown.set(ref)
                                                case .journeyResumed(let ref):
                                                    observedDecision.set("journey_resumed")
                                                    observedFlowShown.set(ref)
                                                case .allowedImmediate:
                                                    observedDecision.set("allowed_immediate")
                                                case .deniedImmediate:
                                                    observedDecision.set("denied_immediate")
                                                }
                                            case .error(let error):
                                                diagnosticsRecorder.triggerError.set("\(error.code): \(error.message)")
                                            default:
                                                break
                                            }
                                        }
                                    }

                                    guard await waitUntil(timeoutSeconds: 30, condition: {
                                        presentationObserver.flowViewController.get() != nil ||
                                        diagnosticsRecorder.triggerError.get() != nil ||
                                        observedDecision.get() == "no_match" ||
                                        observedDecision.get() == "suppressed"
                                    }) else {
                                        handle.cancel()
                                        _ = await updatesTask.result
                                        diagnosticsRecorder.triggerDecision.set(observedDecision.get())
                                        if let triggerError = diagnosticsRecorder.triggerError.get() {
                                            await failAndFinish("Hosted artifact E2E: trigger_event '\(eventName)' failed with \(triggerError)")
                                            return
                                        }
                                        await failAndFinish("Hosted artifact E2E: trigger_event '\(eventName)' did not present a flow")
                                        return
                                    }

                                    handle.cancel()
                                    _ = await updatesTask.result
                                    diagnosticsRecorder.triggerDecision.set(observedDecision.get())
                                    if let triggerError = diagnosticsRecorder.triggerError.get() {
                                        await failAndFinish("Hosted artifact E2E: trigger_event '\(eventName)' failed with \(triggerError)")
                                        return
                                    }
                                    if let ref = observedFlowShown.get() {
                                        diagnosticsRecorder.presentedCampaignId.set(ref.campaignId)
                                        diagnosticsRecorder.presentedFlowId.set(ref.flowId)
                                    }

                                    if let failureDecision = observedDecision.get(), failureDecision == "no_match" || failureDecision == "suppressed" {
                                        await failAndFinish("Hosted artifact E2E: trigger_event '\(eventName)' resolved to \(failureDecision)")
                                        return
                                    }

                                    if let ref = observedFlowShown.get() {
                                        guard ref.campaignId == expectedCampaignId else {
                                            await failAndFinish("Hosted artifact E2E: trigger_event '\(eventName)' started unexpected campaign '\(ref.campaignId)'")
                                            return
                                        }
                                    }

                                    guard presentationObserver.usedJourneyRuntimeDelegate.get() == true else {
                                        await failAndFinish("Hosted artifact E2E: flow was not presented through the journey runtime delegate path")
                                        return
                                    }

                                case "assert_experiment_assignment":
                                    guard let experimentKey = step.experimentKey else {
                                        await failAndFinish("Hosted artifact E2E: assert_experiment_assignment is missing experimentKey")
                                        return
                                    }
                                    let assignment = profile.experiments?[experimentKey]
                                    guard let assignment else {
                                        await failAndFinish("Hosted artifact E2E: missing experiment assignment for key '\(experimentKey)'")
                                        return
                                    }
                                    if let variantKey = step.variantKey {
                                        guard assignment.variantKey == variantKey else {
                                            await failAndFinish("Hosted artifact E2E: expected variantKey '\(variantKey)' but got '\(String(describing: assignment.variantKey))'")
                                            return
                                        }
                                    }
                                    if let isHoldout = step.isHoldout {
                                        guard assignment.isHoldout == isHoldout else {
                                            await failAndFinish("Hosted artifact E2E: expected isHoldout=\(isHoldout) but got \(String(describing: assignment.isHoldout))")
                                            return
                                        }
                                    }

                                case "assert_screen":
                                    guard let expectedScreenId = step.screenId else {
                                        await failAndFinish("Hosted artifact E2E: assert_screen is missing screenId")
                                        return
                                    }
                                    guard await waitUntil(timeoutSeconds: 30, condition: {
                                        presentationObserver.readySeen.get() == true &&
                                        presentationObserver.lastScreenId.get() == expectedScreenId
                                    }) else {
                                        await failAndFinish("Hosted artifact E2E: expected current screen '\(expectedScreenId)' but last screen was '\(presentationObserver.lastScreenId.get() ?? "nil")'")
                                        return
                                    }

                                case "press_button":
                                    guard let componentId = step.componentId else {
                                        await failAndFinish("Hosted artifact E2E: press_button is missing componentId")
                                        return
                                    }
                                    guard let webView = await currentWebView(observer: presentationObserver) else {
                                        await failAndFinish("Hosted artifact E2E: no active FlowViewController/webView for press_button")
                                        return
                                    }
                                    let screenId = step.screenId ?? presentationObserver.lastScreenId.get() ?? ""
                                    let escapedComponent = componentId.replacingOccurrences(of: "'", with: "\\'")
                                    let escapedScreen = screenId.replacingOccurrences(of: "'", with: "\\'")
                                    let preferredStrategy = step.clickStrategy ?? "auto"
                                    let pressScript = """
                                    (() => {
                                      const preferred = '\(preferredStrategy)';
                                      const selectors = [
                                        '#\(escapedComponent)',
                                        `[data-component-id="\(escapedComponent)"]`,
                                        `[data-nuxie-node-id="\(escapedComponent)"]`,
                                        `[data-nuxie-id="\(escapedComponent)"]`,
                                        `[data-testid="\(escapedComponent)"]`
                                      ];
                                      const tryDom = () => {
                                        for (const selector of selectors) {
                                          const node = document.querySelector(selector);
                                          if (node && typeof node.click === 'function') {
                                            node.click();
                                            return 'dom';
                                          }
                                        }
                                        return null;
                                      };
                                      const tryBridge = () => {
                                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) {
                                          window.webkit.messageHandlers.bridge.postMessage({
                                            type: 'action/press',
                                            payload: { componentId: '\(escapedComponent)', screenId: '\(escapedScreen)' }
                                          });
                                          return 'bridge';
                                        }
                                        return null;
                                      };
                                      if (preferred === 'dom') return tryDom() || 'missing';
                                      if (preferred === 'bridge') return tryBridge() || 'missing';
                                      return tryDom() || tryBridge() || 'missing';
                                    })()
                                    """
                                    let result = try await evaluateJavaScript(webView, script: pressScript) as? String
                                    guard result == "dom" || result == "bridge" else {
                                        await failAndFinish("Hosted artifact E2E: button '\(componentId)' was not clickable")
                                        return
                                    }
                                    diagnosticsRecorder.appendClick(componentId: componentId, strategy: result ?? "unknown")

                                case "edit_text":
                                    guard let componentId = step.componentId,
                                          let value = step.value else {
                                        await failAndFinish("Hosted artifact E2E: edit_text is missing componentId or value")
                                        return
                                    }
                                    guard let webView = await currentWebView(observer: presentationObserver) else {
                                        await failAndFinish("Hosted artifact E2E: no active FlowViewController/webView for edit_text")
                                        return
                                    }
                                    let escapedComponent = componentId.replacingOccurrences(of: "'", with: "\\'")
                                    let escapedValue = value.replacingOccurrences(of: "'", with: "\\'")
                                    let editScript = """
                                    (() => {
                                      const selectors = [
                                        '#\(escapedComponent)',
                                        `[data-component-id="\(escapedComponent)"]`,
                                        `[data-nuxie-node-id="\(escapedComponent)"]`,
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
                                        await failAndFinish("Hosted artifact E2E: input '\(componentId)' was not editable")
                                        return
                                    }

                                case "assert_component_visible":
                                    guard let componentId = step.componentId else {
                                        await failAndFinish("Hosted artifact E2E: assert_component_visible is missing componentId")
                                        return
                                    }
                                    guard let webView = await currentWebView(observer: presentationObserver) else {
                                        await failAndFinish("Hosted artifact E2E: no active FlowViewController/webView for assert_component_visible")
                                        return
                                    }
                                    let escapedComponent = componentId.replacingOccurrences(of: "'", with: "\\'")
                                    let visibleScript = """
                                    (() => {
                                      const selectors = [
                                        '#\(escapedComponent)',
                                        `[data-component-id="\(escapedComponent)"]`,
                                        `[data-nuxie-node-id="\(escapedComponent)"]`,
                                        `[data-nuxie-id="\(escapedComponent)"]`,
                                        `[data-testid="\(escapedComponent)"]`
                                      ];
                                      return selectors.some((selector) => document.querySelector(selector) != null);
                                    })()
                                    """
                                    let isVisible = try await evaluateJavaScript(webView, script: visibleScript) as? Bool
                                    guard isVisible == true else {
                                        await failAndFinish("Hosted artifact E2E: component '\(componentId)' was not visible")
                                        return
                                    }

                                case "assert_dismissed":
                                    guard await waitUntil(timeoutSeconds: 30, condition: {
                                        presentationObserver.isPresented.get() == false
                                    }) else {
                                        await failAndFinish("Hosted artifact E2E: flow did not dismiss")
                                        return
                                    }

                                case "flush_events":
                                    let eventService = Container.shared.eventService()
                                    await eventService.drain()
                                    let didFlush = await eventService.flushEvents()
                                    guard didFlush else {
                                        await failAndFinish("Hosted artifact E2E: expected flushEvents() to initiate a flush")
                                        return
                                    }

                                default:
                                    await failAndFinish("Hosted artifact E2E: unsupported runtime script step '\(step.type)'")
                                    return
                                }
                            }

                            await persistDiagnostics()
                            finishOnce()
                        } catch {
                            await writeHostedDiagnostics(
                                artifact: artifact,
                                observer: presentationObserver,
                                recorder: diagnosticsRecorder
                            )
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
    guard let rawPath = resolveHostedArtifactPath(environment),
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
        rootURL: isDirectory ? rootURL : rootURL.deletingLastPathComponent(),
        launchConfig: try JSONDecoder().decode(HostedArtifactLaunchConfig.self, from: launchData),
        runtimeScript: try JSONDecoder().decode(HostedRuntimeScript.self, from: runtimeScriptData)
    )
}

private func resolveHostedArtifactPath(_ environment: [String: String]) -> String? {
    if let rawPath = environment["NUXIE_E2E_ARTIFACT_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !rawPath.isEmpty {
        return rawPath
    }

    guard let fallbackContents = try? String(contentsOf: hostedArtifactPathFallbackURL, encoding: .utf8) else {
        return nil
    }
    let trimmed = fallbackContents.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
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

@MainActor
private func currentWebView(observer: HostedPresentationObserver) -> WKWebView? {
    observer.flowViewController.get()?.flowWebView
}

private func extractPurchaseActionProductIds(from flow: RemoteFlow) -> [String] {
    var productIds = Set<String>()

    for interactions in flow.interactions.values {
        for interaction in interactions {
            for action in interaction.actions {
                guard case .purchase(let purchaseAction) = action else { continue }
                if let productId = purchaseAction.productId.value as? String, !productId.isEmpty {
                    productIds.insert(productId)
                }
            }
        }
    }

    for productId in extractPaywallProductIds(from: flow) {
        productIds.insert(productId)
    }

    return Array(productIds).sorted()
}

private func extractPaywallProductIds(from flow: RemoteFlow) -> Set<String> {
    guard let viewModelInstances = flow.viewModelInstances else { return [] }

    var productIds = Set<String>()
    let instancesById = Dictionary(uniqueKeysWithValues: viewModelInstances.map { ($0.instanceId, $0) })

    for instance in viewModelInstances {
        guard let paywall = decodeDictionary(instance.values["paywall"]?.value) else { continue }

        if let selectedProductId = paywall["selectedProductId"] as? String, !selectedProductId.isEmpty {
            productIds.insert(selectedProductId)
        }

        guard let products = decodeArray(paywall["products"]) else { continue }
        for product in products {
            guard let productRef = decodeDictionary(product),
                  let vmInstanceId = productRef["vmInstanceId"] as? String,
                  let productInstance = instancesById[vmInstanceId],
                  let productId = productInstance.values["productId"]?.value as? String,
                  !productId.isEmpty else {
                continue
            }
            productIds.insert(productId)
        }
    }

    return productIds
}

private func decodeDictionary(_ value: Any?) -> [String: Any]? {
    if let dictionary = value as? [String: Any] {
        return dictionary
    }
    if let dictionary = value as? [String: AnyCodable] {
        return dictionary.mapValues(\.value)
    }
    return nil
}

private func decodeArray(_ value: Any?) -> [Any]? {
    if let array = value as? [Any] {
        return array
    }
    if let array = value as? [AnyCodable] {
        return array.map(\.value)
    }
    return nil
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

private final class HostedDiagnosticsRecorder {
    let profileSummary = LockedValue<HostedProfileSummary?>(nil)
    let triggerDecision = LockedValue<String?>(nil)
    let triggerError = LockedValue<String?>(nil)
    let presentedCampaignId = LockedValue<String?>(nil)
    let presentedFlowId = LockedValue<String?>(nil)
    let runtimeMessages = LockedValue<[HostedRuntimeMessageTrace]>([])
    let screenTransitions = LockedValue<[String]>([])
    let clickResults = LockedValue<[HostedClickTrace]>([])

    func appendRuntimeMessage(type: String, screenId: String?) {
        var next = runtimeMessages.get()
        next.append(HostedRuntimeMessageTrace(type: type, screenId: screenId))
        runtimeMessages.set(next)
    }

    func appendScreenTransition(_ screenId: String) {
        var next = screenTransitions.get()
        next.append(screenId)
        screenTransitions.set(next)
    }

    func appendClick(componentId: String, strategy: String) {
        var next = clickResults.get()
        next.append(HostedClickTrace(componentId: componentId, strategy: strategy))
        clickResults.set(next)
    }
}

private final class HostedPresentationObserver {
    let flowViewController = LockedValue<FlowViewController?>(nil)
    let readySeen = LockedValue(false)
    let lastScreenId = LockedValue<String?>(nil)
    let isPresented = LockedValue(false)
    let usedJourneyRuntimeDelegate = LockedValue(false)
    let dismissalReason = LockedValue<String?>(nil)
}

private func writeHostedDiagnostics(
    artifact: HostedScenarioArtifact,
    observer: HostedPresentationObserver,
    recorder: HostedDiagnosticsRecorder
) async {
    let diagnostics = HostedArtifactDiagnostics(
        generatedAt: ISO8601DateFormatter().string(from: Date()),
        scenarioId: artifact.launchConfig.scenarioId,
        expectedCampaignId: artifact.launchConfig.campaignId,
        expectedFlowId: artifact.launchConfig.flowId,
        profileSummary: recorder.profileSummary.get(),
        triggerDecision: recorder.triggerDecision.get(),
        triggerError: recorder.triggerError.get(),
        presentedCampaignId: recorder.presentedCampaignId.get(),
        presentedFlowId: recorder.presentedFlowId.get(),
        runtimeMessages: recorder.runtimeMessages.get(),
        screenTransitions: recorder.screenTransitions.get(),
        clickResults: recorder.clickResults.get(),
        dismissalReason: observer.dismissalReason.get(),
        readySeen: observer.readySeen.get(),
        usedJourneyRuntimeDelegate: observer.usedJourneyRuntimeDelegate.get()
    )

    let artifactsURL = artifact.rootURL.appendingPathComponent("artifacts", isDirectory: true)
    let diagnosticsURL = artifactsURL.appendingPathComponent("ios-hosted-diagnostics.json")

    do {
        try FileManager.default.createDirectory(
            at: artifactsURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(diagnostics)
        try data.write(to: diagnosticsURL, options: .atomic)
    } catch {
        print("Failed to write hosted diagnostics: \(error)")
    }
}

private final class HostedArtifactWindowProvider: WindowProviderProtocol {
    private let observer: HostedPresentationObserver
    private let recorder: HostedDiagnosticsRecorder

    init(observer: HostedPresentationObserver, recorder: HostedDiagnosticsRecorder) {
        self.observer = observer
        self.recorder = recorder
    }

    func canPresentWindow() -> Bool { true }

    func createPresentationWindow() -> PresentationWindowProtocol? {
        HostedArtifactPresentationWindow(observer: observer, recorder: recorder)
    }
}

@MainActor
private final class HostedArtifactPresentationWindow: PresentationWindowProtocol {
    private let observer: HostedPresentationObserver
    private let recorder: HostedDiagnosticsRecorder
    private let window: UIWindow
    private let rootViewController: UIViewController
    private var retainedDelegate: MultiplexingRuntimeDelegate?

    init(observer: HostedPresentationObserver, recorder: HostedDiagnosticsRecorder) {
        self.observer = observer
        self.recorder = recorder
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
        } else {
            window = UIWindow(frame: UIScreen.main.bounds)
        }
        rootViewController = UIViewController()
        rootViewController.view.backgroundColor = .clear
        window.rootViewController = rootViewController
        window.windowLevel = .alert
        window.backgroundColor = .clear
    }

    func present(_ viewController: NuxiePlatformViewController) async {
        if let flowViewController = viewController as? FlowViewController {
            observer.flowViewController.set(flowViewController)
            observer.usedJourneyRuntimeDelegate.set(flowViewController.runtimeDelegate != nil)
            let delegate = MultiplexingRuntimeDelegate(
                primary: flowViewController.runtimeDelegate,
                observer: observer,
                recorder: recorder
            )
            retainedDelegate = delegate
            flowViewController.runtimeDelegate = delegate
            let originalOnClose = flowViewController.onClose
            flowViewController.onClose = { [weak observer] reason in
                observer?.dismissalReason.set(String(describing: reason))
                originalOnClose?(reason)
            }
        }

        observer.isPresented.set(true)
        window.makeKeyAndVisible()
        rootViewController.present(viewController, animated: false)
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, rootViewController.presentedViewController == nil {
            await Task.yield()
        }
    }

    func dismiss() async {
        guard rootViewController.presentedViewController != nil else {
            observer.isPresented.set(false)
            return
        }
        rootViewController.dismiss(animated: false)
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, rootViewController.presentedViewController != nil {
            await Task.yield()
        }
        observer.isPresented.set(false)
    }

    func destroy() {
        observer.isPresented.set(false)
        window.isHidden = true
        window.rootViewController = nil
        retainedDelegate = nil
    }

    var isPresenting: Bool {
        rootViewController.presentedViewController != nil
    }
}

private final class MultiplexingRuntimeDelegate:
    FlowRuntimeDelegate,
    NotificationPermissionEventReceiver,
    RequestPermissionEventReceiver,
    TrackingPermissionEventReceiver
{
    private let primary: FlowRuntimeDelegate?
    private let observer: HostedPresentationObserver
    private let recorder: HostedDiagnosticsRecorder

    init(
        primary: FlowRuntimeDelegate?,
        observer: HostedPresentationObserver,
        recorder: HostedDiagnosticsRecorder
    ) {
        self.primary = primary
        self.observer = observer
        self.recorder = recorder
    }

    func flowViewController(
        _ controller: FlowViewController,
        didReceiveRuntimeMessage type: String,
        payload: [String : Any],
        id: String?
    ) {
        recorder.appendRuntimeMessage(type: type, screenId: payload["screenId"] as? String)
        if type == "runtime/ready" {
            observer.readySeen.set(true)
        }
        if type == "runtime/screen_changed" {
            let screenId = payload["screenId"] as? String
            observer.lastScreenId.set(screenId)
            if let screenId {
                recorder.appendScreenTransition(screenId)
            }
        }
        primary?.flowViewController(controller, didReceiveRuntimeMessage: type, payload: payload, id: id)
    }

    func flowViewController(
        _ controller: FlowViewController,
        didSendRuntimeMessage type: String,
        payload: [String : Any],
        replyTo: String?
    ) {
        primary?.flowViewController(controller, didSendRuntimeMessage: type, payload: payload, replyTo: replyTo)
    }

    func flowViewControllerDidRequestDismiss(_ controller: FlowViewController, reason: CloseReason) {
        observer.dismissalReason.set(String(describing: reason))
        primary?.flowViewControllerDidRequestDismiss(controller, reason: reason)
    }

    func flowViewController(
        _ controller: FlowViewController,
        didResolveNotificationPermissionEvent eventName: String,
        properties: [String : Any],
        journeyId: String
    ) {
        (primary as? NotificationPermissionEventReceiver)?
            .flowViewController(controller, didResolveNotificationPermissionEvent: eventName, properties: properties, journeyId: journeyId)
    }

    func flowViewController(
        _ controller: FlowViewController,
        didResolveTrackingPermissionEvent eventName: String,
        properties: [String : Any],
        journeyId: String
    ) {
        (primary as? TrackingPermissionEventReceiver)?
            .flowViewController(controller, didResolveTrackingPermissionEvent: eventName, properties: properties, journeyId: journeyId)
    }

    func flowViewController(
        _ controller: FlowViewController,
        didResolveRequestPermissionEvent eventName: String,
        properties: [String : Any],
        journeyId: String
    ) {
        (primary as? RequestPermissionEventReceiver)?
            .flowViewController(controller, didResolveRequestPermissionEvent: eventName, properties: properties, journeyId: journeyId)
    }

    func flowViewController(
        _ controller: FlowViewController,
        didIgnoreUnsupportedRequestPermissionType permissionType: String,
        journeyId: String
    ) {
        (primary as? RequestPermissionEventReceiver)?
            .flowViewController(controller, didIgnoreUnsupportedRequestPermissionType: permissionType, journeyId: journeyId)
    }
}
