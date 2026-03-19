import Quick
import Nimble
import SafariServices
import UserNotifications
import WebKit
import FactoryKit
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class FlowViewControllerPurchaseBridgeSpec: QuickSpec {
    override class func spec() {
        describe("FlowViewController purchase/restore over bridge") {
            var mockProductService: MockProductService!
            var mockDelegate: MockPurchaseDelegate!
            var mockTransactionObserver: MockTransactionObserver!

            func makeFlow(products: [FlowProduct] = []) -> Flow {
                let manifest = BuildManifest(totalFiles: 0, totalSize: 0, contentHash: "hash", files: [])
                let description = RemoteFlow(
                    id: "flow1",
                    bundle: FlowBundleRef(url: "about:blank", manifest: manifest),
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
                    converters: nil,
                )
                return Flow(remoteFlow: description, products: products)
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
	                let productService = MockProductService()
	                mockProductService = productService
	                Container.shared.productService.register { productService }

	                let transactionObserver = MockTransactionObserver()
	                mockTransactionObserver = transactionObserver
	                Container.shared.transactionObserver.register { transactionObserver }
	                let config = NuxieConfiguration(apiKey: "test")
	                mockDelegate = MockPurchaseDelegate()
	                mockDelegate.simulatedDelay = 0
	                config.purchaseDelegate = mockDelegate
	                config.enablePlugins = false
                try? NuxieSDK.shared.setup(with: config)
            }

            afterEach {
                // Reset mocks
                mockProductService = nil
                mockDelegate = nil
                mockTransactionObserver = nil
            }

            it("posts purchase_ui_success on successful purchase") {
                let productId = "pro"
                mockProductService.mockProducts = [MockStoreProduct(id: productId, displayName: "Pro", price: 9.99, displayPrice: "$9.99")]
                mockDelegate.purchaseResult = .success

                let vc = FlowViewController(flow: makeFlow(), archiveService: FlowArchiver())
                _ = vc.view
                injectBootstrap(vc.flowWebView)
                vc.flowWebView.evaluateJavaScript("window.webkit.messageHandlers.bridge.postMessage({ type: 'action/purchase', payload: { productId: '\(productId)' } })") { _, _ in }
                waitUntil(timeout: .seconds(2)) { done in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done() } }
                let msgs = getMessages(vc.flowWebView)
                let match = msgs.first { ($0["type"] as? String) == "purchase_ui_success" }
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
                vc.flowWebView.evaluateJavaScript("window.webkit.messageHandlers.bridge.postMessage({ type: 'action/purchase', payload: { productId: '\(productId)' } })") { _, _ in }
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
                vc.flowWebView.evaluateJavaScript("window.webkit.messageHandlers.bridge.postMessage({ type: 'action/purchase', payload: { productId: '\(productId)' } })") { _, _ in }
                waitUntil(timeout: .seconds(2)) { done in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done() } }
                let msgs = getMessages(vc.flowWebView)
                let match = msgs.first { ($0["type"] as? String) == "purchase_error" }
                expect(match).toNot(beNil())
                let pl = match?["payload"] as? [String: Any]
                expect(pl?["error"] as? String).toNot(beNil())
            }

            it("posts purchase_confirmed after successful sync") {
                let productId = "pro"
                mockProductService.mockProducts = [MockStoreProduct(id: productId, displayName: "Pro", price: 9.99, displayPrice: "$9.99")]
                mockDelegate.purchaseOutcomeOverride = PurchaseOutcome(
                    result: .success,
                    transactionJws: "test-jws",
                    transactionId: "tx-1",
                    originalTransactionId: "otx-1",
                    productId: productId
                )
                let vc = FlowViewController(flow: makeFlow(), archiveService: FlowArchiver())
                _ = vc.view
                injectBootstrap(vc.flowWebView)
                vc.flowWebView.evaluateJavaScript("window.webkit.messageHandlers.bridge.postMessage({ type: 'action/purchase', payload: { productId: '\(productId)' } })") { _, _ in }
                waitUntil(timeout: .seconds(2)) { done in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done() } }
                let msgs = getMessages(vc.flowWebView)
                let confirmed = msgs.first { ($0["type"] as? String) == "purchase_confirmed" }
                expect(confirmed).toNot(beNil())
                let payload = confirmed?["payload"] as? [String: Any]
                expect(payload?["productId"] as? String).to(equal(productId))
            }

            it("posts restore_success on restore success") {
                mockDelegate.restoreResult = .success(restoredCount: 1)
                let vc = FlowViewController(flow: makeFlow(), archiveService: FlowArchiver())
                _ = vc.view
                injectBootstrap(vc.flowWebView)
                vc.flowWebView.evaluateJavaScript("window.webkit.messageHandlers.bridge.postMessage({ type: 'action/restore' })") { _, _ in }
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
                vc.flowWebView.evaluateJavaScript("window.webkit.messageHandlers.bridge.postMessage({ type: 'action/restore' })") { _, _ in }
                waitUntil(timeout: .seconds(2)) { done in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done() } }
                let msgs = getMessages(vc.flowWebView)
                let match = msgs.first { ($0["type"] as? String) == "restore_error" }
                expect(match).toNot(beNil())
                let pl = match?["payload"] as? [String: Any]
                expect(pl?["error"] as? String).toNot(beNil())
            }

            it("emits notifications_enabled when notifications are already authorized") {
                let authHandler = MockNotificationAuthorizationHandler()
                authHandler.status = .authorized
                let vc = NotificationSpyFlowViewController(flow: makeFlow())
                vc.notificationAuthorizationHandler = authHandler
                _ = vc.view

                vc.performRequestNotifications(journeyId: "journey-1")

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done() }
                }

                expect(vc.emittedEvents.map(\.name)).to(equal([SystemEventNames.notificationsEnabled]))
                expect(vc.emittedEvents.first?.properties["journey_id"] as? String).to(equal("journey-1"))
                expect(authHandler.requestedOptions).to(beNil())
            }

            it("emits notifications_denied when notifications are denied") {
                let authHandler = MockNotificationAuthorizationHandler()
                authHandler.status = .denied
                let vc = NotificationSpyFlowViewController(flow: makeFlow())
                vc.notificationAuthorizationHandler = authHandler
                _ = vc.view

                vc.performRequestNotifications()

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done() }
                }

                expect(vc.emittedEvents.map(\.name)).to(equal([SystemEventNames.notificationsDenied]))
                expect(authHandler.requestedOptions).to(beNil())
            }

            it("requests notification authorization when status is not determined") {
                let authHandler = MockNotificationAuthorizationHandler()
                authHandler.status = .notDetermined
                authHandler.requestResult = .success(true)
                let vc = NotificationSpyFlowViewController(flow: makeFlow())
                vc.notificationAuthorizationHandler = authHandler
                _ = vc.view

                vc.performRequestNotifications()

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done() }
                }

                expect(vc.emittedEvents.map(\.name)).to(equal([SystemEventNames.notificationsEnabled]))
                expect(authHandler.requestedOptions).to(equal([.alert, .badge, .sound]))
            }

            it("requests notification authorization again when status is provisional") {
                let authHandler = MockNotificationAuthorizationHandler()
                authHandler.status = .provisional
                authHandler.requestResult = .success(true)
                let vc = NotificationSpyFlowViewController(flow: makeFlow())
                vc.notificationAuthorizationHandler = authHandler
                _ = vc.view

                vc.performRequestNotifications()

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done() }
                }

                expect(vc.emittedEvents.map(\.name)).to(equal([SystemEventNames.notificationsEnabled]))
                expect(authHandler.requestedOptions).to(equal([.alert, .badge, .sound]))
            }

            it("requests notification authorization again when status is ephemeral") {
                let authHandler = MockNotificationAuthorizationHandler()
                authHandler.status = .ephemeral
                authHandler.requestResult = .success(true)
                let vc = NotificationSpyFlowViewController(flow: makeFlow())
                vc.notificationAuthorizationHandler = authHandler
                _ = vc.view

                vc.performRequestNotifications()

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done() }
                }

                expect(vc.emittedEvents.map(\.name)).to(equal([SystemEventNames.notificationsEnabled]))
                expect(authHandler.requestedOptions).to(equal([.alert, .badge, .sound]))
            }

            it("posts notification outcomes back to standalone flows over the bridge") {
                let authHandler = MockNotificationAuthorizationHandler()
                authHandler.status = .authorized
                let vc = FlowViewController(flow: makeFlow(), archiveService: FlowArchiver())
                vc.notificationAuthorizationHandler = authHandler
                _ = vc.view
                injectBootstrap(vc.flowWebView)

                vc.flowWebView.evaluateJavaScript(
                    "window.webkit.messageHandlers.bridge.postMessage({ type: 'action/request_notifications', payload: {} })"
                ) { _, _ in }

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done() }
                }

                let msgs = getMessages(vc.flowWebView)
                let match = msgs.first { ($0["type"] as? String) == "action/event" }
                expect(match).toNot(beNil())
                let payload = match?["payload"] as? [String: Any]
                expect(payload?["name"] as? String).to(equal(SystemEventNames.notificationsEnabled))
            }

            it("routes journey-scoped notification outcomes through the runtime delegate") {
                let authHandler = MockNotificationAuthorizationHandler()
                authHandler.status = .authorized
                let delegate = NotificationPermissionEventReceiverSpy()
                let vc = FlowViewController(flow: makeFlow(), archiveService: FlowArchiver())
                vc.notificationAuthorizationHandler = authHandler
                vc.runtimeDelegate = delegate
                _ = vc.view

                vc.performRequestNotifications(journeyId: "journey-1")

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done() }
                }

                expect(delegate.events.map(\.name)).to(equal([SystemEventNames.notificationsEnabled]))
                expect(delegate.events.first?.journeyId).to(equal("journey-1"))
                expect(delegate.events.first?.properties["journey_id"] as? String).to(equal("journey-1"))
            }

            it("emits permission_granted when camera permission is already authorized") {
                let authHandler = MockRequestPermissionAuthorizationHandler()
                authHandler.status = .granted
                let vc = NotificationSpyFlowViewController(flow: makeFlow())
                vc.cameraPermissionAuthorizationHandler = authHandler
                vc.cameraUsageDescriptionProvider = { "Camera usage description" }
                _ = vc.view

                vc.performRequestPermission(permissionType: "camera", journeyId: "journey-1")

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done() }
                }

                expect(vc.emittedEvents.map(\.name)).to(equal([SystemEventNames.permissionGranted]))
                expect(vc.emittedEvents.first?.properties["journey_id"] as? String).to(equal("journey-1"))
                expect(vc.emittedEvents.first?.properties["type"] as? String).to(equal("camera"))
                expect(authHandler.requestedAuthorization).to(beFalse())
            }

            it("emits permission_denied when camera usage description is missing") {
                let authHandler = MockRequestPermissionAuthorizationHandler()
                authHandler.status = .notDetermined
                authHandler.requestResult = .granted
                let vc = NotificationSpyFlowViewController(flow: makeFlow())
                vc.cameraPermissionAuthorizationHandler = authHandler
                vc.cameraUsageDescriptionProvider = { nil }
                _ = vc.view

                vc.performRequestPermission(permissionType: "camera")

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done() }
                }

                expect(vc.emittedEvents.map(\.name)).to(equal([SystemEventNames.permissionDenied]))
                expect(vc.emittedEvents.first?.properties["type"] as? String).to(equal("camera"))
                expect(authHandler.requestedAuthorization).to(beFalse())
            }

            it("posts permission outcomes back to standalone flows over the bridge") {
                let authHandler = MockRequestPermissionAuthorizationHandler()
                authHandler.status = .granted
                let vc = FlowViewController(flow: makeFlow(), archiveService: FlowArchiver())
                vc.microphonePermissionAuthorizationHandler = authHandler
                vc.microphoneUsageDescriptionProvider = { "Microphone usage description" }
                _ = vc.view
                injectBootstrap(vc.flowWebView)

                vc.flowWebView.evaluateJavaScript(
                    "window.webkit.messageHandlers.bridge.postMessage({ type: 'action/request_permission', payload: { permissionType: 'microphone' } })"
                ) { _, _ in }

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done() }
                }

                let msgs = getMessages(vc.flowWebView)
                let match = msgs.first { ($0["type"] as? String) == "action/event" }
                expect(match).toNot(beNil())
                let payload = match?["payload"] as? [String: Any]
                expect(payload?["name"] as? String).to(equal(SystemEventNames.permissionGranted))
                let properties = payload?["properties"] as? [String: Any]
                expect(properties?["type"] as? String).to(equal("microphone"))
            }

            it("routes journey-scoped permission outcomes through the runtime delegate") {
                let authHandler = MockRequestPermissionAuthorizationHandler()
                authHandler.status = .granted
                let delegate = RequestPermissionEventReceiverSpy()
                let vc = FlowViewController(flow: makeFlow(), archiveService: FlowArchiver())
                vc.photoLibraryPermissionAuthorizationHandler = authHandler
                vc.photoLibraryUsageDescriptionProvider = { "Photos usage description" }
                vc.runtimeDelegate = delegate
                _ = vc.view

                vc.performRequestPermission(permissionType: "photos", journeyId: "journey-1")

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done() }
                }

                expect(delegate.events.map(\.name)).to(equal([SystemEventNames.permissionGranted]))
                expect(delegate.events.first?.journeyId).to(equal("journey-1"))
                expect(delegate.events.first?.properties["journey_id"] as? String).to(equal("journey-1"))
                expect(delegate.events.first?.properties["type"] as? String).to(equal("photos"))
            }

            it("ignores unsupported request permission kinds for standalone flows") {
                let vc = NotificationSpyFlowViewController(flow: makeFlow())
                _ = vc.view

                vc.performRequestPermission(permissionType: "location_always")

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done() }
                }

                expect(vc.emittedEvents).to(beEmpty())
            }

            it("ignores unsupported request permission statuses for standalone flows") {
                let authHandler = MockRequestPermissionAuthorizationHandler()
                authHandler.status = .unsupported
                let vc = NotificationSpyFlowViewController(flow: makeFlow())
                vc.cameraPermissionAuthorizationHandler = authHandler
                vc.cameraUsageDescriptionProvider = { "Camera usage description" }
                _ = vc.view

                vc.performRequestPermission(permissionType: "camera")

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done() }
                }

                expect(vc.emittedEvents).to(beEmpty())
                expect(authHandler.requestedAuthorization).to(beFalse())
            }

            it("routes unsupported request permission statuses through the scoped unsupported callback") {
                let authHandler = MockRequestPermissionAuthorizationHandler()
                authHandler.status = .unsupported
                let delegate = RequestPermissionEventReceiverSpy()
                let vc = FlowViewController(flow: makeFlow(), archiveService: FlowArchiver())
                vc.cameraPermissionAuthorizationHandler = authHandler
                vc.cameraUsageDescriptionProvider = { "Camera usage description" }
                vc.runtimeDelegate = delegate
                _ = vc.view

                vc.performRequestPermission(permissionType: "camera", journeyId: "journey-1")

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done() }
                }

                expect(delegate.events).to(beEmpty())
                expect(delegate.ignoredUnsupportedPermissionTypes).to(equal(["camera"]))
            }

            it("emits tracking_authorized when tracking is already authorized") {
                let authHandler = MockTrackingAuthorizationHandler()
                authHandler.status = .authorized
                let vc = NotificationSpyFlowViewController(flow: makeFlow())
                vc.trackingAuthorizationHandler = authHandler
                vc.trackingUsageDescriptionProvider = { "Tracking usage description" }
                _ = vc.view

                vc.performRequestTracking(journeyId: "journey-1")

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done() }
                }

                expect(vc.emittedEvents.map(\.name)).to(equal([SystemEventNames.trackingAuthorized]))
                expect(vc.emittedEvents.first?.properties["journey_id"] as? String).to(equal("journey-1"))
                expect(authHandler.requestedAuthorization).to(beFalse())
            }

            it("emits tracking_denied when tracking is denied") {
                let authHandler = MockTrackingAuthorizationHandler()
                authHandler.status = .denied
                let vc = NotificationSpyFlowViewController(flow: makeFlow())
                vc.trackingAuthorizationHandler = authHandler
                vc.trackingUsageDescriptionProvider = { "Tracking usage description" }
                _ = vc.view

                vc.performRequestTracking()

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done() }
                }

                expect(vc.emittedEvents.map(\.name)).to(equal([SystemEventNames.trackingDenied]))
                expect(authHandler.requestedAuthorization).to(beFalse())
            }

            it("emits tracking_denied when tracking is restricted") {
                let authHandler = MockTrackingAuthorizationHandler()
                authHandler.status = .restricted
                let vc = NotificationSpyFlowViewController(flow: makeFlow())
                vc.trackingAuthorizationHandler = authHandler
                vc.trackingUsageDescriptionProvider = { "Tracking usage description" }
                _ = vc.view

                vc.performRequestTracking()

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done() }
                }

                expect(vc.emittedEvents.map(\.name)).to(equal([SystemEventNames.trackingDenied]))
                expect(authHandler.requestedAuthorization).to(beFalse())
            }

            it("does not emit a tracking event when ATT is unsupported") {
                let authHandler = MockTrackingAuthorizationHandler()
                authHandler.status = .unsupported
                let vc = NotificationSpyFlowViewController(flow: makeFlow())
                vc.trackingAuthorizationHandler = authHandler
                vc.trackingUsageDescriptionProvider = { "Tracking usage description" }
                _ = vc.view

                vc.performRequestTracking()

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done() }
                }

                expect(vc.emittedEvents).to(beEmpty())
                expect(authHandler.requestedAuthorization).to(beFalse())
            }

            it("routes unsupported scoped tracking requests through the tracking receiver") {
                let authHandler = MockTrackingAuthorizationHandler()
                authHandler.status = .unsupported
                let vc = FlowViewController(flow: makeFlow(), archiveService: FlowArchiver())
                let delegate = TrackingPermissionEventReceiverSpy()
                vc.trackingAuthorizationHandler = authHandler
                vc.runtimeDelegate = delegate
                _ = vc.view

                vc.performRequestTracking(journeyId: "journey-1")

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done() }
                }

                expect(delegate.events.map(\.name)).to(equal([SystemEventNames.trackingDenied]))
                expect(delegate.events.first?.journeyId).to(equal("journey-1"))
                expect(delegate.events.first?.properties["journey_id"] as? String).to(equal("journey-1"))
                expect(authHandler.requestedAuthorization).to(beFalse())
            }

            it("requests tracking authorization when status is not determined") {
                let authHandler = MockTrackingAuthorizationHandler()
                authHandler.status = .notDetermined
                authHandler.requestResult = .authorized
                let vc = NotificationSpyFlowViewController(flow: makeFlow())
                vc.trackingAuthorizationHandler = authHandler
                vc.trackingUsageDescriptionProvider = { "Tracking usage description" }
                _ = vc.view

                vc.performRequestTracking()

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done() }
                }

                expect(vc.emittedEvents.map(\.name)).to(equal([SystemEventNames.trackingAuthorized]))
                expect(authHandler.requestedAuthorization).to(beTrue())
            }

            it("emits tracking_authorized when already authorized and usage description is missing") {
                let authHandler = MockTrackingAuthorizationHandler()
                authHandler.status = .authorized
                let vc = NotificationSpyFlowViewController(flow: makeFlow())
                vc.trackingAuthorizationHandler = authHandler
                vc.trackingUsageDescriptionProvider = { nil }
                _ = vc.view

                vc.performRequestTracking()

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done() }
                }

                expect(vc.emittedEvents.map(\.name)).to(equal([SystemEventNames.trackingAuthorized]))
                expect(authHandler.requestedAuthorization).to(beFalse())
            }

            it("emits tracking_denied when NSUserTrackingUsageDescription is missing") {
                let authHandler = MockTrackingAuthorizationHandler()
                authHandler.status = .notDetermined
                authHandler.requestResult = .authorized
                let vc = NotificationSpyFlowViewController(flow: makeFlow())
                vc.trackingAuthorizationHandler = authHandler
                vc.trackingUsageDescriptionProvider = { nil }
                _ = vc.view

                vc.performRequestTracking()

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done() }
                }

                expect(vc.emittedEvents.map(\.name)).to(equal([SystemEventNames.trackingDenied]))
                expect(authHandler.requestedAuthorization).to(beFalse())
            }

            it("posts tracking outcomes back to standalone flows over the bridge") {
                let authHandler = MockTrackingAuthorizationHandler()
                authHandler.status = .authorized
                let vc = FlowViewController(flow: makeFlow(), archiveService: FlowArchiver())
                vc.trackingAuthorizationHandler = authHandler
                vc.trackingUsageDescriptionProvider = { "Tracking usage description" }
                _ = vc.view
                injectBootstrap(vc.flowWebView)

                vc.flowWebView.evaluateJavaScript(
                    "window.webkit.messageHandlers.bridge.postMessage({ type: 'action/request_tracking', payload: {} })"
                ) { _, _ in }

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done() }
                }

                let msgs = getMessages(vc.flowWebView)
                let match = msgs.first { ($0["type"] as? String) == "action/event" }
                expect(match).toNot(beNil())
                let payload = match?["payload"] as? [String: Any]
                expect(payload?["name"] as? String).to(equal(SystemEventNames.trackingAuthorized))
            }

            it("routes journey-scoped tracking outcomes through the runtime delegate") {
                let authHandler = MockTrackingAuthorizationHandler()
                authHandler.status = .authorized
                let delegate = TrackingPermissionEventReceiverSpy()
                let vc = FlowViewController(flow: makeFlow(), archiveService: FlowArchiver())
                vc.trackingAuthorizationHandler = authHandler
                vc.trackingUsageDescriptionProvider = { "Tracking usage description" }
                vc.runtimeDelegate = delegate
                _ = vc.view

                vc.performRequestTracking(journeyId: "journey-1")

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done() }
                }

                expect(delegate.events.map(\.name)).to(equal([SystemEventNames.trackingAuthorized]))
                expect(delegate.events.first?.journeyId).to(equal("journey-1"))
                expect(delegate.events.first?.properties["journey_id"] as? String).to(equal("journey-1"))
            }

            it("presents in-app Safari for open_link target") {
                let vc = FlowViewController(flow: makeFlow(), archiveService: FlowArchiver())
                let window = UIWindow(frame: UIScreen.main.bounds)
                window.rootViewController = vc
                window.makeKeyAndVisible()
                _ = vc.view

                waitUntil(timeout: .seconds(2)) { done in
                    DispatchQueue.main.async {
                        vc.performOpenLink(urlString: "https://nuxie.com", target: "in_app")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { done() }
                    }
                }

                expect(vc.presentedViewController).to(beAKindOf(SFSafariViewController.self))
            }
        }
    }
}

