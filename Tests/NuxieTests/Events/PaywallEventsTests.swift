import Foundation
import Quick
import Nimble
@testable import Nuxie

/// Tests for paywall, transaction, restore, and subscription event property builders
final class PaywallEventsTests: AsyncSpec {
    override class func spec() {

        // MARK: - Test Fixtures

        var journey: Journey!

        beforeEach {
            journey = TestJourneyBuilder(id: "test-journey-123")
                .withCampaignId("test-campaign-456")
                .build()
        }

        // MARK: - Paywall Events

        describe("Paywall Events") {

            describe("paywallShownProperties") {

                it("returns required properties") {
                    let properties = JourneyEvents.paywallShownProperties(
                        journey: journey,
                        nodeId: "node-1",
                        flowId: "flow-abc"
                    )

                    expect(properties["journey_id"] as? String).to(equal(journey.id))
                    expect(properties["campaign_id"] as? String).to(equal(journey.campaignId))
                    expect(properties["node_id"] as? String).to(equal("node-1"))
                    expect(properties["flow_id"] as? String).to(equal("flow-abc"))
                }

                it("includes experiment_id when provided") {
                    let properties = JourneyEvents.paywallShownProperties(
                        journey: journey,
                        nodeId: "node-1",
                        flowId: "flow-abc",
                        experimentId: "exp-123"
                    )

                    expect(properties["experiment_id"] as? String).to(equal("exp-123"))
                }

                it("includes variant_id when provided") {
                    let properties = JourneyEvents.paywallShownProperties(
                        journey: journey,
                        nodeId: "node-1",
                        flowId: "flow-abc",
                        variantId: "var-456"
                    )

                    expect(properties["variant_id"] as? String).to(equal("var-456"))
                }

                it("includes products array when provided") {
                    let products = ["product-1", "product-2", "product-3"]
                    let properties = JourneyEvents.paywallShownProperties(
                        journey: journey,
                        nodeId: "node-1",
                        flowId: "flow-abc",
                        products: products
                    )

                    expect(properties["products"] as? [String]).to(equal(products))
                }

                it("omits optional properties when nil") {
                    let properties = JourneyEvents.paywallShownProperties(
                        journey: journey,
                        nodeId: "node-1",
                        flowId: "flow-abc"
                    )

                    expect(properties["experiment_id"]).to(beNil())
                    expect(properties["variant_id"]).to(beNil())
                    expect(properties["products"]).to(beNil())
                }
            }

            describe("paywallClosedProperties") {

                it("returns required properties with reason") {
                    let properties = JourneyEvents.paywallClosedProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        reason: .dismissed
                    )

                    expect(properties["journey_id"] as? String).to(equal(journey.id))
                    expect(properties["campaign_id"] as? String).to(equal(journey.campaignId))
                    expect(properties["flow_id"] as? String).to(equal("flow-abc"))
                    expect(properties["reason"] as? String).to(equal("dismissed"))
                }

                it("correctly sets reason for purchased") {
                    let properties = JourneyEvents.paywallClosedProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        reason: .purchased
                    )

                    expect(properties["reason"] as? String).to(equal("purchased"))
                }

                it("correctly sets reason for restored") {
                    let properties = JourneyEvents.paywallClosedProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        reason: .restored
                    )

                    expect(properties["reason"] as? String).to(equal("restored"))
                }

                it("correctly sets reason for dismissed") {
                    let properties = JourneyEvents.paywallClosedProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        reason: .dismissed
                    )

