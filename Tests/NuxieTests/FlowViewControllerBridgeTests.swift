import Quick
import Nimble
import WebKit
@testable import Nuxie

final class FlowViewControllerBridgeSpec: QuickSpec {
    private func makeFlow(products: [FlowProduct] = []) -> Flow {
        let manifest = BuildManifest(totalFiles: 0, totalSize: 0, contentHash: "hash", files: [])
        let description = RemoteFlow(
            id: "flow1",
            version: "v1",
            bundle: FlowBundleRef(url: "about:blank", manifest: manifest),
            entryScreenId: "screen-1",
            entryActions: nil,
            screens: [
                RemoteFlowScreen(
                    id: "screen-1",
                    name: nil,
                    locale: nil,
                    route: nil,
                    defaultViewModelId: nil,
                    defaultInstanceId: nil
                )
            ],
            interactions: RemoteFlowInteractions(screens: [:], components: nil),
            viewModels: [],
            viewModelInstances: nil,
            converters: nil,
            pathIndex: nil
        )
        return Flow(remoteFlow: description, products: products)
    }

    private func loadHTML(_ webView: FlowWebView, html: String) {
        waitUntil(timeout: .seconds(2)) { done in
            webView.loadHTMLString(html, baseURL: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { done() }
        }
        // Wait for window.nuxie to exist
        waitUntil(timeout: .seconds(2)) { done in
            let js = "Boolean(window.nuxie && typeof window.nuxie._handleHostMessage === 'function')"
            func check(_ attempt: Int = 0) {
                webView.evaluateJavaScript(js) { value, _ in
                    if (value as? Bool) == true || attempt >= 20 { done() }
                    else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { check(attempt + 1) } }
                }
            }
            check()
        }
    }

    private func scriptBootstrap() -> String {
        return """
        window.__msgs = [];
        window.nuxie = {
          _handleHostMessage: function(m) {
            window.__msgs.push(m);
          }
        };
        """
    }

    // Inject capture shim into whatever content the VC loaded
    private func injectBootstrap(_ webView: FlowWebView) {
        let js = "window.__msgs=[];window.nuxie={_handleHostMessage:function(m){window.__msgs.push(m);}};true;"
        waitUntil(timeout: .seconds(2)) { done in
            // Delay slightly to allow the initial navigation to complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                webView.evaluateJavaScript(js) { _, _ in done() }
            }
        }
    }

    private func getMessages(_ webView: FlowWebView) -> [[String: Any]] {
        var result: [[String: Any]] = []
        waitUntil(timeout: .seconds(2)) { done in
            webView.evaluateJavaScript("window.__msgs || []") { value, _ in
                result = value as? [[String: Any]] ?? []
                done()
            }
        }
        return result
    }
    override class func spec() {
        describe("FlowViewController bridge") {
            it("dismiss triggers onClose userDismissed") {
                let vc = FlowViewController(flow: FlowViewControllerBridgeSpec().makeFlow(), archiveService: FlowArchiver())
                _ = vc.view
                FlowViewControllerBridgeSpec().injectBootstrap(vc.flowWebView)
                var received: CloseReason?
                waitUntil(timeout: .seconds(2)) { done in
                    vc.onClose = { r in received = r; done() }
                    vc.flowWebView.evaluateJavaScript("window.webkit.messageHandlers.bridge.postMessage({ type: 'dismiss' })") { _, _ in }
                }
                expect(received).to(equal(.userDismissed))
            }

            it("closeFlow triggers onClose userDismissed") {
                let vc = FlowViewController(flow: FlowViewControllerBridgeSpec().makeFlow(), archiveService: FlowArchiver())
                _ = vc.view
                FlowViewControllerBridgeSpec().injectBootstrap(vc.flowWebView)
                var received: CloseReason?
                waitUntil(timeout: .seconds(2)) { done in
                    vc.onClose = { r in received = r; done() }
                    vc.flowWebView.evaluateJavaScript("window.webkit.messageHandlers.bridge.postMessage({ type: 'closeFlow' })") { _, _ in }
                }
                expect(received).to(equal(.userDismissed))
            }

            it("openURL does not crash") {
                let vc = FlowViewController(flow: FlowViewControllerBridgeSpec().makeFlow(), archiveService: FlowArchiver())
                _ = vc.view
                FlowViewControllerBridgeSpec().injectBootstrap(vc.flowWebView)
                waitUntil(timeout: .seconds(2)) { done in
                    vc.flowWebView.evaluateJavaScript("window.webkit.messageHandlers.bridge.postMessage({ type: 'openURL', payload: { url: 'https://example.com' } })") { _, _ in done() }
                }
                expect(true).to(beTrue())
            }
        }
    }
}
