//
//  QuoteStore.swift
//  Quota
//
//  Manages quote generation and quota tracking.
//

import Foundation
import Nuxie

@MainActor
class QuoteStore: ObservableObject {
    @Published var quotes: [Quote] = []
    @Published private(set) var quotesRemaining: Int = 5
    @Published private(set) var isUnlimited: Bool = false
    @Published private(set) var isGenerating: Bool = false

    private let userDefaults = UserDefaults.standard
    private let quotesKey = "quota_quotes"
    private let remainingKey = "quota_remaining"
    private let unlimitedKey = "quota_unlimited"
    private let lastResetKey = "quota_last_reset"

    private let dailyLimit = 5

    init() {
        loadState()
        checkDailyReset()
    }

    func generateQuote() async {
        guard quotesRemaining > 0 || isUnlimited else {
            triggerLimitReached()
            return
        }

        isGenerating = true

        // Consume quota
        if !isUnlimited {
            quotesRemaining -= 1
        }

        // Simulate AI generation delay
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // Generate quote
        let quote = QuoteGenerator.random()
        quotes.insert(quote, at: 0)

        // Track generation
        NuxieSDK.shared.trigger("quote_generated", properties: [
            "quote_id": quote.id.uuidString,
            "remaining": quotesRemaining
        ]) { _ in }

        isGenerating = false
        saveState()
    }

    func upgradeToUnlimited() {
        isUnlimited = true
        saveState()

        NuxieSDK.shared.trigger("quota_upgraded", properties: [:]) { _ in }
    }

    func reset() {
        quotes.removeAll()
        quotesRemaining = dailyLimit
        isUnlimited = false
        saveState()
    }

    // MARK: - Private

    private func triggerLimitReached() {
        NuxieSDK.shared.trigger("quota_limit_reached", properties: [
            "daily_limit": dailyLimit
        ]) { _ in }

        // For demo, upgrade directly
        upgradeToUnlimited()
    }

    private func checkDailyReset() {
        let calendar = Calendar.current
        let now = Date()

        if let lastReset = userDefaults.object(forKey: lastResetKey) as? Date {
            if !calendar.isDate(lastReset, inSameDayAs: now) {
                // New day - reset quota
                quotesRemaining = dailyLimit
                userDefaults.set(now, forKey: lastResetKey)
                saveState()
            }
        } else {
            userDefaults.set(now, forKey: lastResetKey)
        }
    }

    // MARK: - Persistence

    private func loadState() {
        quotesRemaining = userDefaults.integer(forKey: remainingKey)
        if quotesRemaining == 0 && !userDefaults.bool(forKey: "quota_initialized") {
            quotesRemaining = dailyLimit
            userDefaults.set(true, forKey: "quota_initialized")
        }

        isUnlimited = userDefaults.bool(forKey: unlimitedKey)

        if let data = userDefaults.data(forKey: quotesKey),
           let decoded = try? JSONDecoder().decode([Quote].self, from: data) {
            quotes = decoded
        }
    }

    private func saveState() {
        userDefaults.set(quotesRemaining, forKey: remainingKey)
        userDefaults.set(isUnlimited, forKey: unlimitedKey)

        if let encoded = try? JSONEncoder().encode(quotes) {
            userDefaults.set(encoded, forKey: quotesKey)
        }
    }
}
