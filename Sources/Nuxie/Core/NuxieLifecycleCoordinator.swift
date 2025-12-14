import Foundation
import UIKit
import FactoryKit

// NuxieLifecycleCoordinator.swift
final class NuxieLifecycleCoordinator {
  private var observers: [NSObjectProtocol] = []

  @Injected(\.sessionService) private var sessionService: SessionServiceProtocol
  @Injected(\.journeyService) private var journeyService: JourneyServiceProtocol
  @Injected(\.eventService) private var eventService: EventServiceProtocol
  @Injected(\.profileService) private var profileService: ProfileServiceProtocol
  @Injected(\.flowPresentationService) private var flowPresentationService: FlowPresentationServiceProtocol
  @Injected(\.pluginService) private var pluginService: PluginService
  @Injected(\.featureService) private var featureService: FeatureServiceProtocol

  func start() {
    let nc = NotificationCenter.default

    observers.append(
      nc.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil, queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        self.flowPresentationService.onAppDidEnterBackground()
        Task {
          self.sessionService.onAppDidEnterBackground()
          await self.journeyService.onAppDidEnterBackground()
          await self.eventService.onAppDidEnterBackground()
          // Notify plugins after all services have processed
          self.pluginService.onAppDidEnterBackground()
        }
      })

    observers.append(
      nc.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        object: nil, queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        Task {
          // Re-arm timers BEFORE UI is active so we can catch up time-based work,
          // but do not present flows until after didBecomeActive + debounce.
          await self.journeyService.onAppWillEnterForeground()
          // Notify plugins after journey service has processed
          self.pluginService.onAppWillEnterForeground()
        }
      })

    observers.append(
      nc.addObserver(
        forName: UIApplication.didBecomeActiveNotification,
        object: nil, queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        self.flowPresentationService.onAppBecameActive()
        Task {
          // Services can compute immediately
          self.sessionService.onAppBecameActive()
          await self.eventService.onAppBecameActive()
          await self.profileService.onAppBecameActive()
          // Sync FeatureInfo after profile refresh (for SwiftUI reactivity)
          await self.featureService.syncFeatureInfo()
          await self.journeyService.onAppBecameActive()
          // Notify plugins after all services are ready
          self.pluginService.onAppBecameActive()
        }
      })
  }

  func stop() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
  }

  deinit {
    stop()
  }
}