private final class MockNotificationAuthorizationHandler: NotificationAuthorizationHandling {
    var status: UNAuthorizationStatus = .notDetermined
    var requestResult: Result<Bool, Error> = .success(true)
    private(set) var requestedOptions: UNAuthorizationOptions?

    func authorizationStatus() async -> UNAuthorizationStatus {
        status
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestedOptions = options
        return try requestResult.get()
    }
}

private final class MockTrackingAuthorizationHandler: TrackingAuthorizationHandling {
    var status: TrackingAuthorizationStatus = .notDetermined
    var requestResult: TrackingAuthorizationStatus = .authorized
    private(set) var requestedAuthorization = false

    func authorizationStatus() -> TrackingAuthorizationStatus {
        status
    }

    func requestAuthorization() async -> TrackingAuthorizationStatus {
        requestedAuthorization = true
        return requestResult
    }
}

private final class MockRequestPermissionAuthorizationHandler: PermissionAuthorizationHandling {
    var status: PermissionAuthorizationStatus = .notDetermined
    var requestResult: PermissionAuthorizationStatus = .granted
    private(set) var requestedAuthorization = false

    func authorizationStatus() -> PermissionAuthorizationStatus {
        status
    }

    func requestAuthorization() async -> PermissionAuthorizationStatus {
        requestedAuthorization = true
        return requestResult
    }
}

