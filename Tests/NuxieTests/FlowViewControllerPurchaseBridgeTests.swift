import Quick
import Nimble
import WebKit
import FactoryKit
@testable import Nuxie

final class FlowViewControllerPurchaseBridgeSpec: QuickSpec {
    override class func spec() {
        describe("FlowViewController purchase/restore over bridge") {
            var mockProductService: MockProductService!
            var mockDelegate: MockPurchaseDelegate!

            func makeFlow(products: [FlowProduct] = []) -> Flow {
                let manifest = BuildManifest(totalFiles: 0, totalSize: 0, contentHash: "hash", files: [])
                let remote = RemoteFlow(id: "flow1", name: "Test", url: "about:blank", products: [], manifest: manifest)
                return Flow(remoteFlow: remote, products: products)
            }

            func injectBootstrap(_ webView: FlowWebView) {
                let js = "window.__msgs=[];window.nuxie={_handleHostMessage:function(m){window.__msgs.push(m);}};true;"
                waitUntil(timeout: .seconds(2)) { done in
                    // Allow initial load to complete
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        webView.evaluateJavaScript(js) { _, _ in done() }
                    }
                }
            }

            func getMessages(_ webView: FlowWebView) -> [[String: Any]] {
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
                // Ensure clean SDK + container
                waitUntil(timeout: .seconds(3)) { done in
                    Task { await NuxieSDK.shared.shutdown(); done() }
                }
                Container.shared.reset()
                mockProductService = MockProductService()
                Container.shared.productService.register { mockProductService }
                let config = NuxieConfiguration(apiKey: "test")
                mockDelegate = MockPurchaseDelegate()
                mockDelegate.simulatedDelay = 0
                config.purchaseDelegate = mockDelegate
                config.enablePlugins = false
                try? NuxieSDK.shared.setup(with: config)
            }

            afterEach {
                // Properly cleanup SDK to avoid affecting subsequent tests
                waitUntil(timeout: .seconds(3)) { done in
                    Task { 
                        await NuxieSDK.shared.shutdown()
                        done()
                    }
                }
                // Reset mocks
                mockProductService = nil
                mockDelegate = nil
            }

            it("posts purchase_success on successful purchase") {
                let productId = "pro"
                mockProductService.mockProducts = [MockStoreProduct(id: productId, displayName: "Pro", price: 9.99, displayPrice: "$9.99")]
                mockDelegate.purchaseResult = .success

                let vc = FlowViewController(flow: makeFlow(), archiveService: FlowArchiver())
                _ = vc.view
                injectBootstrap(vc.flowWebView)
                vc.flowWebView.evaluateJavaScript("window.webkit.messageHandlers.bridge.postMessage({ type: 'purchase', payload: { productId: '\(productId)' } })") { _, _ in }
                waitUntil(timeout: .seconds(2)) { done in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done() } }
                let msgs = getMessages(vc.flowWebView)
                let match = msgs.first { ($0["type"] as? String) == "purchase_success" }
                expect(match).toNot(beNil())
                let pl = match?["payload"] as? [String: Any]
                expect(pl?["productId"] as? String).to(equal(productId))
            }

            it("posts purchase_cancelled on cancelled purchase") {
                let productId = "pro"
                mockProductService.mockProducts = [MockStoreProduct(id: productId, displayName: "Pro", price: 9.99, displayPrice: "$9.99")]
                mockDelegate.purchaseResult = .cancelled

                let vc = FlowViewController(flow: makeFlow(), archiveService: FlowArchiver())
                _ = vc.view
                injectBootstrap(vc.flowWebView)
                vc.flowWebView.evaluateJavaScript("window.webkit.messageHandlers.bridge.postMessage({ type: 'purchase', payload: { productId: '\(productId)' } })") { _, _ in }
                waitUntil(timeout: .seconds(2)) { done in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done() } }
                let msgs = getMessages(vc.flowWebView)
                let match = msgs.first { ($0["type"] as? String) == "purchase_cancelled" }
                expect(match).toNot(beNil())
            }

            it("posts purchase_error on failed purchase") {
                let productId = "pro"
                mockProductService.mockProducts = [MockStoreProduct(id: productId, displayName: "Pro", price: 9.99, displayPrice: "$9.99")]
                mockDelegate.purchaseResult = .failed(StoreKitError.purchaseFailed(nil))

                let vc = FlowViewController(flow: makeFlow(), archiveService: FlowArchiver())
                _ = vc.view
                injectBootstrap(vc.flowWebView)
                vc.flowWebView.evaluateJavaScript("window.webkit.messageHandlers.bridge.postMessage({ type: 'purchase', payload: { productId: '\(productId)' } })") { _, _ in }
                waitUntil(timeout: .seconds(2)) { done in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done() } }
                let msgs = getMessages(vc.flowWebView)
                let match = msgs.first { ($0["type"] as? String) == "purchase_error" }
                expect(match).toNot(beNil())
                let pl = match?["payload"] as? [String: Any]
                expect(pl?["error"] as? String).toNot(beNil())
            }

            it("posts restore_success on restore success") {
                mockDelegate.restoreResult = .success(restoredCount: 1)
                let vc = FlowViewController(flow: makeFlow(), archiveService: FlowArchiver())
                _ = vc.view
                injectBootstrap(vc.flowWebView)
                vc.flowWebView.evaluateJavaScript("window.webkit.messageHandlers.bridge.postMessage({ type: 'restore' })") { _, _ in }
                waitUntil(timeout: .seconds(2)) { done in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done() } }
                let msgs = getMessages(vc.flowWebView)
                let match = msgs.first { ($0["type"] as? String) == "restore_success" }
                expect(match).toNot(beNil())
            }

            it("posts restore_error on restore failure") {
                mockDelegate.restoreResult = .failed(StoreKitError.restoreFailed(nil))
                let vc = FlowViewController(flow: makeFlow(), archiveService: FlowArchiver())
                _ = vc.view
                injectBootstrap(vc.flowWebView)
                vc.flowWebView.evaluateJavaScript("window.webkit.messageHandlers.bridge.postMessage({ type: 'restore' })") { _, _ in }
                waitUntil(timeout: .seconds(2)) { done in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done() } }
                let msgs = getMessages(vc.flowWebView)
                let match = msgs.first { ($0["type"] as? String) == "restore_error" }
                expect(match).toNot(beNil())
                let pl = match?["payload"] as? [String: Any]
                expect(pl?["error"] as? String).toNot(beNil())
            }
        }
    }
}
