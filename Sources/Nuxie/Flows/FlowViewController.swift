import Foundation
import UIKit
import WebKit
import FactoryKit

/// FlowViewController - displays flow content in a WebView with loading and error states
public class FlowViewController: UIViewController, FlowMessageHandlerDelegate {
    
    // MARK: - Properties
    
    private let viewModel: FlowViewModel
    
    /// Closure called when the flow is closed
    public var onClose: ((CloseReason) -> Void)?
    
    // UI Components
    internal var flowWebView: FlowWebView!
    private var loadingView: UIView!
    private var errorView: UIView!
    private var activityIndicator: UIActivityIndicatorView!
    private var refreshButton: UIButton!
    private var closeButton: UIButton!
    
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
        
        // Bind to product injection
        viewModel.onInjectProducts = { [weak self] products in
            self?.injectProducts()
        }
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
            self?.dismiss(animated: true)
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
    
    
    // MARK: - Product Injection
    
    private func injectProducts() {
        // Send products using @nuxie/bridge format
        let productDicts: [[String: Any]] = products.map { p in
            var d: [String: Any] = [
                "id": p.id,
                "name": p.name,
                "price": p.price
            ]
            if let period = p.period { d["period"] = period.rawValue }
            return d
        }
        let payload: [String: Any] = ["products": productDicts]
        flowWebView.sendBridgeMessage(type: "set_products", payload: payload) { _, error in
            if let error = error {
                LogError("Failed to send products via bridge: \(error)")
            } else {
                LogDebug("Sent \(self.products.count) products to flow \(self.flow.id) via bridge")
            }
        }
    }
}

// MARK: - FlowMessageHandlerDelegate

extension FlowViewController {
    // Handle @nuxie/bridge messages directly
    func messageHandler(_ handler: FlowMessageHandler, didReceiveBridgeMessage type: String, payload: [String : Any], id: String?, from webView: FlowWebView) {
        switch type {
        case "request_products":
            injectProducts()
        case "purchase":
            if let productId = payload["productId"] as? String {
                self.handleBridgePurchase(productId: productId, requestId: id)
            }
        case "restore":
            self.handleBridgeRestore(requestId: id)
        case "dismiss", "closeFlow":
            dismiss(animated: true) { self.onClose?(.userDismissed) }
        case "openURL":
            if let urlString = payload["url"] as? String, let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
            }
        default:
            LogDebug("FlowViewController: Unhandled bridge message: \(type)")
        }
    }
}

// MARK: - Bridge Action Helpers

extension FlowViewController {
    fileprivate func handleBridgePurchase(productId: String, requestId: String?) {
        LogDebug("FlowViewController: Bridge purchase for product: \(productId)")
        let transactionService = Container.shared.transactionService()
        let productService = Container.shared.productService()
        let eventService = Container.shared.eventService()

        // Track transaction start
        eventService.track(
            JourneyEvents.transactionStart,
            properties: JourneyEvents.transactionStartProperties(
                flowId: flow.id,
                productId: productId
            ),
            userProperties: nil,
            userPropertiesSetOnce: nil,
            completion: nil
        )

        Task { @MainActor in
            do {
                let products = try await productService.fetchProducts(for: [productId])
                guard let product = products.first else {
                    // Track transaction fail - product not found
                    eventService.track(
                        JourneyEvents.transactionFail,
                        properties: JourneyEvents.transactionFailProperties(
                            flowId: self.flow.id,
                            productId: productId,
                            error: "Product not found"
                        ),
                        userProperties: nil,
                        userPropertiesSetOnce: nil,
                        completion: nil
                    )
                    self.flowWebView.sendBridgeMessage(type: "purchase_error", payload: ["error": "Product not found"])
                    return
                }

                // Purchase the product - TransactionService throws on failure/cancel
                try await transactionService.purchase(product)

                // Track transaction complete
                // Note: TransactionService doesn't return transaction details yet
                // TODO: Enhance TransactionService to return transactionId, price, currency
                eventService.track(
                    JourneyEvents.transactionComplete,
                    properties: JourneyEvents.transactionCompleteProperties(
                        flowId: self.flow.id,
                        productId: productId,
                        transactionId: nil,  // Not available from current API
                        revenue: product.price,
                        currency: nil  // Not available from current API
                    ),
                    userProperties: nil,
                    userPropertiesSetOnce: nil,
                    completion: nil
                )

                self.flowWebView.sendBridgeMessage(type: "purchase_success", payload: ["productId": productId])

                // Dismiss with purchase completed - pass product details
                self.dismiss(animated: true) {
                    self.onClose?(.purchaseCompleted(productId: productId, transactionId: nil))
                }
            } catch StoreKitError.purchaseCancelled {
                // Track transaction abandon
                eventService.track(
                    JourneyEvents.transactionAbandon,
                    properties: JourneyEvents.transactionAbandonProperties(
                        flowId: self.flow.id,
                        productId: productId
                    ),
                    userProperties: nil,
                    userPropertiesSetOnce: nil,
                    completion: nil
                )
                self.flowWebView.sendBridgeMessage(type: "purchase_cancelled", payload: [:])
            } catch {
                // Track transaction fail
                eventService.track(
                    JourneyEvents.transactionFail,
                    properties: JourneyEvents.transactionFailProperties(
                        flowId: self.flow.id,
                        productId: productId,
                        error: error.localizedDescription
                    ),
                    userProperties: nil,
                    userPropertiesSetOnce: nil,
                    completion: nil
                )
                self.flowWebView.sendBridgeMessage(type: "purchase_error", payload: ["error": error.localizedDescription])
            }
        }
    }

    fileprivate func handleBridgeRestore(requestId: String?) {
        LogDebug("FlowViewController: Bridge restore purchases")
        let transactionService = Container.shared.transactionService()
        let eventService = Container.shared.eventService()

        // Track restore start
        eventService.track(
            JourneyEvents.restoreStart,
            properties: JourneyEvents.restoreStartProperties(flowId: flow.id),
            userProperties: nil,
            userPropertiesSetOnce: nil,
            completion: nil
        )

        Task { @MainActor in
            do {
                // Restore purchases - TransactionService throws on failure
                try await transactionService.restore()

                // Track restore complete
                // Note: TransactionService doesn't return restored product IDs yet
                // TODO: Enhance TransactionService to return list of restored product IDs
                eventService.track(
                    JourneyEvents.restoreComplete,
                    properties: JourneyEvents.restoreCompleteProperties(
                        flowId: self.flow.id,
                        restoredProductIds: []  // Not available from current API
                    ),
                    userProperties: nil,
                    userPropertiesSetOnce: nil,
                    completion: nil
                )

                self.flowWebView.sendBridgeMessage(type: "restore_success", payload: [:])

                // Dismiss with restore completed
                self.dismiss(animated: true) {
                    self.onClose?(.restored(productIds: []))
                }
            } catch {
                // Track restore fail
                eventService.track(
                    JourneyEvents.restoreFail,
                    properties: JourneyEvents.restoreFailProperties(
                        flowId: self.flow.id,
                        error: error.localizedDescription
                    ),
                    userProperties: nil,
                    userPropertiesSetOnce: nil,
                    completion: nil
                )
                self.flowWebView.sendBridgeMessage(type: "restore_error", payload: ["error": error.localizedDescription])
            }
        }
    }
}

// (Legacy FlowMessageControllerDelegate removed — bridge-only path)