                    expect(properties["reason"] as? String).to(equal("dismissed"))
                }

                it("includes experiment context when provided") {
                    let properties = JourneyEvents.paywallClosedProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        reason: .purchased,
                        experimentId: "exp-123",
                        variantId: "var-456"
                    )

                    expect(properties["experiment_id"] as? String).to(equal("exp-123"))
                    expect(properties["variant_id"] as? String).to(equal("var-456"))
                }
            }

            describe("paywallDeclinedProperties") {

                it("returns required properties") {
                    let properties = JourneyEvents.paywallDeclinedProperties(
                        journey: journey,
                        flowId: "flow-abc"
                    )

                    expect(properties["journey_id"] as? String).to(equal(journey.id))
                    expect(properties["campaign_id"] as? String).to(equal(journey.campaignId))
                    expect(properties["flow_id"] as? String).to(equal("flow-abc"))
                }

                it("includes experiment context when provided") {
                    let properties = JourneyEvents.paywallDeclinedProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        experimentId: "exp-123",
                        variantId: "var-456"
                    )

                    expect(properties["experiment_id"] as? String).to(equal("exp-123"))
                    expect(properties["variant_id"] as? String).to(equal("var-456"))
                }
            }
        }

        // MARK: - Transaction Events

        describe("Transaction Events") {

            describe("transactionStartProperties") {

                it("returns required properties") {
                    let properties = JourneyEvents.transactionStartProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        productId: "com.app.premium.monthly"
                    )

                    expect(properties["journey_id"] as? String).to(equal(journey.id))
                    expect(properties["campaign_id"] as? String).to(equal(journey.campaignId))
                    expect(properties["flow_id"] as? String).to(equal("flow-abc"))
                    expect(properties["product_id"] as? String).to(equal("com.app.premium.monthly"))
                }

                it("includes experiment context when provided") {
                    let properties = JourneyEvents.transactionStartProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        productId: "com.app.premium.monthly",
                        experimentId: "exp-123",
                        variantId: "var-456"
                    )

                    expect(properties["experiment_id"] as? String).to(equal("exp-123"))
                    expect(properties["variant_id"] as? String).to(equal("var-456"))
                }
            }

            describe("transactionCompleteProperties") {

                it("returns required properties including revenue") {
                    let properties = JourneyEvents.transactionCompleteProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        productId: "com.app.premium.monthly",
                        revenue: Decimal(9.99),
                        currency: "USD",
                        transactionId: "txn-12345"
                    )

                    expect(properties["journey_id"] as? String).to(equal(journey.id))
                    expect(properties["campaign_id"] as? String).to(equal(journey.campaignId))
                    expect(properties["flow_id"] as? String).to(equal("flow-abc"))
                    expect(properties["product_id"] as? String).to(equal("com.app.premium.monthly"))
                    expect(properties["currency"] as? String).to(equal("USD"))
                    expect(properties["transaction_id"] as? String).to(equal("txn-12345"))
                }

                it("correctly converts Decimal revenue to Double") {
                    let properties = JourneyEvents.transactionCompleteProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        productId: "com.app.premium.monthly",
                        revenue: Decimal(99.99),
                        currency: "USD",
                        transactionId: "txn-12345"
                    )

                    let revenue = properties["revenue"] as? Double
                    expect(revenue).to(beCloseTo(99.99, within: 0.001))
                }

                it("handles zero revenue") {
                    let properties = JourneyEvents.transactionCompleteProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        productId: "com.app.premium.monthly",
                        revenue: Decimal(0),
                        currency: "USD",
                        transactionId: "txn-12345"
                    )

                    expect(properties["revenue"] as? Double).to(equal(0.0))
                }

                it("includes experiment context when provided") {
                    let properties = JourneyEvents.transactionCompleteProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        productId: "com.app.premium.monthly",
                        revenue: Decimal(9.99),
                        currency: "USD",
                        transactionId: "txn-12345",
                        experimentId: "exp-123",
                        variantId: "var-456"
                    )

                    expect(properties["experiment_id"] as? String).to(equal("exp-123"))
                    expect(properties["variant_id"] as? String).to(equal("var-456"))
                }
            }

            describe("transactionFailProperties") {

                it("returns required properties including error") {
                    let properties = JourneyEvents.transactionFailProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        productId: "com.app.premium.monthly",
                        error: "Payment declined"
                    )

                    expect(properties["journey_id"] as? String).to(equal(journey.id))
                    expect(properties["campaign_id"] as? String).to(equal(journey.campaignId))
                    expect(properties["flow_id"] as? String).to(equal("flow-abc"))
                    expect(properties["product_id"] as? String).to(equal("com.app.premium.monthly"))
                    expect(properties["error"] as? String).to(equal("Payment declined"))
                }

                it("includes error_code when provided") {
                    let properties = JourneyEvents.transactionFailProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        productId: "com.app.premium.monthly",
                        error: "Payment declined",
                        errorCode: "CARD_DECLINED"
                    )

                    expect(properties["error_code"] as? String).to(equal("CARD_DECLINED"))
                }

                it("omits error_code when nil") {
                    let properties = JourneyEvents.transactionFailProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        productId: "com.app.premium.monthly",
                        error: "Payment declined"
                    )

                    expect(properties["error_code"]).to(beNil())
                }

                it("includes experiment context when provided") {
                    let properties = JourneyEvents.transactionFailProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        productId: "com.app.premium.monthly",
                        error: "Payment declined",
                        experimentId: "exp-123",
                        variantId: "var-456"
                    )

                    expect(properties["experiment_id"] as? String).to(equal("exp-123"))
                    expect(properties["variant_id"] as? String).to(equal("var-456"))
                }
            }

            describe("transactionAbandonProperties") {

                it("returns required properties") {
                    let properties = JourneyEvents.transactionAbandonProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        productId: "com.app.premium.monthly"
                    )

                    expect(properties["journey_id"] as? String).to(equal(journey.id))
                    expect(properties["campaign_id"] as? String).to(equal(journey.campaignId))
                    expect(properties["flow_id"] as? String).to(equal("flow-abc"))
                    expect(properties["product_id"] as? String).to(equal("com.app.premium.monthly"))
                }

                it("includes experiment context when provided") {
                    let properties = JourneyEvents.transactionAbandonProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        productId: "com.app.premium.monthly",
                        experimentId: "exp-123",
                        variantId: "var-456"
                    )

                    expect(properties["experiment_id"] as? String).to(equal("exp-123"))
                    expect(properties["variant_id"] as? String).to(equal("var-456"))
                }
            }
        }

        // MARK: - Restore Events

        describe("Restore Events") {

            describe("restoreStartProperties") {

                it("returns required properties") {
                    let properties = JourneyEvents.restoreStartProperties(
                        journey: journey,
                        flowId: "flow-abc"
                    )

                    expect(properties["journey_id"] as? String).to(equal(journey.id))
                    expect(properties["campaign_id"] as? String).to(equal(journey.campaignId))
                    expect(properties["flow_id"] as? String).to(equal("flow-abc"))
                }
            }

            describe("restoreCompleteProperties") {

                it("returns required properties with restored product ids") {
                    let restoredProducts = ["com.app.premium.monthly", "com.app.addon.feature"]
                    let properties = JourneyEvents.restoreCompleteProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        restoredProductIds: restoredProducts
                    )

                    expect(properties["journey_id"] as? String).to(equal(journey.id))
                    expect(properties["campaign_id"] as? String).to(equal(journey.campaignId))
                    expect(properties["flow_id"] as? String).to(equal("flow-abc"))
                    expect(properties["restored_product_ids"] as? [String]).to(equal(restoredProducts))
                }

                it("handles empty restored product ids") {
                    let properties = JourneyEvents.restoreCompleteProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        restoredProductIds: []
                    )

                    expect(properties["restored_product_ids"] as? [String]).to(equal([]))
                }
            }

            describe("restoreFailProperties") {

                it("returns required properties including error") {
                    let properties = JourneyEvents.restoreFailProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        error: "No purchases to restore"
                    )

                    expect(properties["journey_id"] as? String).to(equal(journey.id))
                    expect(properties["campaign_id"] as? String).to(equal(journey.campaignId))
                    expect(properties["flow_id"] as? String).to(equal("flow-abc"))
                    expect(properties["error"] as? String).to(equal("No purchases to restore"))
                }

                it("includes error_code when provided") {
                    let properties = JourneyEvents.restoreFailProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        error: "No purchases to restore",
                        errorCode: "NO_PURCHASES"
                    )

                    expect(properties["error_code"] as? String).to(equal("NO_PURCHASES"))
                }

                it("omits error_code when nil") {
                    let properties = JourneyEvents.restoreFailProperties(
                        journey: journey,
                        flowId: "flow-abc",
                        error: "No purchases to restore"
                    )

                    expect(properties["error_code"]).to(beNil())
                }
            }
        }

        // MARK: - Subscription Events

        describe("Subscription Events") {

            describe("subscriptionStartProperties") {

                it("returns required properties") {
                    let properties = JourneyEvents.subscriptionStartProperties(
                        productId: "com.app.premium.monthly",
                        revenue: Decimal(9.99),
                        currency: "USD",
                        transactionId: "txn-12345"
                    )

                    expect(properties["product_id"] as? String).to(equal("com.app.premium.monthly"))
                    expect(properties["currency"] as? String).to(equal("USD"))
                    expect(properties["transaction_id"] as? String).to(equal("txn-12345"))
                }

                it("correctly converts Decimal revenue to Double") {
                    let properties = JourneyEvents.subscriptionStartProperties(
                        productId: "com.app.premium.monthly",
                        revenue: Decimal(49.99),
                        currency: "USD",
                        transactionId: "txn-12345"
                    )

                    let revenue = properties["revenue"] as? Double
                    expect(revenue).to(beCloseTo(49.99, within: 0.001))
                }

                it("includes journey context when provided") {
                    let properties = JourneyEvents.subscriptionStartProperties(
                        productId: "com.app.premium.monthly",
                        revenue: Decimal(9.99),
                        currency: "USD",
                        transactionId: "txn-12345",
                        journey: journey
                    )

                    expect(properties["journey_id"] as? String).to(equal(journey.id))
                    expect(properties["campaign_id"] as? String).to(equal(journey.campaignId))
                }

                it("includes flow_id when provided") {
                    let properties = JourneyEvents.subscriptionStartProperties(
                        productId: "com.app.premium.monthly",
                        revenue: Decimal(9.99),
                        currency: "USD",
                        transactionId: "txn-12345",
                        flowId: "flow-abc"
                    )

                    expect(properties["flow_id"] as? String).to(equal("flow-abc"))
                }

                it("works without journey context for standalone purchase") {
                    let properties = JourneyEvents.subscriptionStartProperties(
                        productId: "com.app.premium.monthly",
                        revenue: Decimal(9.99),
                        currency: "USD",
                        transactionId: "txn-12345"
                    )

                    expect(properties["journey_id"]).to(beNil())
                    expect(properties["campaign_id"]).to(beNil())
                    expect(properties["flow_id"]).to(beNil())
                }
            }

            describe("freeTrialStartProperties") {

                it("returns required properties") {
                    let properties = JourneyEvents.freeTrialStartProperties(
                        productId: "com.app.premium.monthly",
                        offerType: "free_trial",
                        transactionId: "txn-12345"
                    )

                    expect(properties["product_id"] as? String).to(equal("com.app.premium.monthly"))
                    expect(properties["offer_type"] as? String).to(equal("free_trial"))
                    expect(properties["transaction_id"] as? String).to(equal("txn-12345"))
                }

                it("includes journey context when provided") {
                    let properties = JourneyEvents.freeTrialStartProperties(
                        productId: "com.app.premium.monthly",
                        offerType: "free_trial",
                        transactionId: "txn-12345",
                        journey: journey
                    )

                    expect(properties["journey_id"] as? String).to(equal(journey.id))
                    expect(properties["campaign_id"] as? String).to(equal(journey.campaignId))
                }

                it("includes flow_id when provided") {
                    let properties = JourneyEvents.freeTrialStartProperties(
                        productId: "com.app.premium.monthly",
                        offerType: "introductory",
                        transactionId: "txn-12345",
                        flowId: "flow-abc"
                    )

                    expect(properties["flow_id"] as? String).to(equal("flow-abc"))
                }
            }

            describe("nonRecurringProductPurchaseProperties") {

                it("returns required properties") {
                    let properties = JourneyEvents.nonRecurringProductPurchaseProperties(
                        productId: "com.app.lifetime",
                        revenue: Decimal(99.99),
                        currency: "USD",
                        transactionId: "txn-12345"
                    )

                    expect(properties["product_id"] as? String).to(equal("com.app.lifetime"))
                    expect(properties["currency"] as? String).to(equal("USD"))
                    expect(properties["transaction_id"] as? String).to(equal("txn-12345"))
                }

                it("correctly converts Decimal revenue to Double") {
                    let properties = JourneyEvents.nonRecurringProductPurchaseProperties(
                        productId: "com.app.lifetime",
                        revenue: Decimal(199.99),
                        currency: "EUR",
                        transactionId: "txn-12345"
                    )

                    let revenue = properties["revenue"] as? Double
                    expect(revenue).to(beCloseTo(199.99, within: 0.001))
                }

                it("includes journey context when provided") {
                    let properties = JourneyEvents.nonRecurringProductPurchaseProperties(
                        productId: "com.app.lifetime",
                        revenue: Decimal(99.99),
                        currency: "USD",
                        transactionId: "txn-12345",
                        journey: journey
                    )

                    expect(properties["journey_id"] as? String).to(equal(journey.id))
                    expect(properties["campaign_id"] as? String).to(equal(journey.campaignId))
                }
            }
        }

        // MARK: - Enum Tests

        describe("PaywallCloseReason") {

            it("purchased has rawValue 'purchased'") {
                expect(JourneyEvents.PaywallCloseReason.purchased.rawValue).to(equal("purchased"))
            }

            it("restored has rawValue 'restored'") {
                expect(JourneyEvents.PaywallCloseReason.restored.rawValue).to(equal("restored"))
            }

            it("dismissed has rawValue 'dismissed'") {
                expect(JourneyEvents.PaywallCloseReason.dismissed.rawValue).to(equal("dismissed"))
            }
        }

        describe("SubscriptionType") {

            it("subscription has rawValue 'subscription'") {
                expect(JourneyEvents.SubscriptionType.subscription.rawValue).to(equal("subscription"))
            }

            it("freeTrialStart has rawValue 'free_trial'") {
                expect(JourneyEvents.SubscriptionType.freeTrialStart.rawValue).to(equal("free_trial"))
            }

            it("nonRecurring has rawValue 'non_recurring'") {
                expect(JourneyEvents.SubscriptionType.nonRecurring.rawValue).to(equal("non_recurring"))
            }
        }

        // MARK: - Event Name Constants

        describe("Event Name Constants") {

            it("paywall event names have correct $ prefix") {
                expect(JourneyEvents.paywallShown).to(equal("$paywall_shown"))
                expect(JourneyEvents.paywallClosed).to(equal("$paywall_closed"))
                expect(JourneyEvents.paywallDeclined).to(equal("$paywall_declined"))
            }

            it("transaction event names have correct $ prefix") {
                expect(JourneyEvents.transactionStart).to(equal("$transaction_start"))
                expect(JourneyEvents.transactionComplete).to(equal("$transaction_complete"))
                expect(JourneyEvents.transactionFail).to(equal("$transaction_fail"))
                expect(JourneyEvents.transactionAbandon).to(equal("$transaction_abandon"))
            }

            it("restore event names have correct $ prefix") {
                expect(JourneyEvents.restoreStart).to(equal("$restore_start"))
                expect(JourneyEvents.restoreComplete).to(equal("$restore_complete"))
                expect(JourneyEvents.restoreFail).to(equal("$restore_fail"))
            }

            it("subscription event names have correct $ prefix") {
                expect(JourneyEvents.subscriptionStart).to(equal("$subscription_start"))
                expect(JourneyEvents.freeTrialStart).to(equal("$free_trial_start"))
                expect(JourneyEvents.nonRecurringProductPurchase).to(equal("$non_recurring_product_purchase"))
            }
        }
    }
}
