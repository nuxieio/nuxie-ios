import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie

/// Comprehensive tests for AppLifecyclePlugin
/// Tests app lifecycle event tracking: $app_installed, $app_updated, $app_opened, $app_backgrounded
final class AppLifecyclePluginTests: AsyncSpec {
    override class func spec() {
        describe("AppLifecyclePlugin") {
            var plugin: AppLifecyclePlugin!
            var userDefaults: UserDefaults!
            var testSuiteName: String!
            let appVersion = "1.2.3 (4)"

            beforeEach {
                testSuiteName = "com.nuxie.test.lifecycle.\(UUID().uuidString)"
                userDefaults = UserDefaults(suiteName: testSuiteName)
                userDefaults?.removeObject(forKey: "nuxie_has_launched_before")
                userDefaults?.removeObject(forKey: "nuxie_last_version")

                plugin = AppLifecyclePlugin(
                    userDefaults: userDefaults ?? .standard,
                    appVersionProvider: { appVersion }
                )
            }

            afterEach {
                plugin.stop()
                plugin.uninstall()
                plugin = nil
                if let testSuiteName = testSuiteName {
                    UserDefaults.standard.removePersistentDomain(forName: testSuiteName)
                }
                userDefaults = nil
                testSuiteName = nil
            }

            describe("plugin lifecycle") {
                it("should have correct plugin ID") {
                    expect(plugin.pluginId).to(equal("app-lifecycle"))
                }

                it("should not start if not installed") {
                    // Starting without install should be safe (no-op)
                    // sdk is nil so track calls are no-ops
                    plugin.start()

                    // Lifecycle events should not track anything (sdk is nil)
                    plugin.onAppDidEnterBackground()

                    expect(userDefaults?.bool(forKey: "nuxie_has_launched_before")).to(beTrue())
                    expect(userDefaults?.string(forKey: "nuxie_last_version")).to(equal(appVersion))
                }
            }

            describe("plugin lifecycle with SDK") {
                var harness: SDKTestHarness!

                beforeEach {
                    harness = try SDKTestHarness.make(prefix: "test_plugin_lifecycle", enablePlugins: false)
                    try harness.setupSDK()
                }

                afterEach {
                    harness?.cleanup()
                    harness = nil
                }

                it("should handle install/uninstall cycle") {
                    let eventService = Container.shared.eventService()
                    let lifecyclePlugin = AppLifecyclePlugin(
                        userDefaults: userDefaults ?? .standard,
                        appVersionProvider: { appVersion }
                    )
                    lifecyclePlugin.install(sdk: NuxieSDK.shared)
                    lifecyclePlugin.uninstall()

                    await eventService.drain()
                    let events = await eventService.getRecentEvents(limit: 10)
                    expect(events).to(beEmpty())
                }

                it("should handle start/stop cycle") {
                    let eventService = Container.shared.eventService()
                    let lifecyclePlugin = AppLifecyclePlugin(
                        userDefaults: userDefaults ?? .standard,
                        appVersionProvider: { appVersion }
                    )
                    lifecyclePlugin.install(sdk: NuxieSDK.shared)
                    lifecyclePlugin.start()
                    lifecyclePlugin.stop()
                    lifecyclePlugin.uninstall()

                    await eventService.drain()
                    await expect {
                        await eventService.getRecentEvents(limit: 20).count
                    }.toEventually(beGreaterThan(0), timeout: .seconds(2))
                }

                it("should ignore lifecycle events when stopped") {
                    let eventService = Container.shared.eventService()
                    let lifecyclePlugin = AppLifecyclePlugin(
                        userDefaults: userDefaults ?? .standard,
                        appVersionProvider: { appVersion }
                    )
                    lifecyclePlugin.install(sdk: NuxieSDK.shared)
                    lifecyclePlugin.start()

                    // Give time for launch events to be processed
                    await eventService.drain()

                    lifecyclePlugin.stop()

                    let baselineEvents = await eventService.getRecentEvents(limit: 50)
                    let backgroundedCount = baselineEvents.filter { $0.name == "$app_backgrounded" }.count
                    let openedCount = baselineEvents.filter { $0.name == "$app_opened" }.count

                    // Lifecycle events should be ignored when stopped
                    lifecyclePlugin.onAppDidEnterBackground()
                    lifecyclePlugin.onAppWillEnterForeground()

                    await eventService.drain()

                    let events = await eventService.getRecentEvents(limit: 50)
                    expect(events.filter { $0.name == "$app_backgrounded" }.count).to(equal(backgroundedCount))
                    expect(events.filter { $0.name == "$app_opened" }.count).to(equal(openedCount))

                    lifecyclePlugin.uninstall()
                }
            }

            describe("$app_backgrounded event") {
                var harness: SDKTestHarness!

                beforeEach {
                    harness = try SDKTestHarness.make(prefix: "test_lifecycle", enablePlugins: false)
                    try harness.setupSDK()
                }

                afterEach {
                    harness?.cleanup()
                    harness = nil
                }

                it("should track $app_backgrounded event when app enters background") {
                    let eventService = Container.shared.eventService()

                    // Install and start plugin
                    let lifecyclePlugin = AppLifecyclePlugin(
                        userDefaults: userDefaults ?? .standard,
                        appVersionProvider: { appVersion }
                    )
                    lifecyclePlugin.install(sdk: NuxieSDK.shared)
                    lifecyclePlugin.start()

                    await eventService.drain()

                    // Simulate background event
                    lifecyclePlugin.onAppDidEnterBackground()
                    await eventService.drain()

                    // Verify $app_backgrounded event was tracked
                    await expect {
                        await eventService.getRecentEvents(limit: 20)
                            .contains { $0.name == "$app_backgrounded" }
                    }.toEventually(beTrue(), timeout: .seconds(2))

                    lifecyclePlugin.stop()
                    lifecyclePlugin.uninstall()
                }

                it("should include source and background_date in $app_backgrounded event") {
                    let eventService = Container.shared.eventService()

                    let lifecyclePlugin = AppLifecyclePlugin(
                        userDefaults: userDefaults ?? .standard,
                        appVersionProvider: { appVersion }
                    )
                    lifecyclePlugin.install(sdk: NuxieSDK.shared)
                    lifecyclePlugin.start()

                    await eventService.drain()

                    lifecyclePlugin.onAppDidEnterBackground()
                    await eventService.drain()

                    await expect {
                        await eventService.getRecentEvents(limit: 20)
                            .first { $0.name == "$app_backgrounded" }
                    }.toEventuallyNot(beNil(), timeout: .seconds(2))

                    let events = await eventService.getRecentEvents(limit: 20)
                    let backgroundEvent = events.first { $0.name == "$app_backgrounded" }

                    expect(backgroundEvent).toNot(beNil())
                    if let event = backgroundEvent, let props = try? event.getProperties() {
                        // Check source property
                        if let source = props["source"] as? AnyCodable {
                            expect(source.value as? String).to(equal("app_lifecycle_plugin"))
                        } else if let source = props["source"] as? String {
                            expect(source).to(equal("app_lifecycle_plugin"))
                        }

                        // Check background_date property exists
                        let hasBackgroundDate = props["background_date"] != nil
                        expect(hasBackgroundDate).to(beTrue())
                    }

                    lifecyclePlugin.stop()
                    lifecyclePlugin.uninstall()
                }
            }

            describe("$app_opened event") {
                var harness: SDKTestHarness!

                beforeEach {
                    harness = try SDKTestHarness.make(prefix: "test_opened", enablePlugins: false)
                    try harness.setupSDK()
                }

                afterEach {
                    harness?.cleanup()
                    harness = nil
                }

                it("should track $app_opened event on start") {
                    let eventService = Container.shared.eventService()

                    let lifecyclePlugin = AppLifecyclePlugin(
                        userDefaults: userDefaults ?? .standard,
                        appVersionProvider: { appVersion }
                    )
                    lifecyclePlugin.install(sdk: NuxieSDK.shared)
                    lifecyclePlugin.start()

                    // $app_opened should be tracked on start
                    await eventService.drain()
                    await expect {
                        await eventService.getRecentEvents(limit: 20)
                            .contains { $0.name == "$app_opened" }
                    }.toEventually(beTrue(), timeout: .seconds(2))

                    lifecyclePlugin.stop()
                    lifecyclePlugin.uninstall()
                }

                it("should track $app_opened event when returning from background") {
                    let eventService = Container.shared.eventService()

                    let lifecyclePlugin = AppLifecyclePlugin(
                        userDefaults: userDefaults ?? .standard,
                        appVersionProvider: { appVersion }
                    )
                    lifecyclePlugin.install(sdk: NuxieSDK.shared)
                    lifecyclePlugin.start()

                    await eventService.drain()

                    // Get initial count
                    await expect {
                        await eventService.getRecentEvents(limit: 50)
                            .filter { $0.name == "$app_opened" }
                            .count
                    }.toEventually(beGreaterThan(0), timeout: .seconds(2))
                    let initialEvents = await eventService.getRecentEvents(limit: 50)
                    let initialOpenedCount = initialEvents.filter { $0.name == "$app_opened" }.count

                    // Simulate background -> foreground
                    lifecyclePlugin.onAppDidEnterBackground()
                    lifecyclePlugin.onAppWillEnterForeground()
                    await eventService.drain()

                    // Should have additional $app_opened event
                    await expect {
                        await eventService.getRecentEvents(limit: 50)
                            .filter { $0.name == "$app_opened" }
                            .count
                    }.toEventually(beGreaterThan(initialOpenedCount), timeout: .seconds(2))

                    lifecyclePlugin.stop()
                    lifecyclePlugin.uninstall()
                }
            }

            describe("multiple background/foreground cycles") {
                var harness: SDKTestHarness!

                beforeEach {
                    harness = try SDKTestHarness.make(prefix: "test_cycles", enablePlugins: false)
                    try harness.setupSDK()
                }

                afterEach {
                    harness?.cleanup()
                    harness = nil
                }

                it("should track events for each background/foreground cycle") {
                    let eventService = Container.shared.eventService()

                    let lifecyclePlugin = AppLifecyclePlugin(
                        userDefaults: userDefaults ?? .standard,
                        appVersionProvider: { appVersion }
                    )
                    lifecyclePlugin.install(sdk: NuxieSDK.shared)
                    lifecyclePlugin.start()

                    await eventService.drain()

                    // Perform 3 background/foreground cycles
                    for _ in 0..<3 {
                        lifecyclePlugin.onAppDidEnterBackground()
                        lifecyclePlugin.onAppWillEnterForeground()
                    }
                    await eventService.drain()

                    // Should have 3 $app_backgrounded events
                    await expect {
                        await eventService.getRecentEvents(limit: 50)
                            .filter { $0.name == "$app_backgrounded" }
                            .count
                    }.toEventually(equal(3), timeout: .seconds(2))

                    // Should have 4 $app_opened events (1 initial + 3 from foreground)
                    await expect {
                        await eventService.getRecentEvents(limit: 50)
                            .filter { $0.name == "$app_opened" }
                            .count
                    }.toEventually(equal(4), timeout: .seconds(2))

                    lifecyclePlugin.stop()
                    lifecyclePlugin.uninstall()
                }
            }
        }
    }
}
