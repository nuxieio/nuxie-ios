import UIKit
import Nuxie

class ViewController: UIViewController {
    
    private var photoImageView: UIImageView!
    private var filtersStackView: UIStackView!
    private var premiumButton: UIButton!
    private var currentFilter: FilterType = .original
    
    enum FilterType {
        case original
        case blackWhite
        case sepia
        case vintage
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        print("[ViewController] viewDidLoad called")
        
        title = "Photo Editor Pro"
        view.backgroundColor = .systemBackground
        
        setupUI()
        
        // Identify user as a free tier user
        NuxieSDK.shared.identify(
            "demo_user_123",
            userProperties: [
                "subscription_tier": "free",
                "app_version": "1.0.0",
                "user_type": "demo"
            ]
        )
        
        // Track app opened event
        NuxieSDK.shared.track("photo_editor_opened", properties: [:])
        
        print("[ViewController] viewDidLoad completed")
    }
    
    private func setupUI() {
        // Photo display
        photoImageView = UIImageView()
        photoImageView.contentMode = .scaleAspectFit
        photoImageView.backgroundColor = .systemGray6
        photoImageView.layer.cornerRadius = 12
        photoImageView.clipsToBounds = true
        photoImageView.translatesAutoresizingMaskIntoConstraints = false
        
        // Load demo image (using SF Symbol as placeholder)
        let config = UIImage.SymbolConfiguration(pointSize: 100, weight: .light)
        photoImageView.image = UIImage(systemName: "photo", withConfiguration: config)?.withTintColor(.systemGray3, renderingMode: .alwaysOriginal)
        
        // Free filters section
        let freeFiltersLabel = UILabel()
        freeFiltersLabel.text = "Free Filters"
        freeFiltersLabel.font = .boldSystemFont(ofSize: 18)
        freeFiltersLabel.textAlignment = .center
        
        let freeFiltersStack = UIStackView()
        freeFiltersStack.axis = .horizontal
        freeFiltersStack.distribution = .fillEqually
        freeFiltersStack.spacing = 12
        
        let originalButton = createFilterButton(title: "Original", action: #selector(originalTapped))
        let bwButton = createFilterButton(title: "B&W", action: #selector(blackWhiteTapped))
        let sepiaButton = createFilterButton(title: "Sepia", action: #selector(sepiaTapped))
        
        freeFiltersStack.addArrangedSubview(originalButton)
        freeFiltersStack.addArrangedSubview(bwButton)
        freeFiltersStack.addArrangedSubview(sepiaButton)
        
        // Premium section
        let premiumLabel = UILabel()
        premiumLabel.text = "Pro Filters"
        premiumLabel.font = .boldSystemFont(ofSize: 18)
        premiumLabel.textAlignment = .center
        
        premiumButton = UIButton(type: .system)
        premiumButton.setTitle("🔒 Unlock Pro Filters", for: .normal)
        premiumButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        premiumButton.backgroundColor = .systemPurple
        premiumButton.setTitleColor(.white, for: .normal)
        premiumButton.layer.cornerRadius = 12
        premiumButton.addTarget(self, action: #selector(premiumFiltersTapped), for: .touchUpInside)
        
        // Open Flow (static id) demo button
        let openFlowButton = UIButton(type: .system)
        openFlowButton.setTitle("🌐 Open Flow (static id)", for: .normal)
        openFlowButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        openFlowButton.backgroundColor = .systemTeal
        openFlowButton.setTitleColor(.white, for: .normal)
        openFlowButton.layer.cornerRadius = 12
        openFlowButton.heightAnchor.constraint(equalToConstant: 50).isActive = true
        openFlowButton.addTarget(self, action: #selector(openStaticFlowTapped), for: .touchUpInside)
        
        // Main stack view
        let mainStackView = UIStackView()
        mainStackView.axis = .vertical
        mainStackView.spacing = 24
        mainStackView.translatesAutoresizingMaskIntoConstraints = false
        
        mainStackView.addArrangedSubview(photoImageView)
        mainStackView.addArrangedSubview(freeFiltersLabel)
        mainStackView.addArrangedSubview(freeFiltersStack)
        mainStackView.addArrangedSubview(premiumLabel)
        mainStackView.addArrangedSubview(premiumButton)
        mainStackView.addArrangedSubview(openFlowButton)
        
        view.addSubview(mainStackView)
        
        NSLayoutConstraint.activate([
            photoImageView.heightAnchor.constraint(equalToConstant: 300),
            premiumButton.heightAnchor.constraint(equalToConstant: 50),
            
            mainStackView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            mainStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            mainStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
    }
    
    private func createFilterButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.backgroundColor = .systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        button.addTarget(self, action: action, for: .touchUpInside)
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }
    
    // MARK: - Filter Actions
    
    @objc private func originalTapped() {
        applyFilter(.original)
        NuxieSDK.shared.track("filter_applied", properties: ["filter_type": "original"])
    }
    
    @objc private func blackWhiteTapped() {
        applyFilter(.blackWhite)
        NuxieSDK.shared.track("filter_applied", properties: ["filter_type": "black_white"])
    }
    
    @objc private func sepiaTapped() {
        applyFilter(.sepia)
        NuxieSDK.shared.track("filter_applied", properties: ["filter_type": "sepia"])
    }
    
    @objc private func premiumFiltersTapped() {
        // Track the premium filter access attempt
        NuxieSDK.shared.track("premium_filters_accessed", properties: [
            "user_tier": "free",
            "feature": "pro_filters"
        ]) { result in
            DispatchQueue.main.async {
                switch result {
                case .noInteraction:
                    print("Event tracked, no paywall shown")
                    // For demo purposes, show paywall manually since no campaign is configured
                    self.showPaywallMessage(paywallId: "default_premium")
                case .flow(let completion):
                    switch completion.outcome {
                    case .purchased(let productId, _):
                        self.showSuccessMessage("Premium filters unlocked! 🎉")
                        self.unlockPremiumFeatures()
                        print("Purchase completed - Product: \(productId ?? "unknown")")
                    case .dismissed:
                        self.showAccessDeniedMessage()
                    case .error(let message):
                        self.showAlert(title: "Error", message: "Paywall failed: \(message ?? "Unknown error")")
                    default:
                        // Handle other outcomes like .trialStarted, .restored, .skipped
                        self.showAccessDeniedMessage()
                    }
                case .failed(let error):
                    self.showAlert(title: "Error", message: "Failed to track event: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Filter Logic
    
    private func applyFilter(_ filter: FilterType) {
        currentFilter = filter
        
        let config = UIImage.SymbolConfiguration(pointSize: 100, weight: .light)
        
        switch filter {
        case .original:
            photoImageView.image = UIImage(systemName: "photo", withConfiguration: config)?.withTintColor(.systemGray3, renderingMode: .alwaysOriginal)
        case .blackWhite:
            photoImageView.image = UIImage(systemName: "photo", withConfiguration: config)?.withTintColor(.black, renderingMode: .alwaysOriginal)
        case .sepia:
            photoImageView.image = UIImage(systemName: "photo", withConfiguration: config)?.withTintColor(.systemBrown, renderingMode: .alwaysOriginal)
        case .vintage:
            photoImageView.image = UIImage(systemName: "photo", withConfiguration: config)?.withTintColor(.systemOrange, renderingMode: .alwaysOriginal)
        }
    }
    
    private func unlockPremiumFeatures() {
        premiumButton.setTitle("✨ Vintage Filter", for: .normal)
        premiumButton.backgroundColor = .systemGreen
        premiumButton.removeTarget(nil, action: nil, for: .allEvents)
        premiumButton.addTarget(self, action: #selector(vintageFilterTapped), for: .touchUpInside)
    }
    
    @objc private func vintageFilterTapped() {
        applyFilter(.vintage)
        NuxieSDK.shared.track("filter_applied", properties: ["filter_type": "vintage"])
    }
    
    // MARK: - UI Feedback
    
    private func showSuccessMessage(_ message: String) {
        showAlert(title: "Success!", message: message)
    }
    
    private func showPaywallMessage(paywallId: String) {
        let message = """
        🔒 Premium Feature
        
        Unlock Pro Filters to access:
        • Vintage effects
        • Advanced color grading
        • Professional presets
        
        Paywall ID: \(paywallId)
        """
        
        let alert = UIAlertController(title: "Upgrade to Pro", message: message, preferredStyle: .alert)
        
        alert.addAction(UIAlertAction(title: "Upgrade Now", style: .default) { _ in
            self.simulatePurchase()
        })
        
        alert.addAction(UIAlertAction(title: "Maybe Later", style: .cancel) { _ in
            NuxieSDK.shared.track("paywall_dismissed", properties: ["paywall_id": paywallId])
        })
        
        present(alert, animated: true)
    }
    
    private func showAccessDeniedMessage() {
        showAlert(title: "Premium Required", message: "Subscribe to Photo Editor Pro to unlock advanced filters!")
    }
    
    private func simulatePurchase() {
        let alert = UIAlertController(title: "Demo Purchase", message: "This would normally integrate with StoreKit. For demo purposes, we'll simulate a successful purchase.", preferredStyle: .alert)
        
        alert.addAction(UIAlertAction(title: "Complete Purchase", style: .default) { _ in
            NuxieSDK.shared.track("purchase_completed", properties: [
                "product_id": "pro_filters",
                "price": "4.99"
            ])
            
            self.unlockPremiumFeatures()
            self.showAlert(title: "Purchase Complete!", message: "Pro filters are now unlocked! 🎉")
        })
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        present(alert, animated: true)
    }
    
    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    
    // MARK: - Open static flow
    @objc private func openStaticFlowTapped() {
        // Replace with a known flow id for the demo
        let staticFlowId = "flow_demo_123"
        Task { @MainActor in
            do {
                let vc = try await NuxieSDK.shared.getFlowViewController(with: staticFlowId)
                self.present(vc, animated: true)
            } catch {
                self.showAlert(title: "Error", message: "Failed to load flow: \(error.localizedDescription)")
            }
        }
    }
}
