import Foundation
@testable import Nuxie

/// Mock implementation of JourneyStore for testing
public class MockJourneyStore: JourneyStoreProtocol {
    private var activeJourneys: [String: Journey] = [:]
    private var completionRecords: [String: [JourneyCompletionRecord]] = [:]
    
    public var shouldThrowOnSave = false
    public var shouldThrowOnRecord = false
    
    public func saveJourney(_ journey: Journey) throws {
        if shouldThrowOnSave {
            throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mock save error"])
        }
        activeJourneys[journey.id] = journey
    }
    
    public func loadActiveJourneys() -> [Journey] {
        return Array(activeJourneys.values)
    }
    
    public func loadJourney(id: String) -> Journey? {
        return activeJourneys[id]
    }
    
    public func deleteJourney(id: String) {
        activeJourneys.removeValue(forKey: id)
    }
    
    public func recordCompletion(_ record: JourneyCompletionRecord) throws {
        if shouldThrowOnRecord {
            throw NSError(domain: "TestError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Mock record error"])
        }
        let key = "\(record.distinctId):\(record.campaignId)"
        completionRecords[key, default: []].append(record)
    }
    
    public func hasCompletedCampaign(distinctId: String, campaignId: String) -> Bool {
        let key = "\(distinctId):\(campaignId)"
        return completionRecords[key]?.isEmpty == false
    }
    
    public func lastCompletionTime(distinctId: String, campaignId: String) -> Date? {
        let key = "\(distinctId):\(campaignId)"
        return completionRecords[key]?.last?.completedAt
    }
    
    public func cleanup(olderThan date: Date) {
        // Remove old journeys
        activeJourneys = activeJourneys.filter { $0.value.startedAt >= date }
        
        // Remove old completion records
        for key in completionRecords.keys {
            completionRecords[key] = completionRecords[key]?.filter { $0.completedAt >= date }
        }
    }
    
    public func getActiveJourneyIds(distinctId: String, campaignId: String) -> Set<String> {
        let matching = activeJourneys.values.filter { 
            $0.distinctId == distinctId && $0.campaignId == campaignId && $0.status.isActive 
        }
        return Set(matching.map { $0.id })
    }
    
    public func updateCache(for journey: Journey) {
        // No-op for mock
    }
    
    public func clearCache() {
        // No-op for mock
    }
    
    // Test helpers
    public func reset() {
        activeJourneys.removeAll()
        completionRecords.removeAll()
        shouldThrowOnSave = false
        shouldThrowOnRecord = false
    }
    
    public func getCompletions(for distinctId: String) -> [JourneyCompletionRecord] {
        return completionRecords.values.flatMap { $0 }.filter { $0.distinctId == distinctId }
    }
    
    // Public access for test convenience (from legacy mock)
    public var mockActiveJourneys: [Journey] {
        get { Array(activeJourneys.values) }
        set { 
            activeJourneys.removeAll()
            for journey in newValue {
                activeJourneys[journey.id] = journey
            }
        }
    }
    
    public var mockCompletionRecords: [JourneyCompletionRecord] {
        get { completionRecords.values.flatMap { $0 } }
        set {
            completionRecords.removeAll()
            for record in newValue {
                let key = "\(record.distinctId):\(record.campaignId)"
                completionRecords[key, default: []].append(record)
            }
        }
    }
}
