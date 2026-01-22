import Foundation
import UIKit
import WebKit
import FactoryKit

/// Delegate for Flow runtime bridge messages
protocol FlowRuntimeDelegate: AnyObject {
    func flowViewController(_ controller: FlowViewController, didReceiveRuntimeMessage type: String, payload: [String: Any], id: String?)
    func flowViewControllerDidRequestDismiss(_ controller: FlowViewController, reason: CloseReason)
}

/// FlowViewController - displays flow content in a WebView with loading and error states
public class FlowViewController: UIViewController, FlowMessageHandlerDelegate {
    
    // MARK: - Properties
    
    private let viewModel: FlowViewModel

    /// Delegate for runtime bridge messages
    weak var runtimeDelegate: FlowRuntimeDelegate?
    
    /// Closure called when the flow is closed
    public var onClose: ((CloseReason) -> Void)?
    
    // UI Components
    internal var flowWebView: FlowWebView!
    private var loadingView: UIView!
    private var errorView: UIView!
    private var activityIndicator: UIActivityIndicatorView!
    private var refreshButton: UIButton!
    private var closeButton: UIButton!

    // Runtime readiness + message buffering
    private var runtimeReady = false
    private var pendingRuntimeMessages: [(type: String, payload: [String: Any], replyTo: String?)] = []
    
    // MARK: - Computed Properties
    
    var flow: Flow {
        return viewModel.flow
    }
    
    var products: [FlowProduct] {
        return viewModel.products
    }
    
    // MARK: - Initialization
    
    init(flow: Flow, archiveService: FlowArchiver) {
        self.viewModel = FlowViewModel(flow: flow, archiveService: archiveService)
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
    
    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Timer cleanup is handled by view model
    }
    
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
        
        // Product injection handled via runtime bridge when needed
    }
    
    private func setupViews() {
        view.backgroundColor = .systemBackground
        
        // Setup web view
        setupWebView()
        
        // Setup loading view
        setupLoadingView()
        
        // Setup error view
        setupErrorView()
        
        // Bridge-only: no legacy message controller
        
        // Start in loading state
        updateUIState(.loading)
    }
    
    private func setupWebView() {
        flowWebView = FlowWebView(messageHandlerDelegate: self)
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
    
    private func setupLoadingView() {
        // Container view
        loadingView = UIView()
        loadingView.backgroundColor = .systemBackground
        loadingView.isHidden = true
        view.addSubview(loadingView)
        
        // Activity indicator
        if #available(iOS 13.0, *) {
            activityIndicator = UIActivityIndicatorView(style: .large)
        } else {
            activityIndicator = UIActivityIndicatorView(style: .whiteLarge)
            activityIndicator.color = .gray
        }
        activityIndicator.hidesWhenStopped = true
        loadingView.addSubview(activityIndicator)
        
        // Loading label
        let loadingLabel = UILabel()
        loadingLabel.text = "Loading..."
        loadingLabel.textColor = .secondaryLabel
        loadingLabel.font = .systemFont(ofSize: 16)
        loadingLabel.textAlignment = .center
        loadingView.addSubview(loadingLabel)
        
        // Setup constraints
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            loadingView.topAnchor.constraint(equalTo: view.topAnchor),
            loadingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            activityIndicator.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: loadingView.centerYAnchor, constant: -20),
            
            loadingLabel.topAnchor.constraint(equalTo: activityIndicator.bottomAnchor, constant: 16),
            loadingLabel.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor)
        ])
    }
    
    private func setupErrorView() {
        // Container view
        errorView = UIView()
        errorView.backgroundColor = .systemBackground
        errorView.isHidden = true
        view.addSubview(errorView)
        
        // Refresh button with icon
        refreshButton = UIButton(type: .system)
        if let refreshImage = UIImage(systemName: "arrow.clockwise") {
            refreshButton.setImage(refreshImage, for: .normal)
        }
        refreshButton.setTitle(" Refresh", for: .normal)
        refreshButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        refreshButton.backgroundColor = .systemBlue
        refreshButton.setTitleColor(.white, for: .normal)
        refreshButton.tintColor = .white
        refreshButton.layer.cornerRadius = 22
        refreshButton.addAction(UIAction { [weak self] _ in
            self?.viewModel.retry()
        }, for: .touchUpInside)
        errorView.addSubview(refreshButton)
        
        // Close button
        closeButton = UIButton(type: .system)
        closeButton.setTitle("Close", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 17)
        closeButton.setTitleColor(.label, for: .normal)
        closeButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.runtimeDelegate?.flowViewControllerDidRequestDismiss(self, reason: .userDismissed)
            self.dismiss(animated: true) { self.onClose?(.userDismissed) }
        }, for: .touchUpInside)
        errorView.addSubview(closeButton)
        
        // Setup constraints
        errorView.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            errorView.topAnchor.constraint(equalTo: view.topAnchor),
            errorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            // Refresh button centered
            refreshButton.centerXAnchor.constraint(equalTo: errorView.centerXAnchor),
            refreshButton.centerYAnchor.constraint(equalTo: errorView.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 140),
            refreshButton.heightAnchor.constraint(equalToConstant: 44),
            
            // Close button below refresh
            closeButton.topAnchor.constraint(equalTo: refreshButton.bottomAnchor, constant: 16),
            closeButton.centerXAnchor.constraint(equalTo: errorView.centerXAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 100),
            closeButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }
    
    // MARK: - UI State Management
    
    private func updateUIState(_ state: FlowViewModel.State) {
        // This is already called on main thread from the view model's binding
        switch state {
        case .loading:
            self.flowWebView.isHidden = true
            self.loadingView.isHidden = false
            self.errorView.isHidden = true
            self.activityIndicator.startAnimating()
            
        case .loaded:
            self.flowWebView.isHidden = false
            self.loadingView.isHidden = true
            self.errorView.isHidden = true
            self.activityIndicator.stopAnimating()
            
        case .error:
            self.flowWebView.isHidden = true
            self.loadingView.isHidden = true
            self.errorView.isHidden = false
            self.activityIndicator.stopAnimating()
        }
    }
    
    // MARK: - Actions
}

