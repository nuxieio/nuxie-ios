import Foundation
import FactoryKit
import WebKit
import UserNotifications
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(SafariServices)
import SafariServices
#endif

protocol NotificationAuthorizationHandling {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
}

enum TrackingAuthorizationStatus {
    case authorized
    case denied
    case restricted
    case notDetermined
    case unsupported
}

protocol TrackingAuthorizationHandling {
    func authorizationStatus() -> TrackingAuthorizationStatus
    func requestAuthorization() async -> TrackingAuthorizationStatus
}

struct UserNotificationAuthorizationHandler: NotificationAuthorizationHandling {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: options)
    }
}

struct AppTrackingAuthorizationHandler: TrackingAuthorizationHandling {
    func authorizationStatus() -> TrackingAuthorizationStatus {
        #if canImport(AppTrackingTransparency)
        if #available(iOS 14, *) {
            return TrackingAuthorizationStatus(ATTrackingManager.trackingAuthorizationStatus)
        }
        #endif
        return .unsupported
    }

    func requestAuthorization() async -> TrackingAuthorizationStatus {
        #if canImport(AppTrackingTransparency)
        if #available(iOS 14, *) {
            return await withCheckedContinuation { continuation in
                ATTrackingManager.requestTrackingAuthorization { status in
                    continuation.resume(returning: TrackingAuthorizationStatus(status))
                }
            }
        }
        #endif
        return .unsupported
    }
}

#if canImport(AppTrackingTransparency)
@available(iOS 14, *)
private extension TrackingAuthorizationStatus {
    init(_ status: ATTrackingManager.AuthorizationStatus) {
        switch status {
        case .authorized:
            self = .authorized
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        case .notDetermined:
            self = .notDetermined
        @unknown default:
            self = .restricted
        }
    }
}
#endif

/// Delegate for Flow runtime bridge messages
protocol FlowRuntimeDelegate: AnyObject {
    func flowViewController(
        _ controller: FlowViewController,
        didReceiveRuntimeMessage type: String,
        payload: [String: Any],
        id: String?
    )
    /// Called when the host emits a runtime message toward the web runtime.
    /// This is fired when the message is requested, even if delivery is queued
    /// until runtime readiness.
    func flowViewController(
        _ controller: FlowViewController,
        didSendRuntimeMessage type: String,
        payload: [String: Any],
        replyTo: String?
    )
    func flowViewControllerDidRequestDismiss(_ controller: FlowViewController, reason: CloseReason)
}

protocol NotificationPermissionEventReceiver: AnyObject {
    func flowViewController(
        _ controller: FlowViewController,
        didResolveNotificationPermissionEvent eventName: String,
        properties: [String: Any],
        journeyId: String
    )
}

protocol TrackingPermissionEventReceiver: AnyObject {
    func flowViewController(
        _ controller: FlowViewController,
        didResolveTrackingPermissionEvent eventName: String,
        properties: [String: Any],
        journeyId: String
    )

    func flowViewController(
        _ controller: FlowViewController,
        didCompleteUnsupportedTrackingRequestFor journeyId: String
    )
}

extension TrackingPermissionEventReceiver {
    func flowViewController(
        _ controller: FlowViewController,
        didCompleteUnsupportedTrackingRequestFor journeyId: String
    ) {}
}

extension FlowRuntimeDelegate {
    func flowViewController(
        _ controller: FlowViewController,
        didSendRuntimeMessage type: String,
        payload: [String: Any],
        replyTo: String?
    ) {}
}

/// FlowViewController - displays flow content in a WebView with loading and error states
public class FlowViewController: NuxiePlatformViewController, FlowMessageHandlerDelegate {

    // MARK: - Properties