private final class NotificationSpyFlowViewController: FlowViewController {
    struct EmittedEvent {
        let name: String
        let properties: [String: Any]
    }

    private(set) var emittedEvents: [EmittedEvent] = []

    init(flow: Flow) {
        super.init(flow: flow, archiveService: FlowArchiver())
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func emitSystemEvent(_ name: String, properties: [String: Any]) {
        emittedEvents.append(EmittedEvent(name: name, properties: properties))
    }
}

private final class NotificationPermissionEventReceiverSpy: FlowRuntimeDelegate, NotificationPermissionEventReceiver {
    struct Event {
        let name: String
        let properties: [String: Any]
        let journeyId: String
    }

    private(set) var events: [Event] = []

    func flowViewController(
        _ controller: FlowViewController,
        didReceiveRuntimeMessage type: String,
        payload: [String : Any],
        id: String?
    ) {}

    func flowViewControllerDidRequestDismiss(_ controller: FlowViewController, reason: CloseReason) {}

    func flowViewController(
        _ controller: FlowViewController,
        didResolveNotificationPermissionEvent eventName: String,
        properties: [String : Any],
        journeyId: String
    ) {
        events.append(Event(name: eventName, properties: properties, journeyId: journeyId))
    }
}

private final class TrackingPermissionEventReceiverSpy: FlowRuntimeDelegate, TrackingPermissionEventReceiver {
    struct Event {
        let name: String
        let properties: [String: Any]
        let journeyId: String
    }

