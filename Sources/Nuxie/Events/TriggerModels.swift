import _Concurrency
import Foundation

/// Progressive updates emitted by `trigger(...)`.
public enum TriggerUpdate: Equatable {
  case decision(TriggerDecision)
  case entitlement(EntitlementUpdate)
  case journey(JourneyUpdate)
  case error(TriggerError)
}

/// High-level trigger decisions (campaign-level).
public enum TriggerDecision: Equatable {
  case noMatch
  case suppressed(SuppressReason)
  case journeyStarted(JourneyRef)
  case journeyResumed(JourneyRef)
  case flowShown(JourneyRef)
  case allowedImmediate
  case deniedImmediate
}

/// Entitlement-specific updates for gated flows.
public enum EntitlementUpdate: Equatable {
  case pending
  case allowed(source: GateSource)
  case denied
}

public struct JourneyRef: Equatable {
  public let journeyId: String
  public let campaignId: String
  public let flowId: String?

  public init(journeyId: String, campaignId: String, flowId: String?) {
    self.journeyId = journeyId
    self.campaignId = campaignId
    self.flowId = flowId
  }
}

public enum SuppressReason: Equatable {
  case alreadyActive
  case reentryLimited
  case holdout
  case noFlow
  case unknown(String)
}

public struct JourneyUpdate: Equatable {
  public let journeyId: String
  public let campaignId: String
  public let flowId: String?
  public let exitReason: JourneyExitReason
  public let goalMet: Bool
  public let goalMetAt: Date?
  public let durationSeconds: Double?
  public let flowExitReason: String?

  public init(
    journeyId: String,
    campaignId: String,
    flowId: String?,
    exitReason: JourneyExitReason,
    goalMet: Bool,
    goalMetAt: Date?,
    durationSeconds: Double?,
    flowExitReason: String?
  ) {
    self.journeyId = journeyId
    self.campaignId = campaignId
    self.flowId = flowId
    self.exitReason = exitReason
    self.goalMet = goalMet
    self.goalMetAt = goalMetAt
    self.durationSeconds = durationSeconds
    self.flowExitReason = flowExitReason
  }
}

public enum GateSource: Equatable {
  case cache
  case purchase
  case restore
}

public struct TriggerError: Error, Equatable {
  public let code: String
  public let message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}

public struct TriggerHandle: AsyncSequence {
  public typealias Element = TriggerUpdate

  private let stream: AsyncStream<TriggerUpdate>
  private let cancelHandler: (() -> Void)?

  public init(stream: AsyncStream<TriggerUpdate>, cancel: (() -> Void)? = nil) {
    self.stream = stream
    self.cancelHandler = cancel
  }

  public func makeAsyncIterator() -> AsyncStream<TriggerUpdate>.Iterator {
    stream.makeAsyncIterator()
  }

  public func cancel() {
    cancelHandler?()
  }

  public static var empty: TriggerHandle {
    let stream = AsyncStream<TriggerUpdate> { continuation in
      continuation.finish()
    }
    return TriggerHandle(stream: stream)
  }
}
