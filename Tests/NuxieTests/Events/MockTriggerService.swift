import Foundation
@testable import Nuxie

public actor MockTriggerService: TriggerServiceProtocol {
    private var updatesToEmit: [TriggerUpdate] = []

    public init() {}

    public func setUpdates(_ updates: [TriggerUpdate]) {
        updatesToEmit = updates
    }

    public func trigger(
        _ event: String,
        properties: [String: Any]?,
        userProperties: [String: Any]?,
        userPropertiesSetOnce: [String: Any]?,
        handler: @escaping (TriggerUpdate) -> Void
    ) async {
        for update in updatesToEmit {
            await MainActor.run {
                handler(update)
            }
        }
    }
}
