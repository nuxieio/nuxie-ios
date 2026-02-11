import Foundation
import FactoryKit
import WebKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(SafariServices)
import SafariServices
#endif

/// Delegate for Flow runtime bridge messages
protocol FlowRuntimeDelegate: AnyObject {
    func flowViewController(
        _ controller: FlowViewController,
        didReceiveRuntimeMessage type: String,
        payload: [String: Any],
        id: String?
    )
    func flowViewControllerDidRequestDismiss(_ controller: FlowViewController, reason: CloseReason)
}

/// FlowViewController - displays flow content in a WebView with loading and error states
public class FlowViewController: NuxiePlatformViewController, FlowMessageHandlerDelegate {

    // MARK: - Properties

    private let viewModel: FlowViewModel
    private let fontStore: FontStore

    /// Delegate for runtime bridge messages
    weak var runtimeDelegate: FlowRuntimeDelegate?

    /// Closure called when the flow is closed
    public var onClose: ((CloseReason) -> Void)?

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

    // MARK: - Computed Properties

    var flow: Flow {
        return viewModel.flow
    }

    var products: [FlowProduct] {
        return viewModel.products
    }

    // MARK: - Initialization

    init(flow: Flow, archiveService: FlowArchiver, fontStore: FontStore = FontStore()) {
        self.viewModel = FlowViewModel(
            flow: flow,
            archiveService: archiveService,
            fontStore: fontStore
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
        viewModel.loadFlow()
    }

    #if canImport(UIKit)
    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
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

    func performPurchase(productId: String, placementIndex: Any? = nil) {
        handleBridgePurchase(productId: productId, requestId: nil)
    }

    func performRestore() {
        handleBridgeRestore(requestId: nil)
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
            flowWebView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
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
    func invokeOnCloseOnce(_ reason: CloseReason) {
        guard !didInvokeClose else { return }
        didInvokeClose = true
        onClose?(reason)
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
