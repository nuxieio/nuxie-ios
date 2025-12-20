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
            var mockSDK: MockNuxieSDKForPlugin!
            var userDefaults: UserDefaults!
            var testSuiteName: String!

            beforeEach {
                // Create isolated UserDefaults for testing
                testSuiteName = "com.nuxie.test.lifecycle.\(UUID().uuidString)"
                userDefaults = UserDefaults(suiteName: testSuiteName)!

                // Clear any existing keys
                userDefaults.removeObject(forKey: "nuxie_has_launched_before")
                userDefaults.removeObject(forKey: "nuxie_last_version")

                plugin = AppLifecyclePlugin()
                mockSDK = MockNuxieSDKForPlugin()
            }

            afterEach {
                plugin.stop()
                plugin.uninstall()
                plugin = nil
                mockSDK = nil

                // Clean up UserDefaults
                if let suiteName = testSuiteName {
                    UserDefaults.standard.removePersistentDomain(forName: suiteName)
                }
            }

            describe("plugin lifecycle") {
                it("should have correct plugin ID") {
                    expect(plugin.pluginId).to(equal("app-lifecycle"))
                }

                it("should handle install/uninstall cycle") {
                    plugin.install(sdk: NuxieSDK.shared)
                    plugin.uninstall()

                    // Should not crash and should be in clean state
                }

                it("should handle start/stop cycle") {
                    plugin.install(sdk: NuxieSDK.shared)
                    plugin.start()
                    plugin.stop()
                    plugin.uninstall()

                    // Should not crash
                }

                it("should not start if not installed") {
                    // Starting without install should be safe (no-op)
                    plugin.start()

                    // Lifecycle events should not track anything
                    plugin.onAppDidEnterBackground()

                    // No crash expected
                }

                it("should ignore lifecycle events when stopped") {
                    plugin.install(sdk: NuxieSDK.shared)
                    plugin.start()
                    plugin.stop()

                    // Lifecycle events should be ignored when stopped
                    plugin.onAppDidEnterBackground()
                    plugin.onAppWillEnterForeground()

                    // No crash expected
                }
            }

            describe("$app_backgrounded event") {
                var config: NuxieConfiguration!
                var dbPath: String!
                var mockApi: MockNuxieApi!

                beforeEach {
                    mockApi = MockNuxieApi()
                    Container.shared.nuxieApi.register { mockApi }

                    await NuxieSDK.shared.shutdown()

                    let testId = UUID().uuidString
                    let tempDir = NSTemporaryDirectory()
                    let testDirPath = "\(tempDir)test_lifecycle_\(testId)"
                    try FileManager.default.createDirectory(atPath: testDirPath, withIntermediateDirectories: true)
                    dbPath = testDirPath

                    config = NuxieConfiguration(apiKey: "test-key-\(testId)")
                    config.customStoragePath = URL(fileURLWithPath: dbPath)
                    config.environment = .development
                    config.enablePlugins = false // We'll manually manage the plugin

                    try NuxieSDK.shared.setup(with: config)
                }

                afterEach {
                    await NuxieSDK.shared.shutdown()
                    if let dbPath = dbPath {
                        try? FileManager.default.removeItem(atPath: dbPath)
                    }
                    Container.shared.reset()
                }

                it("should track $app_backgrounded event when app enters background") {
                    let eventService = Container.shared.eventService()

                    // Install and start plugin
                    let lifecyclePlugin = AppLifecyclePlugin()
                    lifecyclePlugin.install(sdk: NuxieSDK.shared)
                    lifecyclePlugin.start()

                    // Give time for launch events to be processed
                    try await Task.sleep(nanoseconds: 200_000_000)

                    // Simulate background event
                    lifecyclePlugin.onAppDidEnterBackground()

                    // Verify $app_backgrounded event was tracked
                    await expect {
                        let events = await eventService.getRecentEvents(limit: 20)
                        return events.contains { $0.name == "$app_backgrounded" }
                    }.toEventually(beTrue(), timeout: .seconds(2))

                    lifecyclePlugin.stop()
                    lifecyclePlugin.uninstall()
                }

                it("should include source and background_date in $app_backgrounded event") {
                    let eventService = Container.shared.eventService()

                    let lifecyclePlugin = AppLifecyclePlugin()
                    lifecyclePlugin.install(sdk: NuxieSDK.shared)
                    lifecyclePlugin.start()

                    try await Task.sleep(nanoseconds: 200_000_000)

                    lifecyclePlugin.onAppDidEnterBackground()

                    await expect {
                        let events = await eventService.getRecentEvents(limit: 20)
                        return events.first { $0.name == "$app_backgrounded" }
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
                var config: NuxieConfiguration!
                var dbPath: String!
                var mockApi: MockNuxieApi!

                beforeEach {
                    mockApi = MockNuxieApi()
                    Container.shared.nuxieApi.register { mockApi }

                    await NuxieSDK.shared.shutdown()

                    let testId = UUID().uuidString
                    let tempDir = NSTemporaryDirectory()
                    let testDirPath = "\(tempDir)test_opened_\(testId)"
                    try FileManager.default.createDirectory(atPath: testDirPath, withIntermediateDirectories: true)
                    dbPath = testDirPath

                    config = NuxieConfiguration(apiKey: "test-key-\(testId)")
                    config.customStoragePath = URL(fileURLWithPath: dbPath)
                    config.environment = .development
                    config.enablePlugins = false

                    try NuxieSDK.shared.setup(with: config)
                }

                afterEach {
                    await NuxieSDK.shared.shutdown()
                    if let dbPath = dbPath {
                        try? FileManager.default.removeItem(atPath: dbPath)
                    }
                    Container.shared.reset()
                }

                it("should track $app_opened event on start") {
                    let eventService = Container.shared.eventService()

                    let lifecyclePlugin = AppLifecyclePlugin()
                    lifecyclePlugin.install(sdk: NuxieSDK.shared)
                    lifecyclePlugin.start()

                    // $app_opened should be tracked on start
                    await expect {
                        let events = await eventService.getRecentEvents(limit: 20)
                        return events.contains { $0.name == "$app_opened" }
                    }.toEventually(beTrue(), timeout: .seconds(2))

                    lifecyclePlugin.stop()
                    lifecyclePlugin.uninstall()
                }

                it("should track $app_opened event when returning from background") {
                    let eventService = Container.shared.eventService()

                    let lifecyclePlugin = AppLifecyclePlugin()
                    lifecyclePlugin.install(sdk: NuxieSDK.shared)
                    lifecyclePlugin.start()

                    try await Task.sleep(nanoseconds: 200_000_000)

                    // Get initial count
                    let initialEvents = await eventService.getRecentEvents(limit: 50)
                    let initialOpenedCount = initialEvents.filter { $0.name == "$app_opened" }.count

                    // Simulate background -> foreground
                    lifecyclePlugin.onAppDidEnterBackground()
                    try await Task.sleep(nanoseconds: 100_000_000)
                    lifecyclePlugin.onAppWillEnterForeground()

                    // Should have additional $app_opened event
                    await expect {
                        let events = await eventService.getRecentEvents(limit: 50)
                        let openedCount = events.filter { $0.name == "$app_opened" }.count
                        return openedCount
                    }.toEventually(beGreaterThan(initialOpenedCount), timeout: .seconds(2))

                    lifecyclePlugin.stop()
                    lifecyclePlugin.uninstall()
                }
            }

            describe("multiple background/foreground cycles") {
                var config: NuxieConfiguration!
                var dbPath: String!
                var mockApi: MockNuxieApi!

                beforeEach {
                    mockApi = MockNuxieApi()
                    Container.shared.nuxieApi.register { mockApi }

                    await NuxieSDK.shared.shutdown()

                    let testId = UUID().uuidString
                    let tempDir = NSTemporaryDirectory()
                    let testDirPath = "\(tempDir)test_cycles_\(testId)"
                    try FileManager.default.createDirectory(atPath: testDirPath, withIntermediateDirectories: true)
                    dbPath = testDirPath

                    config = NuxieConfiguration(apiKey: "test-key-\(testId)")
                    config.customStoragePath = URL(fileURLWithPath: dbPath)
                    config.environment = .development
                    config.enablePlugins = false

                    try NuxieSDK.shared.setup(with: config)
                }

                afterEach {
                    await NuxieSDK.shared.shutdown()
                    if let dbPath = dbPath {
                        try? FileManager.default.removeItem(atPath: dbPath)
                    }
                    Container.shared.reset()
                }

                it("should track events for each background/foreground cycle") {
                    let eventService = Container.shared.eventService()

                    let lifecyclePlugin = AppLifecyclePlugin()
                    lifecyclePlugin.install(sdk: NuxieSDK.shared)
                    lifecyclePlugin.start()

                    try await Task.sleep(nanoseconds: 200_000_000)

                    // Perform 3 background/foreground cycles
                    for _ in 0..<3 {
                        lifecyclePlugin.onAppDidEnterBackground()
                        try await Task.sleep(nanoseconds: 50_000_000)
                        lifecyclePlugin.onAppWillEnterForeground()
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }

                    // Should have 3 $app_backgrounded events
                    await expect {
                        let events = await eventService.getRecentEvents(limit: 50)
                        return events.filter { $0.name == "$app_backgrounded" }.count
                    }.toEventually(equal(3), timeout: .seconds(3))

                    // Should have 4 $app_opened events (1 initial + 3 from foreground)
                    await expect {
                        let events = await eventService.getRecentEvents(limit: 50)
                        return events.filter { $0.name == "$app_opened" }.count
                    }.toEventually(equal(4), timeout: .seconds(3))

                    lifecyclePlugin.stop()
                    lifecyclePlugin.uninstall()
                }
            }
        }
    }
}

// MARK: - Mock SDK for Plugin Testing

/// Simple mock for testing plugin installation without full SDK setup
class MockNuxieSDKForPlugin {
    var trackedEvents: [(name: String, properties: [String: Any]?)] = []

    func track(_ name: String, properties: [String: Any]? = nil) {
        trackedEvents.append((name: name, properties: properties))
    }

    func reset() {
        trackedEvents.removeAll()
    }
}
