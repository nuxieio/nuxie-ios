import Foundation
import Quick
import Nimble
import WebKit
@testable import Nuxie

final class FlowRuntimeReadyE2ESpec: QuickSpec {
    override class func spec() {
        describe("E2E flow runtime ready") {
            var server: LocalHTTPServer?

            var apiKey: String = "pk_test_e2e_local"
            var baseURL: URL = URL(string: "http://127.0.0.1:8084")!
            var flowId: String = "flow_e2e_ready"

            var flowViewController: FlowViewController?
            var runtimeDelegate: CapturingRuntimeDelegate?
            var requestLog: LockedArray<String>?

            beforeEach {
                flowViewController = nil
                runtimeDelegate = nil
                requestLog = LockedArray<String>()

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
                    if request.method == "GET", request.path.hasPrefix("/flows/") {
                        let reqFlowId = request.path.replacingOccurrences(of: "/flows/", with: "")
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

                        let remoteFlow = RemoteFlow(
                            id: reqFlowId,
                            bundle: FlowBundleRef(url: bundleBaseUrl, manifest: manifest),
                            screens: [
                                RemoteFlowScreen(
                                    id: "screen-1",
                                    defaultViewModelId: nil,
                                    defaultInstanceId: nil
                                )
                            ],
                            interactions: [:],
                            viewModels: [],
                            viewModelInstances: nil,
                            converters: nil
                        )

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
                            <div id="vm-text">(unset)</div>
                            <button id="tap" type="button">Tap</button>
                            <script>
                              (function(){
                                // Minimal runtime surface for Phase 0 + 1:
                                // - Provide window.nuxie._handleHostMessage (host -> web)
                                // - Emit runtime/ready and runtime/screen_changed (web -> host)
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
                                    post("action/tap", { elementId: "tap" });
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
                requestLog = nil
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
                            if server != nil {
                                // Prefer loading from a freshly-built WebArchive to reduce WKWebView/network flake.
                                await archiveService.preloadArchive(for: flow)
                            }

                            await MainActor.run {
                                let vc = FlowViewController(flow: flow, archiveService: archiveService)
                                vc.runtimeDelegate = runtimeDelegate
                                flowViewController = vc
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
                let expectedScreenId = LockedValue<String?>(nil)
                let didApplyInit = LockedValue(false)
                let didApplyPatch = LockedValue(false)
                let didReceiveTap = LockedValue(false)

                waitUntil(timeout: .seconds(25)) { done in
                    var finished = false
                    var didReceiveReady = false

                    func finishOnce() {
                        guard !finished else { return }
                        finished = true
                        done()
                    }

                    runtimeDelegate = CapturingRuntimeDelegate(onMessage: { type, payload, _ in
                        let payloadKeys = payload.keys.sorted().joined(separator: ",")
                        messages.append("\(type) keys=[\(payloadKeys)]")

                        if type == "runtime/ready" {
                            didReceiveReady = true
                            Task { @MainActor in
                                guard let vc = flowViewController else {
                                    fail("E2E: FlowViewController was not created")
                                    finishOnce()
                                    return
                                }
                                guard let screenId = vc.flow.remoteFlow.screens.first?.id else {
                                    fail("E2E: RemoteFlow has no screens; cannot test runtime/navigate")
                                    finishOnce()
                                    return
                                }

                                expectedScreenId.set(screenId)
                                vc.sendRuntimeMessage(type: "runtime/navigate", payload: ["screenId": screenId])
                            }
                            return
                        }

                        if type == "runtime/screen_changed" {
                            guard didReceiveReady else { return }
                            guard let expected = expectedScreenId.get() else { return }
                            let got = payload["screenId"] as? String
                            guard got == expected else { return }

                            Task { @MainActor in
                                guard let vc = flowViewController else {
                                    fail("E2E: FlowViewController was not created")
                                    finishOnce()
                                    return
                                }

                                vc.sendRuntimeMessage(
                                    type: "runtime/view_model_init",
                                    payload: [
                                        "instances": [
                                            [
                                                "viewModelId": "vm-1",
                                                "instanceId": "inst-1",
                                                "values": [
                                                    "title": "hello"
                                                ]
                                            ]
                                        ]
                                    ]
                                )
                                if let webView = vc.flowWebView,
                                   (try? await waitForVmText(webView, equals: "hello")) == true {
                                    didApplyInit.set(true)
                                } else {
                                    fail("E2E: view model init did not update DOM")
                                    finishOnce()
                                    return
                                }

                                vc.sendRuntimeMessage(
                                    type: "runtime/view_model_patch",
                                    payload: [
                                        "pathIds": [0],
                                        "value": "world"
                                    ]
                                )
                                if let webView = vc.flowWebView,
                                   (try? await waitForVmText(webView, equals: "world")) == true {
                                    didApplyPatch.set(true)
                                } else {
                                    fail("E2E: view model patch did not update DOM")
                                    finishOnce()
                                    return
                                }

                                if let webView = vc.flowWebView {
                                    _ = try? await evaluateJavaScript(webView, script: "document.getElementById('tap').click()")
                                }

                                if didReceiveTap.get(), didApplyInit.get(), didApplyPatch.get() {
                                    finishOnce()
                                }
                            }
                            return
                        }

                        if type == "action/tap" {
                            guard payload["elementId"] as? String == "tap" else { return }
                            didReceiveTap.set(true)
                            if didApplyInit.get(), didApplyPatch.get() {
                                finishOnce()
                            }
                        }
                    })

                    Task {
                        do {
                            let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
                            let remoteFlow = try await api.fetchFlow(flowId: flowId)
                            let flow = Flow(remoteFlow: remoteFlow, products: [])

                            let archiveService = FlowArchiver()
                            await archiveService.removeArchive(for: flow.id)
                            if server != nil {
                                await archiveService.preloadArchive(for: flow)
                            }

                            await MainActor.run {
                                let vc = FlowViewController(flow: flow, archiveService: archiveService)
                                vc.runtimeDelegate = runtimeDelegate
                                flowViewController = vc
                                _ = vc.view
                            }
                        } catch {
                            fail("E2E setup failed: \(error)")
                            finishOnce()
                        }
                    }
                }

                let messagesSnapshot = messages.snapshot()
                expect(messagesSnapshot.contains(where: { $0.hasPrefix("runtime/ready") })).to(beTrue())
                expect(didApplyInit.get()).to(beTrue())
                expect(didApplyPatch.get()).to(beTrue())
                expect(didReceiveTap.get()).to(beTrue())
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