    private let viewModel: FlowViewModel
    private let fontStore: FontStore
    var notificationAuthorizationHandler: NotificationAuthorizationHandling = UserNotificationAuthorizationHandler()
    var trackingAuthorizationHandler: TrackingAuthorizationHandling = AppTrackingAuthorizationHandler()
    var trackingUsageDescriptionProvider: () -> String? = {
        Bundle.main.object(forInfoDictionaryKey: "NSUserTrackingUsageDescription") as? String
    }

    /// Delegate for runtime bridge messages
    weak var runtimeDelegate: FlowRuntimeDelegate? {
        didSet {
            if let receiver = runtimeDelegate as? NotificationPermissionEventReceiver {
                notificationPermissionEventReceiver = receiver
            }
            if let receiver = runtimeDelegate as? TrackingPermissionEventReceiver {
                trackingPermissionEventReceiver = receiver
            }
        }
    }

    /// Dedicated receiver for native notification permission results.
    ///
    /// This is retained separately from `runtimeDelegate` because permission
    /// responses can arrive after the journey delegate has been removed from the
    /// active journey maps during identity changes or cancellation.
    var notificationPermissionEventReceiver: NotificationPermissionEventReceiver?
    var trackingPermissionEventReceiver: TrackingPermissionEventReceiver?

    /// Closure called when the flow is closed
    public var onClose: ((CloseReason) -> Void)?

    public var colorSchemeMode: FlowColorSchemeMode = .light {
        didSet {
            guard oldValue != colorSchemeMode else { return }
            guard isViewLoaded else { return }
            applyColorSchemeMode()
            sendCurrentColorSchemeToRuntimeIfNeeded(force: true)
        }
    }

    // UI Components
    internal var flowWebView: FlowWebView!
    #if canImport(UIKit)
    var loadingView: UIView!
    var errorView: UIView!
    var activityIndicator: UIActivityIndicatorView!
    var refreshButton: UIButton!
    var closeButton: UIButton!
    #elseif canImport(AppKit)
    var loadingView: NSView!
    var errorView: NSView!
    var activityIndicator: NSProgressIndicator!
    var refreshButton: NSButton!
    var closeButton: NSButton!
    #endif

    // Runtime readiness + message buffering
    private var runtimeReady = false
    private var pendingRuntimeMessages: [(type: String, payload: [String: Any], replyTo: String?)] = []
    private var didInvokeClose = false
    private var lastSentColorSchemePayload: [String: String]?

    // MARK: - Computed Properties

    var flow: Flow {
        return viewModel.flow
    }

    var products: [FlowProduct] {
        return viewModel.products
    }

    // MARK: - Initialization

    init(
        flow: Flow,
        archiveService: FlowArchiver,
        fontStore: FontStore = FontStore(),
        artifactTelemetryContext: FlowArtifactTelemetryContext? = nil
    ) {
        self.viewModel = FlowViewModel(
            flow: flow,
            archiveService: archiveService,
            fontStore: fontStore,
            artifactTelemetryContext: artifactTelemetryContext
        )
        self.fontStore = fontStore
        super.init(nibName: nil, bundle: nil)

        setupBindings()
        LogDebug("FlowViewController initialized for flow: \(flow.id)")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        applyColorSchemeMode()
        viewModel.loadFlow()
    }

