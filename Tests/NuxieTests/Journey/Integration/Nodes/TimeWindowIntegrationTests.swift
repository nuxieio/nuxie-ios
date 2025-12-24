// Path: packages/nuxie-ios/Tests/NuxieTests/Journey/Integration/TimeWindowIntegrationTests.swift

import FactoryKit
import Foundation
import Nimble
import Quick

@testable import Nuxie

/// Integration tests focused on TimeWindow node semantics
final class TimeWindowIntegrationTests: AsyncSpec {
  override class func spec() {
    describe("TimeWindow Integration") {
      // Spy + mocks
      var spy: JourneyTestSpy!

      var identityService: MockIdentityService!
      var segmentService: MockSegmentService!
      var journeyStore: MockJourneyStore!
      var spyJourneyStore: SpyJourneyStore!
      var spyJourneyExecutor: SpyJourneyExecutor!
      var profileService: MockProfileService!
      var eventService: MockEventService!
      var eventStore: MockEventStore!
      var nuxieApi: MockNuxieApi!
      var flowService: MockFlowService!
      var flowPresentationService: MockFlowPresentationService!
      var dateProvider: MockDateProvider!
      var sleepProvider: MockSleepProvider!
      var productService: MockProductService!

      var journeyService: JourneyService!

      // Helpers
      func hourMinute(_ date: Date, tz: TimeZone) -> (Int, Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let comps = cal.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0, comps.minute ?? 0)
      }

      /// Format hour and minute as "HH:mm" string
      func formatTime(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
      }

      func wrap24(_ v: Int) -> Int { (v % 24 + 24) % 24 }

      beforeEach {

        // Register test configuration (required for any services that depend on sdkConfiguration)
        let testConfig = NuxieConfiguration(apiKey: "test-api-key")
        Container.shared.sdkConfiguration.register { testConfig }

        spy = JourneyTestSpy()

        identityService = MockIdentityService()
        segmentService = MockSegmentService()
        journeyStore = MockJourneyStore()
        profileService = MockProfileService()
        eventService = MockEventService()
        eventStore = MockEventStore()
        nuxieApi = MockNuxieApi()
        flowService = MockFlowService()
        flowPresentationService = MockFlowPresentationService()
        dateProvider = MockDateProvider()
        sleepProvider = MockSleepProvider()
        productService = MockProductService()

        // Register base mocks
        Container.shared.identityService.register { identityService }
        Container.shared.segmentService.register { segmentService }
        Container.shared.profileService.register { profileService }
        Container.shared.eventService.register { eventService }
        Container.shared.nuxieApi.register { nuxieApi }
        Container.shared.flowService.register { flowService }
        Container.shared.flowPresentationService.register { flowPresentationService }
        Container.shared.dateProvider.register { dateProvider }
        Container.shared.sleepProvider.register { sleepProvider }
        Container.shared.productService.register { productService }

        // Spy wrappers
        spyJourneyStore = SpyJourneyStore(realStore: journeyStore, spy: spy)
        spyJourneyExecutor = SpyJourneyExecutor(spy: spy)

        journeyService = JourneyService(
          journeyStore: spyJourneyStore,
          journeyExecutor: spyJourneyExecutor
        )
        Container.shared.journeyService.register { journeyService }

        await journeyService.initialize()
      }

      // Don't reset container in afterEach - let beforeEach handle it
      // to avoid race conditions with background tasks accessing services
      afterEach {
        await journeyService.shutdown()
        sleepProvider.reset()
      }

      it("continues immediately when now is inside the (UTC) window") {
        let now = dateProvider.now()
        let utc = TimeZone(secondsFromGMT: 0)!

        let (h, m) = hourMinute(now, tz: utc)
        let startTime = formatTime(hour: wrap24(h - 1), minute: m)
        let endTime = formatTime(hour: wrap24(h + 1), minute: m)

        let campaign = TestCampaignBuilder()
          .withId("tw-in-window")
          .withFrequencyPolicy("every_rematch")
          .withNodes([
            AnyWorkflowNode(
              TimeWindowNode(
                id: "window",
                next: ["show"],
                data: TimeWindowNode.TimeWindowData(
                  startTime: startTime,
                  endTime: endTime,
                  timezone: "UTC",
                  daysOfWeek: nil
                )
              )),
            AnyWorkflowNode(
              ShowFlowNode(
                id: "show",
                next: ["exit"],
                data: ShowFlowNode.ShowFlowData(flowId: "tw-flow")
              )),
            AnyWorkflowNode(ExitNode(id: "exit", next: [], data: nil)),
          ])
          .withEntryNodeId("window")
          .build()

        profileService.profileResponse = TestProfileResponseBuilder()
          .addCampaign(campaign)
          .build()

        let journey = await journeyService.startJourney(for: campaign, distinctId: "user_tw_in")
        expect(journey).toNot(beNil())
        expect(journey?.status).to(equal(.completed))

        let jid = journey!.id
        spy.assertPath(["window", "show", "exit"], for: jid)
        spy.assertFlowDisplayed("tw-flow", for: jid)
        spy.assertNoPersistence(for: jid)
      }

      it("pauses and persists when now is outside the (UTC) window") {
        let now = dateProvider.now()
        let utc = TimeZone(secondsFromGMT: 0)!
        let (h, m) = hourMinute(now, tz: utc)

        let startH = wrap24(h + 1)
        let endH = wrap24(h + 2)
        let startTime = formatTime(hour: startH, minute: m)
        let endTime = formatTime(hour: endH, minute: m)

        let campaign = TestCampaignBuilder()
          .withId("tw-out-window")
          .withFrequencyPolicy("every_rematch")
          .withNodes([
            AnyWorkflowNode(
              TimeWindowNode(
                id: "window",
                next: ["show"],
                data: TimeWindowNode.TimeWindowData(
                  startTime: startTime,
                  endTime: endTime,
                  timezone: "UTC",
                  daysOfWeek: nil
                )
              )),
            AnyWorkflowNode(
              ShowFlowNode(
                id: "show",
                next: ["exit"],
                data: ShowFlowNode.ShowFlowData(flowId: "tw-flow-out")
              )),
            AnyWorkflowNode(ExitNode(id: "exit", next: [], data: nil)),
          ])
          .withEntryNodeId("window")
          .build()

        profileService.profileResponse = TestProfileResponseBuilder()
          .addCampaign(campaign)
          .build()

        let journey = await journeyService.startJourney(for: campaign, distinctId: "user_tw_out")
        expect(journey).toNot(beNil())
        expect(journey?.status).to(equal(.paused))
        expect(journey?.currentNodeId).to(equal("window"))
        expect(journey?.resumeAt).toNot(beNil())

        let jid = journey!.id
        spy.assertPath(["window"], for: jid)
        spy.assertPersistenceCount(1, for: jid)
        expect(spy.flowDisplayAttempts).to(beEmpty())

        // Expected next open: today at startH:m UTC
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        var comps = cal.dateComponents(in: utc, from: now)
        comps.hour = startH
        comps.minute = m
        comps.second = 0
        var expected = cal.date(from: comps)!
        if expected <= now { expected = cal.date(byAdding: .day, value: 1, to: expected)! }

        expect(journey!.resumeAt!.timeIntervalSince1970).to(
          beCloseTo(expected.timeIntervalSince1970, within: 1.0)
        )
      }

      it("treats overnight windows that include now as in-window (no persistence)") {
        let now = dateProvider.now()
        let utc = TimeZone(secondsFromGMT: 0)!
        let (h, m) = hourMinute(now, tz: utc)

        // Overnight that includes now: start = h-1, end = h-2
        let startTime = formatTime(hour: wrap24(h - 1), minute: m)
        let endTime = formatTime(hour: wrap24(h - 2), minute: m)

        let campaign = TestCampaignBuilder()
          .withId("tw-overnight-in")
          .withFrequencyPolicy("every_rematch")
          .withNodes([
            AnyWorkflowNode(
              TimeWindowNode(
                id: "window",
                next: ["show"],
                data: TimeWindowNode.TimeWindowData(
                  startTime: startTime,
                  endTime: endTime,
                  timezone: "UTC",
                  daysOfWeek: nil
                )
              )),
            AnyWorkflowNode(
              ShowFlowNode(
                id: "show",
                next: ["exit"],
                data: ShowFlowNode.ShowFlowData(flowId: "tw-overnight-flow")
              )),
            AnyWorkflowNode(ExitNode(id: "exit", next: [], data: nil)),
          ])
          .withEntryNodeId("window")
          .build()

        profileService.profileResponse = TestProfileResponseBuilder()
          .addCampaign(campaign)
          .build()

        let journey = await Container.shared.journeyService().startJourney(
          for: campaign, distinctId: "user_tw_overnight", originEventId: nil)
        expect(journey).toNot(beNil())
        expect(journey?.status).to(equal(.completed))

        let jid = journey!.id
        spy.assertPath(["window", "show", "exit"], for: jid)
        spy.assertFlowDisplayed("tw-overnight-flow", for: jid)
        spy.assertNoPersistence(for: jid)
      }

      it("respects daysOfWeek and waits if today is not allowed") {
        let now = dateProvider.now()
        let utc = TimeZone(secondsFromGMT: 0)!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc

        let wd = cal.component(.weekday, from: now)  // 1 = Sunday ... 7 = Saturday
        let onlyNextDay = ((wd % 7) + 1)  // a day that's not today

        let (h, m) = hourMinute(now, tz: utc)
        // Choose a broad window around now, but disallow today via daysOfWeek
        let startTime = formatTime(hour: wrap24(h - 1), minute: m)
        let endTime = formatTime(hour: wrap24(h + 1), minute: m)

        let campaign = TestCampaignBuilder()
          .withId("tw-days-filter")
          .withFrequencyPolicy("every_rematch")
          .withNodes([
            AnyWorkflowNode(
              TimeWindowNode(
                id: "window",
                next: ["show"],
                data: TimeWindowNode.TimeWindowData(
                  startTime: startTime,
                  endTime: endTime,
                  timezone: "UTC",
                  daysOfWeek: [onlyNextDay]  // excludes today
                )
              )),
            AnyWorkflowNode(
              ShowFlowNode(
                id: "show",
                next: ["exit"],
                data: ShowFlowNode.ShowFlowData(flowId: "tw-dow-flow")
              )),
            AnyWorkflowNode(ExitNode(id: "exit", next: [], data: nil)),
          ])
          .withEntryNodeId("window")
          .build()

        profileService.profileResponse = TestProfileResponseBuilder()
          .addCampaign(campaign)
          .build()

        let journey = await journeyService.startJourney(for: campaign, distinctId: "user_tw_dow")
        expect(journey).toNot(beNil())
        expect(journey?.status).to(equal(.paused))
        expect(journey?.currentNodeId).to(equal("window"))
        spy.assertPath(["window"], for: journey!.id)
        spy.assertPersistenceCount(1, for: journey!.id)
      }

      // Pending until you adopt "start == end means always-open" semantics
      xit("treats start == end as always-open (no persistence)") {
        // Implement after engine change: startTime == endTime -> always open window
      }
    }
  }
}
