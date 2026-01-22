import Foundation

public enum JourneyTriggerResult {
  case started(Journey)
  case suppressed(SuppressReason)
}