    #if canImport(UIKit)
    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }

    public override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        sendRuntimeSafeAreaInsets()
    }
    #endif

    // MARK: - Public Methods

    func preloadView() {
        // Force view to load
        _ = self.view
        LogDebug("Preloaded view for flow: \(flow.id)")
    }

    func updateProducts(_ newProducts: [FlowProduct]) {
        viewModel.updateProducts(newProducts)
    }

    func updateFlowIfNeeded(_ newFlow: Flow) {
        viewModel.updateFlowIfNeeded(newFlow)
    }

    func updateArtifactTelemetryContext(_ context: FlowArtifactTelemetryContext) {
        viewModel.updateArtifactTelemetryContext(context)
    }

    func performPurchase(productId: String, placementIndex: Any? = nil) {
        handleBridgePurchase(productId: productId, requestId: nil)
    }

    func performRestore() {
        handleBridgeRestore(requestId: nil)
    }

    func performRequestNotifications(journeyId: String? = nil) {
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.resolveNotificationAuthorizationOutcome()
            let properties = self.journeyScopedEventProperties(journeyId: journeyId)
            let eventName: String
            switch outcome {
            case .enabled:
                eventName = SystemEventNames.notificationsEnabled
            case .denied:
                eventName = SystemEventNames.notificationsDenied
            }
            self.dispatchNotificationPermissionEvent(
                eventName,
                properties: properties,
                journeyId: journeyId
            )
        }
    }

    func performRequestTracking(journeyId: String? = nil) {
        let currentStatus = trackingAuthorizationHandler.authorizationStatus()
        if currentStatus == .unsupported {
            LogWarning("FlowViewController: tracking authorization is unsupported on this platform; skipping event")
            if let journeyId, !journeyId.isEmpty,
               let receiver = trackingPermissionEventReceiver {
                receiver.flowViewController(
                    self,
                    didCompleteUnsupportedTrackingRequestFor: journeyId
                )
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.resolveTrackingAuthorizationOutcome(
                currentStatus: currentStatus
            )
            let properties = self.journeyScopedEventProperties(journeyId: journeyId)
            let eventName: String
            switch outcome {
            case .authorized:
                eventName = SystemEventNames.trackingAuthorized
            case .denied:
                eventName = SystemEventNames.trackingDenied
            case .unsupported:
                return
            }
            self.dispatchTrackingPermissionEvent(
                eventName,
                properties: properties,
                journeyId: journeyId
            )
        }
    }

    func emitSystemEvent(_ name: String, properties: [String: Any]) {
        NuxieSDK.shared.trigger(name, properties: properties.isEmpty ? nil : properties)
    }

    func performDismiss(reason: CloseReason = .userDismissed) {
        runtimeDelegate?.flowViewControllerDidRequestDismiss(self, reason: reason)

        #if canImport(UIKit)
        dismiss(animated: true) { [weak self] in
            self?.invokeOnCloseOnce(reason)
        }
        #elseif canImport(AppKit)
        view.window?.orderOut(nil)
        invokeOnCloseOnce(reason)
        #endif

        // Fallback: ensure onClose is invoked even if platform dismissal completion never fires.
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.invokeOnCloseOnce(reason)
        }
    }

    func performOpenLink(urlString: String, target: String? = nil) {
        guard let url = URL(string: urlString) else { return }
        let normalizedTarget = target?.lowercased()

        if normalizedTarget == "in_app" {
            let scheme = url.scheme?.lowercased()
            guard scheme == "http" || scheme == "https" else { return }
            #if canImport(UIKit)
            let safariViewController = SFSafariViewController(url: url)
            present(safariViewController, animated: true)
            #elseif canImport(AppKit)
            NSWorkspace.shared.open(url)
            #endif
            return
        }

        #if canImport(UIKit)
        guard UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    /// Send a runtime message to the Flow bundle
    func sendRuntimeMessage(
        type: String,
        payload: [String: Any] = [:],
        replyTo: String? = nil,
        completion: ((Any?, Error?) -> Void)? = nil
    ) {
        runtimeDelegate?.flowViewController(
            self,
            didSendRuntimeMessage: type,
            payload: payload,
            replyTo: replyTo
        )
        if !runtimeReady {
            pendingRuntimeMessages.append((type: type, payload: payload, replyTo: replyTo))
            return
        }
        flowWebView.sendBridgeMessage(type: type, payload: payload, replyTo: replyTo, completion: completion)
    }

    // MARK: - Setup

    private func setupBindings() {
        // Bind to view model state changes
        viewModel.onStateChanged = { [weak self] state in
            self?.updateUIState(state)
        }

        // Bind to load URL requests
        viewModel.onLoadURL = { [weak self] url in
            self?.flowWebView.loadFileURL(url)
        }

        // Bind to load request
        viewModel.onLoadRequest = { [weak self] request in
            self?.flowWebView.load(request)
        }
    }

    private func setupViews() {
        platformApplyDefaultBackgroundColor()

        setupWebView()
        platformSetupLoadingView()
        platformSetupErrorView()

        // Start in loading state
        updateUIState(.loading)
    }

    private func setupWebView() {
        flowWebView = FlowWebView(messageHandlerDelegate: self, fontStore: fontStore)
        flowWebView.isHidden = true
        view.addSubview(flowWebView)

        // Set up callbacks
        flowWebView.onLoadingStarted = { [weak self] in
            self?.viewModel.handleLoadingStarted()
        }

        flowWebView.onLoadingFinished = { [weak self] in
            self?.viewModel.handleLoadingFinished()
        }

        flowWebView.onLoadingFailed = { [weak self] error in
            self?.viewModel.handleLoadingFailed(error)
        }

        NSLayoutConstraint.activate([
            flowWebView.topAnchor.constraint(equalTo: view.topAnchor),
            flowWebView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            flowWebView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            flowWebView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        LogDebug("FlowWebView added for flow: \(flow.id)")
    }

    // MARK: - UI State Management

    private func updateUIState(_ state: FlowViewModel.State) {
        switch state {
        case .loading:
            flowWebView.isHidden = true
            loadingView.isHidden = false
            errorView.isHidden = true
            platformStartLoadingIndicator()

        case .loaded:
            flowWebView.isHidden = false
            loadingView.isHidden = true
            errorView.isHidden = true
            platformStopLoadingIndicator()

        case .error:
            flowWebView.isHidden = true
            loadingView.isHidden = true
            errorView.isHidden = false
            platformStopLoadingIndicator()
        }
    }

    func retryFromErrorView() {
        viewModel.retry()
    }
}

// MARK: - FlowMessageHandlerDelegate

extension FlowViewController {
    // Handle @nuxie/bridge messages directly
    func messageHandler(
        _ handler: FlowMessageHandler,
        didReceiveBridgeMessage type: String,
        payload: [String: Any],
        id: String?,
        from webView: FlowWebView
    ) {
        switch type {
        case "runtime/ready":
            runtimeReady = true
            runtimeDelegate?.flowViewController(self, didReceiveRuntimeMessage: type, payload: payload, id: id)
            flushPendingRuntimeMessages()
            sendRuntimeSafeAreaInsets()
            sendCurrentColorSchemeToRuntimeIfNeeded(force: true)
        case "runtime/screen_changed", "action/did_set", "action/event":
            runtimeDelegate?.flowViewController(self, didReceiveRuntimeMessage: type, payload: payload, id: id)
        case "action/purchase":
            if runtimeDelegate != nil {
                runtimeDelegate?.flowViewController(self, didReceiveRuntimeMessage: type, payload: payload, id: id)
            } else if let productId = payload["productId"] as? String {
                handleBridgePurchase(productId: productId, requestId: id)
            }
        case "action/restore":
            if runtimeDelegate != nil {
                runtimeDelegate?.flowViewController(self, didReceiveRuntimeMessage: type, payload: payload, id: id)
            } else {
                handleBridgeRestore(requestId: id)
            }
        case "action/request_notifications":
            if runtimeDelegate != nil {
                runtimeDelegate?.flowViewController(self, didReceiveRuntimeMessage: type, payload: payload, id: id)
            } else {
                performRequestNotifications()
            }
        case "action/request_tracking":
            if runtimeDelegate != nil {
                runtimeDelegate?.flowViewController(self, didReceiveRuntimeMessage: type, payload: payload, id: id)
            } else {
                performRequestTracking()
            }
        case "action/open_link":
            if runtimeDelegate != nil {
                runtimeDelegate?.flowViewController(self, didReceiveRuntimeMessage: type, payload: payload, id: id)
            } else if let urlString = payload["url"] as? String {
                performOpenLink(urlString: urlString, target: payload["target"] as? String)
            }
        case "action/back":
            if runtimeDelegate != nil {
                runtimeDelegate?.flowViewController(self, didReceiveRuntimeMessage: type, payload: payload, id: id)
            } else {
                LogDebug("FlowViewController: Unhandled runtime back action")
            }
        case "action/dismiss":
            performDismiss(reason: .userDismissed)
        case "dismiss", "closeFlow":
            performDismiss(reason: .userDismissed)
        case "openURL":
            if let urlString = payload["url"] as? String {
                performOpenLink(urlString: urlString)
            }
        default:
            if type.hasPrefix("action/") {
                runtimeDelegate?.flowViewController(self, didReceiveRuntimeMessage: type, payload: payload, id: id)
            } else {
                LogDebug("FlowViewController: Unhandled bridge message: \(type)")
            }
        }
    }
}

private extension FlowViewController {
    enum NotificationAuthorizationOutcome {
        case enabled
        case denied
    }

    enum TrackingAuthorizationOutcome {
        case authorized
        case denied
        case unsupported
    }

    func invokeOnCloseOnce(_ reason: CloseReason) {
        guard !didInvokeClose else { return }
        didInvokeClose = true
        onClose?(reason)
    }

    func resolveNotificationAuthorizationOutcome() async -> NotificationAuthorizationOutcome {
        let status = await notificationAuthorizationHandler.authorizationStatus()
        if isNotificationAuthorizationGranted(status) {
            return .enabled
        }
        if status == .denied {
            return .denied
        }

        do {
            let granted = try await notificationAuthorizationHandler.requestAuthorization(
                options: [.alert, .badge, .sound]
            )
            return granted ? .enabled : .denied
        } catch {
            LogWarning("FlowViewController: notification request failed: \(error)")
            return .denied
        }
    }

    func resolveTrackingAuthorizationOutcome(
        currentStatus: TrackingAuthorizationStatus? = nil
    ) async -> TrackingAuthorizationOutcome {
        switch currentStatus ?? trackingAuthorizationHandler.authorizationStatus() {
        case .authorized:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .unsupported:
            return .unsupported
        case .notDetermined:
            guard let usageDescription = trackingUsageDescriptionProvider()?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !usageDescription.isEmpty
            else {
                LogWarning("FlowViewController: NSUserTrackingUsageDescription is missing; emitting tracking_denied")
                return .denied
            }

            switch await trackingAuthorizationHandler.requestAuthorization() {
            case .authorized:
                return .authorized
            case .denied, .restricted, .notDetermined:
                return .denied
            case .unsupported:
                return .unsupported
            }
        }
    }

    func isNotificationAuthorizationGranted(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized:
            return true
        case .ephemeral, .provisional, .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    func journeyScopedEventProperties(journeyId: String?) -> [String: Any] {
        guard let journeyId, !journeyId.isEmpty else {
            return [:]
        }
        return ["journey_id": journeyId]
    }

    func dispatchNotificationPermissionEvent(
        _ eventName: String,
        properties: [String: Any],
        journeyId: String?
    ) {
        if let journeyId, !journeyId.isEmpty,
           let receiver = notificationPermissionEventReceiver {
            receiver.flowViewController(
                self,
                didResolveNotificationPermissionEvent: eventName,
                properties: properties,
                journeyId: journeyId
            )
            return
        }

        if journeyId == nil {
            sendSystemEventToRuntime(
                eventName,
                properties: properties
            )
        }

        emitSystemEvent(eventName, properties: properties)
    }

    func dispatchTrackingPermissionEvent(
        _ eventName: String,
        properties: [String: Any],
        journeyId: String?
    ) {
        if let journeyId, !journeyId.isEmpty,
           let receiver = trackingPermissionEventReceiver {
            receiver.flowViewController(
                self,
                didResolveTrackingPermissionEvent: eventName,
                properties: properties,
                journeyId: journeyId
            )
            return
        }

        if journeyId == nil {
            sendSystemEventToRuntime(
                eventName,
                properties: properties
            )
        }

        emitSystemEvent(eventName, properties: properties)
    }

    func sendSystemEventToRuntime(
        _ eventName: String,
        properties: [String: Any]
    ) {
        guard flowWebView != nil else { return }

        var payload: [String: Any] = ["name": eventName]
        if !properties.isEmpty {
            payload["properties"] = properties
        }

        flowWebView.sendBridgeMessage(type: "action/event", payload: payload)
    }

    func applyColorSchemeMode() {
        platformApplyColorSchemeMode(colorSchemeMode)
        lastSentColorSchemePayload = nil
    }

    func currentColorSchemePayload() -> [String: String] {
        [
            "mode": colorSchemeMode.rawValue,
        ]
    }

    func sendCurrentColorSchemeToRuntimeIfNeeded(force: Bool) {
        guard runtimeReady else { return }
        let payload = currentColorSchemePayload()
        if !force && payload == lastSentColorSchemePayload {
            return
        }
        lastSentColorSchemePayload = payload
        sendRuntimeMessage(type: "runtime/color_scheme", payload: payload)
    }

    func flushPendingRuntimeMessages() {
        guard runtimeReady, !pendingRuntimeMessages.isEmpty else { return }
        let queued = pendingRuntimeMessages
        pendingRuntimeMessages.removeAll()
        for message in queued {
            flowWebView.sendBridgeMessage(
                type: message.type,
                payload: message.payload,
                replyTo: message.replyTo,
                completion: nil
            )
        }
    }

    func sendRuntimeSafeAreaInsets() {
        #if canImport(UIKit)
        let insets = view.safeAreaInsets
        sendRuntimeMessage(
            type: "system/safe_area_insets",
            payload: [
                "top": Double(insets.top),
                "bottom": Double(insets.bottom),
                "left": Double(insets.left),
                "right": Double(insets.right)
            ]
        )
        #endif
    }
}

// MARK: - Bridge Action Helpers

extension FlowViewController {
    fileprivate func handleBridgePurchase(productId: String, requestId: String?) {
        LogDebug("FlowViewController: Bridge purchase for product: \(productId)")
        let transactionService = Container.shared.transactionService()
        let productService = Container.shared.productService()

        Task { @MainActor in
            do {
                let products = try await productService.fetchProducts(for: [productId])
                guard let product = products.first else {
                    self.flowWebView.sendBridgeMessage(type: "purchase_error", payload: ["error": "Product not found"])
                    return
                }
                let syncResult = try await transactionService.purchase(product)
                self.flowWebView.sendBridgeMessage(type: "purchase_ui_success", payload: ["productId": productId])
                if let syncTask = syncResult.syncTask {
                    let confirmed = await syncTask.value
                    if confirmed {
                        self.flowWebView.sendBridgeMessage(type: "purchase_confirmed", payload: ["productId": productId])
                    }
                }
            } catch StoreKitError.purchaseCancelled {
                self.flowWebView.sendBridgeMessage(type: "purchase_cancelled", payload: [:])
            } catch {
                self.flowWebView.sendBridgeMessage(type: "purchase_error", payload: ["error": error.localizedDescription])
            }
        }
    }

    fileprivate func handleBridgeRestore(requestId: String?) {
        LogDebug("FlowViewController: Bridge restore purchases")
        let transactionService = Container.shared.transactionService()
        Task { @MainActor in
            do {
                try await transactionService.restore()
                self.flowWebView.sendBridgeMessage(type: "restore_success", payload: [:])
            } catch {
                self.flowWebView.sendBridgeMessage(type: "restore_error", payload: ["error": error.localizedDescription])
            }
        }
    }
}