    private(set) var events: [Event] = []

    func flowViewController(
        _ controller: FlowViewController,
        didReceiveRuntimeMessage type: String,
        payload: [String : Any],
        id: String?
    ) {}

    func flowViewControllerDidRequestDismiss(_ controller: FlowViewController, reason: CloseReason) {}

    func flowViewController(
        _ controller: FlowViewController,
        didResolveTrackingPermissionEvent eventName: String,
        properties: [String : Any],
        journeyId: String
    ) {
        events.append(Event(name: eventName, properties: properties, journeyId: journeyId))
    }
}

private final class RequestPermissionEventReceiverSpy: FlowRuntimeDelegate, RequestPermissionEventReceiver {
    struct Event {
        let name: String
        let properties: [String: Any]
        let journeyId: String
    }

    private(set) var events: [Event] = []
    private(set) var ignoredUnsupportedPermissionTypes: [String] = []

    func flowViewController(
        _ controller: FlowViewController,
        didReceiveRuntimeMessage type: String,
        payload: [String : Any],
        id: String?
    ) {}

    func flowViewControllerDidRequestDismiss(_ controller: FlowViewController, reason: CloseReason) {}

    func flowViewController(
        _ controller: FlowViewController,
        didResolveRequestPermissionEvent eventName: String,
        properties: [String : Any],
        journeyId: String
    ) {
        events.append(Event(name: eventName, properties: properties, journeyId: journeyId))
    }

    func flowViewController(
        _ controller: FlowViewController,
        didIgnoreUnsupportedRequestPermissionType permissionType: String,
        journeyId: String
    ) {
        ignoredUnsupportedPermissionTypes.append(permissionType)
    }
}
