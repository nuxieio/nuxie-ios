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

            beforeEach {
                flowViewController = nil
                runtimeDelegate = nil

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
                    if request.method == "GET", request.path.hasPrefix("/flows/") {
                        let reqFlowId = request.path.replacingOccurrences(of: "/flows/", with: "")
                        let host = request.headers["host"] ?? "127.0.0.1"
                        let htmlUrl = "http://\(host)/flow.html"

                        let manifest = BuildManifest(
                            totalFiles: 1,
                            totalSize: 0,
                            contentHash: "e2e-ready",
                            files: [
                                BuildFile(path: "flow.html", size: 0, contentType: "text/html")
                            ]
                        )

                        let remoteFlow = RemoteFlow(
                            id: reqFlowId,
                            bundle: FlowBundleRef(url: htmlUrl, manifest: manifest),
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

                    if request.method == "GET", request.path == "/flow.html" {
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
                flowId = "flow_e2e_ready"
            }

            afterEach {
                server?.stop()
                server = nil
                flowViewController = nil
                runtimeDelegate = nil
            }

            it("fetches /flows/:id and receives runtime/ready from the loaded WebView") {
                let messages = LockedArray<String>()

                waitUntil(timeout: .seconds(15)) { done in
                    var finished = false
                    runtimeDelegate = CapturingRuntimeDelegate(onMessage: { type, payload, _ in
                        let payloadKeys = payload.keys.sorted().joined(separator: ",")
                        messages.append("\(type) keys=[\(payloadKeys)]")
                        if type == "runtime/ready" {
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
