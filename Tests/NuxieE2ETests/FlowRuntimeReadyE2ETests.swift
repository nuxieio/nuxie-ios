import Foundation
import Quick
import Nimble
import UIKit
import WebKit
import FactoryKit
@testable import Nuxie

final class FlowRuntimeReadyE2ESpec: QuickSpec {
    override class func spec() {
        describe("E2E flow runtime ready") {
            var server: LocalHTTPServer?

            var apiKey: String = "pk_test_e2e_local"
            var baseURL: URL = URL(string: "http://127.0.0.1:8084")!
            var flowId: String = "flow_e2e_ready"

            var flowViewController: FlowViewController?
            var runtimeDelegate: FlowRuntimeDelegate?
            var window: UIWindow?
            var requestLog: LockedArray<String>?
            var batchBodies: LockedArray<Data>?

            func makeCampaign(flowId: String) -> Campaign {
                let publishedAt = ISO8601DateFormatter().string(from: Date())
                return Campaign(
                    id: "camp-e2e-1",
                    name: "E2E Campaign",
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
            }

            beforeEach {
                flowViewController = nil
                runtimeDelegate = nil
                window = nil
                requestLog = LockedArray<String>()
                batchBodies = LockedArray<Data>()

                let env = ProcessInfo.processInfo.environment
                let envApiKey = env["NUXIE_E2E_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let envIngestUrl = env["NUXIE_E2E_INGEST_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let envFlowId = env["NUXIE_E2E_FLOW_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)

                let hasEnvConfig = (envApiKey?.isEmpty == false)
                    && (envIngestUrl?.isEmpty == false)
                    && (envFlowId?.isEmpty == false)

                if hasEnvConfig, let ingestUrl = URL(string: envIngestUrl!) {
                    apiKey = envApiKey!
                    baseURL = ingestUrl
                    flowId = envFlowId!
                    server = nil
                    return
                }

	                server = try? LocalHTTPServer { request in
	                    requestLog?.append("\(request.method) \(request.path)")
	                    if request.method == "POST", request.path.hasSuffix("/batch") {
	                        batchBodies?.append(request.body)

	                        // Best-effort count for nicer logs/debugging.
	                        let decoded = decodeMaybeGzippedJSON(request.body)
	                        let batchCount = ((decoded as? [String: Any])?["batch"] as? [Any])?.count ?? 0
	                        let response = BatchResponse(
	                            status: "ok",
	                            processed: batchCount,
	                            failed: 0,
	                            total: batchCount,
	                            errors: nil
	                        )
	                        let json = (try? JSONEncoder().encode(response))
	                            ?? Data("{\"status\":\"ok\",\"processed\":0,\"failed\":0,\"total\":0}".utf8)
	                        return LocalHTTPServer.Response.json(json)
	                    }
	                    if (request.method == "POST" || request.method == "GET"), request.path == "/profile" {
	                        var requestedDistinctId: String? = request.query["distinct_id"]
	                        if requestedDistinctId == nil, !request.body.isEmpty {
	                            if let profileRequest = try? JSONDecoder().decode(ProfileRequest.self, from: request.body) {
	                                requestedDistinctId = profileRequest.distinctId
	                            }
	                        }

	                        let distinctId = requestedDistinctId ?? "unknown"
	                        let variantKey = distinctId.hasSuffix("-b") ? "b" : "a"
	                        let assignment = ExperimentAssignment(
	                            experimentKey: "exp-1",
	                            variantKey: variantKey,
	                            status: "running",
	                            isHoldout: false
	                        )
	                        let response = ProfileResponse(
	                            campaigns: [],
	                            segments: [],
	                            flows: [],
	                            userProperties: nil,
	                            experiments: ["exp-1": assignment],
	                            features: nil,
	                            journeys: nil
	                        )
	                        let json = (try? JSONEncoder().encode(response)) ?? Data("{}".utf8)
	                        return LocalHTTPServer.Response.json(json)
	                    }
	                    if request.method == "GET", request.path.hasPrefix("/flows/") {
	                        let reqFlowId = request.path.replacingOccurrences(of: "/flows/", with: "")
	                        let isExperimentFlow = reqFlowId.hasPrefix("flow_e2e_experiment_")
	                        let host = request.headers["host"] ?? "127.0.0.1"
                        // Serve a per-flow bundle root to avoid cache collisions and to more closely
                        // match real bundle shapes (base URL + manifest-relative paths).
                        let bundleBaseUrl = "http://\(host)/bundles/\(reqFlowId)/"

                        let manifest = BuildManifest(
                            totalFiles: 1,
                            totalSize: 0,
                            contentHash: "e2e-ready-\(reqFlowId)",
                            files: [
                                BuildFile(path: "index.html", size: 0, contentType: "text/html")
                            ]
                        )

                        let remoteFlow: RemoteFlow
                        if isExperimentFlow {
                            let variantA = ExperimentVariant(
                                id: "a",
                                name: "A",
                                percentage: 50,
                                actions: [
                                    .navigate(NavigateAction(screenId: "screen-a"))
                                ]
                            )
                            let variantB = ExperimentVariant(
                                id: "b",
                                name: "B",
                                percentage: 50,
                                actions: [
                                    .navigate(NavigateAction(screenId: "screen-b"))
                                ]
                            )
                            let experiment = ExperimentAction(
                                experimentId: "exp-1",
                                variants: [variantA, variantB]
                            )

                            remoteFlow = RemoteFlow(
                                id: reqFlowId,
                                bundle: FlowBundleRef(url: bundleBaseUrl, manifest: manifest),
                                screens: [
                                    RemoteFlowScreen(
                                        id: "screen-entry",
                                        defaultViewModelId: nil,
                                        defaultInstanceId: nil
                                    ),
                                    RemoteFlowScreen(
                                        id: "screen-a",
                                        defaultViewModelId: nil,
                                        defaultInstanceId: nil
                                    ),
                                    RemoteFlowScreen(
                                        id: "screen-b",
                                        defaultViewModelId: nil,
                                        defaultInstanceId: nil
                                    )
                                ],
                                interactions: [
                                    "tap": [
                                        Interaction(
                                            id: "int-tap",
                                            trigger: .tap,
                                            actions: [
                                                .experiment(experiment)
                                            ],
                                            enabled: true
                                        )
                                    ]
                                ],
                                viewModels: [],
                                viewModelInstances: nil,
                                converters: nil
                            )
                        } else {
                            remoteFlow = RemoteFlow(
                                id: reqFlowId,
                                bundle: FlowBundleRef(url: bundleBaseUrl, manifest: manifest),
                                screens: [
                                    RemoteFlowScreen(
                                        id: "screen-1",
                                        defaultViewModelId: "vm-1",
                                        defaultInstanceId: nil
                                    )
                                ],
                                interactions: [
                                    "tap": [
                                        Interaction(
                                            id: "int-tap",
                                            trigger: .tap,
                                            actions: [
                                                .setViewModel(
                                                    SetViewModelAction(
                                                        path: .ids(VmPathIds(pathIds: [0, 1])),
                                                        value: AnyCodable(["literal": "world"] as [String: Any])
                                                    )
                                                )
                                            ],
                                            enabled: true
                                        )
                                    ]
                                ],
                                viewModels: [
                                    ViewModel(
                                        id: "vm-1",
                                        name: "VM",
                                        viewModelPathId: 0,
                                        properties: [
                                            "title": ViewModelProperty(
                                                type: .string,
                                                propertyId: 1,
                                                defaultValue: AnyCodable("hello"),
                                                required: nil,
                                                enumValues: nil,
                                                itemType: nil,
                                                schema: nil,
                                                viewModelId: nil,
                                                validation: nil
                                            )
                                        ]
                                    )
                                ],
                                viewModelInstances: nil,
                                converters: nil
                            )
                        }

                        let encoder = JSONEncoder()
                        let json = (try? encoder.encode(remoteFlow)) ?? Data("{}".utf8)
                        return LocalHTTPServer.Response.json(json)
                    }

                    if request.method == "GET", request.path.hasPrefix("/bundles/") {
                        let html = """
                        <!doctype html>
                        <html>
                          <head>
                            <meta charset="utf-8" />
                            <meta name="viewport" content="width=device-width, initial-scale=1" />
                            <title>Nuxie E2E Ready</title>
                          </head>
                          <body>
                            <div id="status">loading</div>
                            <div id="screen-id">(unset)</div>
                            <div id="vm-text">(unset)</div>
                            <button id="tap" type="button">Tap</button>
                            <script>
                              (function(){
                                // Minimal runtime surface for Phase 0 + 1 + 2:
                                // - Provide window.nuxie._handleHostMessage (host -> web)
                                // - Emit runtime/ready and runtime/screen_changed (web -> host)
                                // - Reflect runtime/navigate into the DOM
                                // - Apply runtime/view_model_init + runtime/view_model_patch into the DOM
                                // - Emit a deterministic action/tap from a button click

                                function post(type, payload) {
                                  try {
                                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) {
                                      window.webkit.messageHandlers.bridge.postMessage({ type: type, payload: payload || {} });
                                      return true;
                                    }
                                  } catch (e) {}
                                  return false;
                                }

                                function setScreenId(value) {
                                  try {
                                    var el = document.getElementById("screen-id");
                                    if (!el) return;
                                    if (value === null || value === undefined) {
                                      el.textContent = "(null)";
                                    } else {
                                      el.textContent = String(value);
                                    }
                                  } catch (e) {}
                                }

                                function setVmText(value) {
                                  try {
                                    var el = document.getElementById("vm-text");
                                    if (!el) return;
                                    if (value === null || value === undefined) {
                                      el.textContent = "(null)";
                                    } else {
                                      el.textContent = String(value);
                                    }
                                  } catch (e) {}
                                }

                                window.nuxie = {
                                  _handleHostMessage: function(envelope) {
                                    try {
                                      if (!envelope || !envelope.type) return;
                                      if (envelope.type === "runtime/navigate") {
                                        var screenId = (envelope.payload && envelope.payload.screenId) || null;
                                        window.__nuxieScreenId = screenId;
                                        setScreenId(screenId);
                                        post("runtime/screen_changed", { screenId: screenId });
                                        return;
                                      }
                                      if (envelope.type === "runtime/view_model_init") {
                                        var instances = envelope.payload && envelope.payload.instances;
                                        var first = instances && instances[0];
                                        var title = first && first.values && first.values.title;
                                        if (title !== undefined) setVmText(title);
                                        return;
                                      }
                                      if (envelope.type === "runtime/view_model_patch") {
                                        if (envelope.payload && Object.prototype.hasOwnProperty.call(envelope.payload, "value")) {
                                          setVmText(envelope.payload.value);
                                        }
                                        return;
                                      }
                                    } catch (e) {}
                                  }
                                };

                                try {
                                  document.getElementById("tap").addEventListener("click", function() {
                                    post("action/tap", { componentId: "tap", screenId: window.__nuxieScreenId || null });
                                  });
                                } catch (e) {}

                                function sendReadyOnce() {
                                  if (post("runtime/ready", { version: "e2e" })) {
                                    document.getElementById("status").textContent = "ready-sent";
                                    return true;
                                  }
                                  return false;
                                }
                                var tries = 0;
                                var readyTimer = setInterval(function() {
                                  tries++;
                                  if (sendReadyOnce() || tries > 200) clearInterval(readyTimer);
                                }, 50);
                              })();
                            </script>
                          </body>
                        </html>
                        """
                        return LocalHTTPServer.Response.html(html)
                    }

                    if request.method == "GET", request.path == "/favicon.ico" {
                        return LocalHTTPServer.Response(statusCode: 204, headers: [:], body: Data())
                    }

                    return LocalHTTPServer.Response.text("Not Found", statusCode: 404)
                }

                guard let server else {
                    fail("Failed to start LocalHTTPServer for E2E test")
                    return
                }

                apiKey = "pk_test_e2e_local"
                baseURL = server.baseURL
                flowId = "flow_e2e_ready_\(UUID().uuidString)"
            }

            afterEach {
                server?.stop()
                server = nil
                flowViewController = nil
                runtimeDelegate = nil
                window?.isHidden = true
                window?.rootViewController = nil
                window = nil
                requestLog = nil
                batchBodies = nil
            }

            it("fetches /flows/:id, receives runtime/ready, and completes a navigate→screen_changed handshake") {
                let messages = LockedArray<String>()
                let expectedScreenId = LockedValue<String?>(nil)
                let screenChangedId = LockedValue<String?>(nil)

                waitUntil(timeout: .seconds(25)) { done in
                    var finished = false
                    var didReceiveReady = false
                    runtimeDelegate = CapturingRuntimeDelegate(onMessage: { type, payload, _ in
                        let payloadKeys = payload.keys.sorted().joined(separator: ",")
                        messages.append("\(type) keys=[\(payloadKeys)]")

                        if type == "runtime/ready" {
                            didReceiveReady = true
                            // Drive the smallest "real runtime" contract: host -> web navigate, web -> host ack.
                            Task { @MainActor in
                                guard let vc = flowViewController else {
                                    fail("E2E: FlowViewController was not created")
                                    guard !finished else { return }
                                    finished = true
                                    done()
                                    return
                                }
                                guard let screenId = vc.flow.remoteFlow.screens.first?.id else {
                                    fail("E2E: RemoteFlow has no screens; cannot test runtime/navigate")
                                    guard !finished else { return }
                                    finished = true
                                    done()
                                    return
                                }

                                expectedScreenId.set(screenId)
                                flowViewController?.sendRuntimeMessage(
                                    type: "runtime/navigate",
                                    payload: ["screenId": screenId]
                                )
                            }
                            return
                        }

                        if type == "runtime/screen_changed" {
                            guard didReceiveReady else { return }
                            guard let expected = expectedScreenId.get() else { return }
                            let got = payload["screenId"] as? String
                            guard got == expected else { return }

                            screenChangedId.set(got)
                            guard !finished else { return }
                            finished = true
                            done()
                        }
                    })

                    Task {
                        do {
                            let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
                            let remoteFlow = try await api.fetchFlow(flowId: flowId)
                            let flow = Flow(remoteFlow: remoteFlow, products: [])

                            let archiveService = FlowArchiver()
                            // This conformance check should reflect the current backend response, not a cached
                            // WebArchive from a previous run.
                            await archiveService.removeArchive(for: flow.id)

                            await MainActor.run {
                                let vc = FlowViewController(flow: flow, archiveService: archiveService)
                                vc.runtimeDelegate = runtimeDelegate
                                flowViewController = vc
                                let testWindow = UIWindow(frame: UIScreen.main.bounds)
                                testWindow.rootViewController = vc
                                testWindow.makeKeyAndVisible()
                                window = testWindow
                                _ = vc.view
                            }
                        } catch {
                            fail("E2E setup failed: \(error)")
                            guard !finished else { return }
                            finished = true
                            done()
                        }
                    }
                }

                // If the waitUntil timed out, include last observed messages for debugging.
                let messagesSnapshot = messages.snapshot()
                expect(messagesSnapshot.contains(where: { $0.hasPrefix("runtime/ready") })).to(beTrue())
                guard let expected = expectedScreenId.get() else {
                    fail("E2E: did not resolve expected screen id; messages=\(messagesSnapshot)")
                    return
                }
                expect(screenChangedId.get()).to(equal(expected))
            }

            it("applies view model init/patch and emits action/tap (fixture mode)") {
                guard server != nil else { return }
                guard ProcessInfo.processInfo.environment["NUXIE_E2E_PHASE1"] == "1" else { return }

                let messages = LockedArray<String>()
                let didApplyInit = LockedValue(false)
                let didApplyPatch = LockedValue(false)
                let didReceiveTap = LockedValue(false)

                waitUntil(timeout: .seconds(25)) { done in
                    var finished = false

                    func finishOnce() {
                        guard !finished else { return }
                        finished = true
                        done()
                    }

                    Task {
                        do {
                            // Ensure FlowJourneyRunner can resolve injected dependencies without requiring full SDK setup.
                            Container.shared.reset()
                            let config = NuxieConfiguration(apiKey: apiKey)
                            config.apiEndpoint = baseURL
                            config.enablePlugins = false
                            config.customStoragePath = FileManager.default.temporaryDirectory
                                .appendingPathComponent("nuxie-e2e-\(UUID().uuidString)", isDirectory: true)
                            Container.shared.sdkConfiguration.register { config }
                            Container.shared.eventService.register { MockEventService() }

                            let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
                            let remoteFlow = try await api.fetchFlow(flowId: flowId)
                            let flow = Flow(remoteFlow: remoteFlow, products: [])

                            let archiveService = FlowArchiver()
                            await archiveService.removeArchive(for: flow.id)

                            await MainActor.run {
                                let vc = FlowViewController(flow: flow, archiveService: archiveService)
                                let campaign = makeCampaign(flowId: flowId)
                                let journey = Journey(campaign: campaign, distinctId: "e2e-user")
                                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
                                runner.attach(viewController: vc)

                                let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
                                let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge) { type, payload, id in
                                    let payloadKeys = payload.keys.sorted().joined(separator: ",")
                                    messages.append("\(type) keys=[\(payloadKeys)]")
                                    if type == "action/tap" {
                                        if payload["componentId"] as? String == "tap" || payload["elementId"] as? String == "tap" {
                                            didReceiveTap.set(true)
                                        }
                                    }
                                }
                                runtimeDelegate = delegate
                                vc.runtimeDelegate = delegate
                                flowViewController = vc
                                let testWindow = UIWindow(frame: UIScreen.main.bounds)
                                testWindow.rootViewController = vc
                                testWindow.makeKeyAndVisible()
                                window = testWindow
                                _ = vc.view
                            }

                            guard let vc = flowViewController else {
                                fail("E2E: FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }
                            let webView = await MainActor.run { vc.flowWebView }
                            guard let webView else {
                                fail("E2E: FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }

                            if (try? await waitForVmText(webView, equals: "hello")) == true {
                                didApplyInit.set(true)
                            } else {
                                fail("E2E: view model init did not update DOM")
                                finishOnce()
                                return
                            }

                            _ = try? await evaluateJavaScript(webView, script: "document.getElementById('tap').click()")

                            if (try? await waitForVmText(webView, equals: "world")) == true {
                                didApplyPatch.set(true)
                            } else {
                                fail("E2E: view model patch did not update DOM")
                                finishOnce()
                                return
                            }

                            if didReceiveTap.get(), didApplyInit.get(), didApplyPatch.get() {
                                finishOnce()
                            }
                        } catch {
                            fail("E2E setup failed: \(error)")
                            finishOnce()
                        }
                    }
                }

                let messagesSnapshot = messages.snapshot()
                expect(messagesSnapshot.contains(where: { $0.hasPrefix("runtime/ready") })).to(beTrue())
                expect(messagesSnapshot.contains(where: { $0.hasPrefix("runtime/screen_changed") })).to(beTrue())
                expect(messagesSnapshot.contains(where: { $0.hasPrefix("action/tap") })).to(beTrue())
                expect(didApplyInit.get()).to(beTrue())
                expect(didApplyPatch.get()).to(beTrue())
                expect(didReceiveTap.get()).to(beTrue())
            }

            it("caches and loads a WebArchive on the next load (fixture mode)") {
                guard let requestLog else { return }
                guard server != nil else { return }

                let didLoadFirst = LockedValue(false)
                let didLoadSecond = LockedValue(false)

                waitUntil(timeout: .seconds(25)) { done in
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
                                .appendingPathComponent("nuxie-e2e-\(UUID().uuidString)", isDirectory: true)
                            Container.shared.sdkConfiguration.register { config }
                            Container.shared.eventService.register { MockEventService() }

                            let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
                            let remoteFlow = try await api.fetchFlow(flowId: flowId)
                            let flow = Flow(remoteFlow: remoteFlow, products: [])

                            let archiveService = FlowArchiver()
                            await archiveService.removeArchive(for: flow.id)

                            // First presentation (remote URL; kicks off background WebArchive preload).
                            await MainActor.run {
                                let vc = FlowViewController(flow: flow, archiveService: archiveService)
                                let campaign = makeCampaign(flowId: flowId)
                                let journey = Journey(campaign: campaign, distinctId: "e2e-user")
                                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
                                runner.attach(viewController: vc)

                                let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
                                let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge, onMessage: nil)
                                runtimeDelegate = delegate
                                vc.runtimeDelegate = delegate
                                flowViewController = vc

                                let testWindow = UIWindow(frame: UIScreen.main.bounds)
                                testWindow.rootViewController = vc
                                testWindow.makeKeyAndVisible()
                                window = testWindow
                                _ = vc.view
                            }

                            guard let vc = flowViewController else {
                                fail("E2E: FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }
                            let webView = await MainActor.run { vc.flowWebView }
                            guard let webView else {
                                fail("E2E: FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }

                            if (try? await waitForVmText(webView, equals: "hello", timeoutSeconds: 8.0)) == true {
                                didLoadFirst.set(true)
                            } else {
                                fail("E2E: first load did not reach runtime/view_model_init")
                                finishOnce()
                                return
                            }

                            guard let archiveURL = try await waitForArchiveURL(archiveService, for: flow) else {
                                fail("E2E: expected WebArchive to be cached after first load")
                                finishOnce()
                                return
                            }
                            if !archiveURL.isFileURL {
                                fail("E2E: expected cached WebArchive URL to be a file URL")
                                finishOnce()
                                return
                            }

                            let logAfterFirst = requestLog.snapshot()
                            let firstLogCount = logAfterFirst.count

                            // Second presentation should load from cached WebArchive (no /bundles/* network).
                            await MainActor.run {
                                window?.rootViewController = nil
                                flowViewController = nil
                                runtimeDelegate = nil

                                let vc = FlowViewController(flow: flow, archiveService: archiveService)
                                let campaign = makeCampaign(flowId: flowId)
                                let journey = Journey(campaign: campaign, distinctId: "e2e-user-2")
                                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
                                runner.attach(viewController: vc)

                                let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
                                let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge, onMessage: nil)
                                runtimeDelegate = delegate
                                vc.runtimeDelegate = delegate
                                flowViewController = vc

                                window?.rootViewController = vc
                                window?.makeKeyAndVisible()
                                _ = vc.view
                            }

                            guard let vc2 = flowViewController else {
                                fail("E2E: second FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }
                            let webView2 = await MainActor.run { vc2.flowWebView }
                            guard let webView2 else {
                                fail("E2E: second FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }

                            if (try? await waitForVmText(webView2, equals: "hello", timeoutSeconds: 8.0)) == true {
                                didLoadSecond.set(true)
                            } else {
                                fail("E2E: second load did not reach runtime/view_model_init (cached WebArchive)")
                                finishOnce()
                                return
                            }

                            let logAfterSecond = requestLog.snapshot()
                            if logAfterSecond.count > firstLogCount {
                                let delta = logAfterSecond[firstLogCount..<logAfterSecond.count]
                                let didFetchBundleAgain = delta.contains(where: { $0.contains("/bundles/") })
                                if didFetchBundleAgain {
                                    fail("E2E: expected cached WebArchive load to avoid /bundles/* fetches; delta=\(Array(delta))")
                                    finishOnce()
                                    return
                                }
                            }

                            if didLoadFirst.get(), didLoadSecond.get() {
                                finishOnce()
                            }
                        } catch {
                            fail("E2E setup failed: \(error)")
                            finishOnce()
                        }
                    }
                }

                expect(didLoadFirst.get()).to(beTrue())
                expect(didLoadSecond.get()).to(beTrue())
            }

            func runExperimentBranchTest(variantKey: String, expectedScreenId: String) {
                guard server != nil else { return }
	                guard ProcessInfo.processInfo.environment["NUXIE_E2E_PHASE2"] == "1" else { return }

	                let phase2FlowId = "flow_e2e_experiment_\(UUID().uuidString)"
	                let distinctId = "e2e-user-1-\(variantKey)"

                let messages = LockedArray<String>()
                let didReceiveTap = LockedValue(false)
                let didNavigateToExpected = LockedValue(false)
                let exposureProps = LockedValue<[String: Any]?>(nil)
                let expectedJourneyId = LockedValue<String?>(nil)

                waitUntil(timeout: .seconds(25)) { done in
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
                                .appendingPathComponent("nuxie-e2e-\(UUID().uuidString)", isDirectory: true)
	                            Container.shared.sdkConfiguration.register { config }

	                            let identityService = Container.shared.identityService()
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
	                            guard profile.experiments?["exp-1"]?.variantKey == variantKey else {
	                                fail("E2E: expected server profile assignment variant '\(variantKey)' but got '\(profile.experiments?["exp-1"]?.variantKey ?? "nil")'")
	                                finishOnce()
	                                return
	                            }

                            let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
                            let remoteFlow = try await api.fetchFlow(flowId: phase2FlowId)
                            let flow = Flow(remoteFlow: remoteFlow, products: [])

                            let archiveService = FlowArchiver()
                            await archiveService.removeArchive(for: flow.id)

                            await MainActor.run {
                                let vc = FlowViewController(flow: flow, archiveService: archiveService)
                                let campaign = makeCampaign(flowId: phase2FlowId)
                                let journey = Journey(campaign: campaign, distinctId: distinctId)
                                expectedJourneyId.set(journey.id)

                                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
                                runner.attach(viewController: vc)

                                let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
                                let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge) { type, payload, _ in
                                    let payloadKeys = payload.keys.sorted().joined(separator: ",")
                                    messages.append("\(type) keys=[\(payloadKeys)]")
                                    if type == "action/tap" {
                                        didReceiveTap.set(true)
                                    }
                                }

                                runtimeDelegate = delegate
                                vc.runtimeDelegate = delegate
                                flowViewController = vc
                                let testWindow = UIWindow(frame: UIScreen.main.bounds)
                                testWindow.rootViewController = vc
                                testWindow.makeKeyAndVisible()
                                window = testWindow
                                _ = vc.view
                            }

                            guard let vc = flowViewController else {
                                fail("E2E: FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }
                            let webView = await MainActor.run { vc.flowWebView }
                            guard let webView else {
                                fail("E2E: FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }

                            guard (try? await waitForScreenId(webView, equals: "screen-entry")) == true else {
                                fail("E2E: initial navigate did not update DOM to screen-entry")
                                finishOnce()
                                return
                            }

                            _ = try? await evaluateJavaScript(webView, script: "document.getElementById('tap').click()")

                            if (try? await waitForScreenId(webView, equals: expectedScreenId)) == true {
                                didNavigateToExpected.set(true)
                            } else {
                                fail("E2E: experiment did not navigate to expected screen '\(expectedScreenId)'")
                                finishOnce()
                                return
                            }

                            await eventService.drain()
                            let didFlush = await eventService.flushEvents()
                            if !didFlush {
                                fail("E2E: expected flushEvents() to initiate a flush (didFlush=false)")
                                finishOnce()
                                return
                            }

                            let bodies = batchBodies?.snapshot() ?? []
                            guard let props = firstExposureProperties(fromBatchBodies: bodies) else {
                                fail("E2E: expected a $experiment_exposure event in POST /batch payload; requests=\(bodies.count)")
                                finishOnce()
                                return
                            }
                            exposureProps.set(props)
                            finishOnce()
                        } catch {
                            fail("E2E setup failed: \(error)")
                            finishOnce()
                        }
                    }
                }

                let messagesSnapshot = messages.snapshot()
                expect(messagesSnapshot.contains(where: { $0.hasPrefix("runtime/ready") })).to(beTrue())
                expect(messagesSnapshot.contains(where: { $0.hasPrefix("action/tap") })).to(beTrue())
                expect(didReceiveTap.get()).to(beTrue())
                expect(didNavigateToExpected.get()).to(beTrue())

                let props = exposureProps.get() ?? [:]
                expect(props["experiment_key"] as? String).to(equal("exp-1"))
                expect(props["variant_key"] as? String).to(equal(variantKey))
                expect(props["campaign_id"] as? String).to(equal("camp-e2e-1"))
	                expect(props["flow_id"] as? String).to(equal(phase2FlowId))
	                expect(props["journey_id"] as? String).to(equal(expectedJourneyId.get()))
	                expect(props["is_holdout"] as? Bool).to(equal(false))

	                let requestSnapshot = requestLog?.snapshot() ?? []
	                expect(requestSnapshot.contains("POST /profile") || requestSnapshot.contains("GET /profile")).to(beTrue())
	                expect(requestSnapshot.contains("POST /batch")).to(beTrue())
	            }

            it("branches to screen-a and tracks exposure (fixture mode)") {
                runExperimentBranchTest(variantKey: "a", expectedScreenId: "screen-a")
            }

            it("branches to screen-b and tracks exposure (fixture mode)") {
                runExperimentBranchTest(variantKey: "b", expectedScreenId: "screen-b")
            }
	        }
	    }
	}

// MARK: - Test helpers

private final class CapturingRuntimeDelegate: FlowRuntimeDelegate {
    typealias OnMessage = (_ type: String, _ payload: [String: Any], _ id: String?) -> Void
    private let onMessage: OnMessage

    init(onMessage: @escaping OnMessage) {
        self.onMessage = onMessage
    }

    func flowViewController(_ controller: FlowViewController, didReceiveRuntimeMessage type: String, payload: [String: Any], id: String?) {
        onMessage(type, payload, id)
    }

    func flowViewControllerDidRequestDismiss(_ controller: FlowViewController, reason: CloseReason) {
        // Not used for this smoke test.
    }
}

private final class LockedArray<T> {
    private let lock = NSLock()
    private(set) var values: [T] = []

    func append(_ value: T) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [T] {
        lock.lock()
        let snapshot = values
        lock.unlock()
        return snapshot
    }
}

private final class LockedValue<T> {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func set(_ value: T) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> T {
        lock.lock()
        let current = value
        lock.unlock()
        return current
    }
}

private func decodeMaybeGzippedJSON(_ data: Data) -> Any? {
    let decoded: Data
    if data.isGzipped, let unzipped = try? data.gunzipped() {
        decoded = unzipped
    } else {
        decoded = data
    }
    return try? JSONSerialization.jsonObject(with: decoded, options: [])
}

private func firstExposureProperties(fromBatchBodies bodies: [Data]) -> [String: Any]? {
    for body in bodies {
        guard let root = decodeMaybeGzippedJSON(body) as? [String: Any] else { continue }
        guard let batch = root["batch"] as? [[String: Any]] else { continue }
        for item in batch {
            guard (item["event"] as? String) == JourneyEvents.experimentExposure else { continue }
            return item["properties"] as? [String: Any]
        }
    }
    return nil
}

@MainActor
private func evaluateJavaScript(_ webView: FlowWebView, script: String) async throws -> Any? {
    try await withCheckedThrowingContinuation { continuation in
        webView.evaluateJavaScript(script) { result, error in
            if let error = error {
                continuation.resume(throwing: error)
                return
            }
            continuation.resume(returning: result)
        }
    }
}

@MainActor
private func waitForVmText(_ webView: FlowWebView, equals expected: String, timeoutSeconds: Double = 3.0) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        let value = try await evaluateJavaScript(
            webView,
            script: "document.getElementById('vm-text') && document.getElementById('vm-text').textContent"
        ) as? String
        if value == expected {
            return true
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    return false
}

@MainActor
private func waitForScreenId(_ webView: FlowWebView, equals expected: String, timeoutSeconds: Double = 3.0) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        let value = try await evaluateJavaScript(
            webView,
            script: "document.getElementById('screen-id') && document.getElementById('screen-id').textContent"
        ) as? String
        if value == expected {
            return true
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    return false
}

private func waitForArchiveURL(_ archiveService: FlowArchiver, for flow: Flow, timeoutSeconds: Double = 8.0) async throws -> URL? {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if let url = await archiveService.getArchiveURL(for: flow) {
            return url
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    return nil
}
