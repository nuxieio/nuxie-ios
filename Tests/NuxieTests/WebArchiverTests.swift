import Foundation
import Quick
import Nimble
@testable import Nuxie

final class WebArchiverTests: AsyncSpec {
    override class func spec() {
        describe("WebArchiver") {
            var webArchiver: WebArchiver!
            var session: URLSession!
            
            beforeEach {
                // Reset protocol handlers
                
                // Create test session
                session = TestURLSessionProvider.createTestSession()
                
                // Initialize WebArchiver with test session
                webArchiver = WebArchiver(urlSession: session)
            }
            
            afterEach {
                webArchiver = nil
                session = nil
            }
            
            describe("downloadAndBuildArchive") {
                it("should successfully download and build archive with single file") {
                    let manifest = BuildManifest(
                        totalFiles: 1,
                        totalSize: 100,
                        contentHash: "test-hash",
                        files: [
                            BuildFile(path: "index.html", size: 100, contentType: "text/html")
                        ]
                    )
                    let baseURL = URL(string: "https://example.com")!
                    
                    // Setup stub response
                    let mockData = "<html><body>Test</body></html>".data(using: .utf8)!
                    StubURLProtocol.registerSuccess(
                        path: "/index.html",
                        data: mockData,
                        headers: ["Content-Type": "text/html"]
                    )
                    
                    let result = try await webArchiver.downloadAndBuildArchive(
                        manifest: manifest,
                        baseURL: baseURL
                    )
                    
                    expect(result).toNot(beNil())
                    expect(result.count).to(beGreaterThan(0))
                }
                
                it("should successfully download and build archive with multiple files") {
                    let manifest = BuildManifest(
                        totalFiles: 3,
                        totalSize: 300,
                        contentHash: "test-hash",
                        files: [
                            BuildFile(path: "index.html", size: 100, contentType: "text/html"),
                            BuildFile(path: "style.css", size: 100, contentType: "text/css"),
                            BuildFile(path: "script.js", size: 100, contentType: "text/javascript")
                        ]
                    )
                    let baseURL = URL(string: "https://example.com")!
                    
                    // Setup stub responses
                    StubURLProtocol.registerSuccess(
                        path: "/index.html",
                        data: "<html><body>Test</body></html>".data(using: .utf8)!,
                        headers: ["Content-Type": "text/html"]
                    )
                    StubURLProtocol.registerSuccess(
                        path: "/style.css",
                        data: "body { color: red; }".data(using: .utf8)!,
                        headers: ["Content-Type": "text/css"]
                    )
                    StubURLProtocol.registerSuccess(
                        path: "/script.js",
                        data: "console.log('test');".data(using: .utf8)!,
                        headers: ["Content-Type": "text/javascript"]
                    )
                    
                    let result = try await webArchiver.downloadAndBuildArchive(
                        manifest: manifest,
                        baseURL: baseURL
                    )
                    
                    expect(result).toNot(beNil())
                    expect(result.count).to(beGreaterThan(0))
                }
                
                it("should handle download failure") {
                    let manifest = BuildManifest(
                        totalFiles: 1,
                        totalSize: 100,
                        contentHash: "test-hash",
                        files: [
                            BuildFile(path: "index.html", size: 100, contentType: "text/html")
                        ]
                    )
                    let baseURL = URL(string: "https://example.com")!
                    
                    // Setup stub to fail
                    StubURLProtocol.registerError(
                        path: "/index.html",
                        error: URLError(.notConnectedToInternet)
                    )
                    
                    await expect {
                        try await webArchiver.downloadAndBuildArchive(
                            manifest: manifest,
                            baseURL: baseURL
                        )
                    }.to(throwError())
                }
                
                it("should handle missing files in manifest") {
                    let manifest = BuildManifest(
                        totalFiles: 2,
                        totalSize: 200,
                        contentHash: "test-hash",
                        files: [
                            BuildFile(path: "index.html", size: 100, contentType: "text/html"),
                            BuildFile(path: "missing.js", size: 100, contentType: "text/javascript")
                        ]
                    )
                    let baseURL = URL(string: "https://example.com")!
                    
                    // Setup stub responses - only one file available
                    StubURLProtocol.registerSuccess(
                        path: "/index.html",
                        data: "<html><body>Test</body></html>".data(using: .utf8)!,
                        headers: ["Content-Type": "text/html"]
                    )
                    StubURLProtocol.registerError(
                        path: "/missing.js",
                        error: URLError(.fileDoesNotExist)
                    )
                    
                    await expect {
                        try await webArchiver.downloadAndBuildArchive(
                            manifest: manifest,
                            baseURL: baseURL
                        )
                    }.to(throwError())
                }
                
                it("should download files in parallel") {
                    let manifest = BuildManifest(
                        totalFiles: 5,
                        totalSize: 500,
                        contentHash: "test-hash",
                        files: (1...5).map { i in
                            BuildFile(path: "file\(i).txt", size: 100, contentType: "text/plain")
                        }
                    )
                    let baseURL = URL(string: "https://example.com")!
                    
                    // Track download order
                    var downloadOrder: [String] = []
                    let queue = DispatchQueue(label: "test.queue")
                    
                    // Setup stub responses with delay
                    for i in 1...5 {
                        StubURLProtocol.register(
                            matcher: { request in
                                request.url?.path == "/file\(i).txt"
                            },
                            handler: { request in
                                queue.sync {
                                    downloadOrder.append("file\(i).txt")
                                }
                                // Simulate network delay
                                Thread.sleep(forTimeInterval: 0.01)
                                let response = HTTPURLResponse(
                                    url: request.url!,
                                    statusCode: 200,
                                    httpVersion: nil,
                                    headerFields: ["Content-Type": "text/plain"]
                                )!
                                let data = "content\(i)".data(using: .utf8)!
                                return (response, data)
                            }
                        )
                    }
                    
                    let result = try await webArchiver.downloadAndBuildArchive(
                        manifest: manifest,
                        baseURL: baseURL
                    )
                    
                    expect(result).toNot(beNil())
                    expect(result.count).to(beGreaterThan(0))
                    
                    // Verify all files were downloaded (order may vary due to parallel execution)
                    expect(downloadOrder.count).to(equal(5))
                    expect(Set(downloadOrder)).to(equal(Set(["file1.txt", "file2.txt", "file3.txt", "file4.txt", "file5.txt"])))
                }
                
                it("should handle empty manifest") {
                    let manifest = BuildManifest(
                        totalFiles: 0,
                        totalSize: 0,
                        contentHash: "empty",
                        files: []
                    )
                    let baseURL = URL(string: "https://example.com")!
                    
                    await expect {
                        try await webArchiver.downloadAndBuildArchive(
                            manifest: manifest,
                            baseURL: baseURL
                        )
                    }.to(throwError())
                }
            }
        }
    }
}