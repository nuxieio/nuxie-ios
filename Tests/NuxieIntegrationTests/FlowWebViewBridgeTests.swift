import Quick
import Nimble
import WebKit
@testable import Nuxie

final class FlowWebViewBridgeSpec: QuickSpec {
    final class DummyDelegate: FlowMessageHandlerDelegate {
        func messageHandler(_ handler: FlowMessageHandler, didReceiveBridgeMessage type: String, payload: [String : Any], id: String?, from webView: FlowWebView) { }
    }

    override class func spec() {
        describe("FlowWebView bridge") {
            var webView: FlowWebView!

            func scriptBootstrap() -> String {
                return """
                window.__msgs = [];
                window.nuxie = { _handleHostMessage: function(m){ window.__msgs.push(m); } };
                """
            }

            func loadHTML(_ html: String) {
                waitUntil(timeout: .seconds(2)) { done in
                    webView.loadHTMLString(html, baseURL: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { done() }
                }
                // wait for window.nuxie
                waitUntil(timeout: .seconds(2)) { done in
                    let js = "Boolean(window.nuxie && typeof window.nuxie._handleHostMessage === 'function')"
                    func check(_ attempt: Int = 0) {
                        webView.evaluateJavaScript(js) { value, _ in
                            if (value as? Bool) == true || attempt >= 20 {
                                done()
                            } else {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { check(attempt + 1) }
                            }
                        }
                    }
                    check()
                }
            }

            func getMessages() -> [[String: Any]] {
                var result: [[String: Any]] = []
                waitUntil(timeout: .seconds(2)) { done in
                    webView.evaluateJavaScript("window.__msgs || []") { value, _ in
                        result = value as? [[String: Any]] ?? []
                        done()
                    }
                }
                return result
            }

            beforeEach {
                webView = FlowWebView(messageHandlerDelegate: DummyDelegate(), fontStore: FontStore())
                loadHTML("<html><head><script>\(scriptBootstrap())</script></head><body>OK</body></html>")
            }

            it("delivers set_products envelope to JS") {
                let payload: [String: Any] = ["products": [["id": "pro", "name": "Pro", "price": "$9"]]]
                webView.sendBridgeMessage(type: "set_products", payload: payload)
                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done() }
                }
                let msgs = getMessages()
                expect(msgs.count).to(equal(1))
                expect(msgs.first?["type"] as? String).to(equal("set_products"))
                let pl = msgs.first?["payload"] as? [String: Any]
                let products = pl?["products"] as? [[String: Any]]
                expect(products?.count).to(equal(1))
                expect(products?.first?["id"] as? String).to(equal("pro"))
            }

            it("replies to ping with response envelope") {
                let js = "window.webkit.messageHandlers.bridge.postMessage({ type: 'ping', id: 'abc' })"
                waitUntil(timeout: .seconds(2)) { done in
                    webView.evaluateJavaScript(js) { _, _ in done() }
                }
                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done() }
                }
                let msgs = getMessages()
                expect(msgs.count).to(equal(1))
                expect(msgs.first?["type"] as? String).to(equal("response"))
                expect(msgs.first?["replyTo"] as? String).to(equal("abc"))
                let pl = msgs.first?["payload"] as? [String: Any]
                expect(pl?["result"] as? String).to(equal("pong"))
            }
        }
    }
}
