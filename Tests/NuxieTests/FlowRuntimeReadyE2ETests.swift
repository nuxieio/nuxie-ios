import Foundation
import Quick
import Nimble
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
                            <script>
                              (function(){
                                // Minimal "real runtime" surface for Phase 0:
                                // - Provide window.nuxie._handleHostMessage (host -> web)
                                // - Emit runtime/ready and runtime/screen_changed (web -> host)
                                window.nuxie = {
                                  _handleHostMessage: function(envelope) {
                                    try {
                                      if (!envelope || !envelope.type) return;
                                      if (envelope.type === "runtime/navigate") {
                                        var screenId = (envelope.payload && envelope.payload.screenId) || null;
                                        window.webkit.messageHandlers.bridge.postMessage({
                                          type: "runtime/screen_changed",
                                          payload: { screenId: screenId }
                                        });
                                      }
                                    } catch (e) {}
                                  }
                                };

                                function sendReady() {
                                  try {
                                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) {
                                      window.webkit.messageHandlers.bridge.postMessage({ type: "runtime/ready", payload: { version: "e2e" } });
                                      document.getElementById("status").textContent = "ready-sent";
                                    }
                                  } catch (e) {}
                                }
                                setTimeout(sendReady, 50);
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
                var screenChangedId: String?

                waitUntil(timeout: .seconds(25)) { done in
                    var finished = false
                    runtimeDelegate = CapturingRuntimeDelegate(onMessage: { type, payload, _ in
                        let payloadKeys = payload.keys.sorted().joined(separator: ",")
                        messages.append("\(type) keys=[\(payloadKeys)]")

                        if type == "runtime/ready" {
                            // Drive the smallest "real runtime" contract: host -> web navigate, web -> host ack.
                            Task { @MainActor in
                                flowViewController?.sendRuntimeMessage(
                                    type: "runtime/navigate",
                                    payload: ["screenId": "screen-1"]
                                )
                            }
                            return
                        }

                        if type == "runtime/screen_changed" {
                            screenChangedId = payload["screenId"] as? String
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

                            await MainActor.run {
                                let vc = FlowViewController(flow: flow, archiveService: FlowArchiver())
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
                expect(messages.values.contains(where: { $0.hasPrefix("runtime/ready") })).to(beTrue())
                expect(screenChangedId).to(equal("screen-1"))
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
}
