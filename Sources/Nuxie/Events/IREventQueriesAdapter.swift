import Foundation

/// Adapter that bridges EventServiceProtocol to IREventQueries
public struct IREventQueriesAdapter: IREventQueries {
    private let eventService: EventServiceProtocol
    
    public init(eventService: EventServiceProtocol) {
        self.eventService = eventService
    }
    
    public func exists(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Bool {
        return await eventService.exists(name: name, since: since, until: until, where: predicate)
    }
    
    public func count(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Int {
        return await eventService.count(name: name, since: since, until: until, where: predicate)
    }
    
    public func firstTime(name: String, where predicate: IRPredicate?) async -> Date? {
        return await eventService.firstTime(name: name, where: predicate)
    }
    
    public func lastTime(name: String, where predicate: IRPredicate?) async -> Date? {
        return await eventService.lastTime(name: name, where: predicate)
    }
    
    public func aggregate(_ agg: Aggregate, name: String, prop: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Double? {
        return await eventService.aggregate(agg, name: name, prop: prop, since: since, until: until, where: predicate)
    }
    
    public func inOrder(steps: [StepQuery], overallWithin: TimeInterval?, perStepWithin: TimeInterval?, since: Date?, until: Date?) async -> Bool {
        return await eventService.inOrder(steps: steps, overallWithin: overallWithin, perStepWithin: perStepWithin, since: since, until: until)
    }
    
    public func activePeriods(name: String, period: Period, total: Int, min: Int, where predicate: IRPredicate?) async -> Bool {
        return await eventService.activePeriods(name: name, period: period, total: total, min: min, where: predicate)
    }
    
    public func stopped(name: String, inactiveFor: TimeInterval, where predicate: IRPredicate?) async -> Bool {
        return await eventService.stopped(name: name, inactiveFor: inactiveFor, where: predicate)
    }
    
    public func restarted(name: String, inactiveFor: TimeInterval, within: TimeInterval, where predicate: IRPredicate?) async -> Bool {
        return await eventService.restarted(name: name, inactiveFor: inactiveFor, within: within, where: predicate)
    }
}