// MARK: - FlowMessageHandlerDelegate

extension FlowViewController {
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

    // Handle @nuxie/bridge messages directly
    func messageHandler(_ handler: FlowMessageHandler, didReceiveBridgeMessage type: String, payload: [String : Any], id: String?, from webView: FlowWebView) {
        switch type {
        case "runtime/ready":
            runtimeReady = true
            runtimeDelegate?.flowViewController(self, didReceiveRuntimeMessage: type, payload: payload, id: id)
            flushPendingRuntimeMessages()
        case "runtime/screen_changed", "action/view_model_changed", "action/event":
            runtimeDelegate?.flowViewController(self, didReceiveRuntimeMessage: type, payload: payload, id: id)
        case "action/purchase":
            if runtimeDelegate != nil {
                runtimeDelegate?.flowViewController(self, didReceiveRuntimeMessage: type, payload: payload, id: id)
            } else if let productId = payload["productId"] as? String {
                self.handleBridgePurchase(productId: productId, requestId: id)
            }
        case "action/restore":
            if runtimeDelegate != nil {
                runtimeDelegate?.flowViewController(self, didReceiveRuntimeMessage: type, payload: payload, id: id)
            } else {
                self.handleBridgeRestore(requestId: id)
            }
        case "action/dismiss":
            runtimeDelegate?.flowViewControllerDidRequestDismiss(self, reason: .userDismissed)
            dismiss(animated: true) { self.onClose?(.userDismissed) }
        case "dismiss", "closeFlow":
            runtimeDelegate?.flowViewControllerDidRequestDismiss(self, reason: .userDismissed)
            dismiss(animated: true) { self.onClose?(.userDismissed) }
        case "openURL":
            if let urlString = payload["url"] as? String, let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
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
    func flushPendingRuntimeMessages() {
        guard runtimeReady, !pendingRuntimeMessages.isEmpty else { return }
        let queued = pendingRuntimeMessages
        pendingRuntimeMessages.removeAll()
        for message in queued {
            flowWebView.sendBridgeMessage(type: message.type, payload: message.payload, replyTo: message.replyTo, completion: nil)
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
                try await transactionService.purchase(product)
                self.flowWebView.sendBridgeMessage(type: "purchase_success", payload: ["productId": productId])
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

// (Legacy FlowMessageControllerDelegate removed — bridge-only path)
