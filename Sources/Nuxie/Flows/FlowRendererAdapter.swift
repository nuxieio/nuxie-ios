import Foundation

/// Adapter boundary between Flow runtime orchestration and renderer implementation.
///
/// v0 keeps the existing WebView-backed renderer as the default adapter so behavior
/// is unchanged while introducing a seam for future native renderers (for example rive).
protocol FlowRendererAdapter {
    var id: String { get }

    @MainActor
    func makeViewController(
        flow: Flow,
        archiveService: FlowArchiver,
        fontStore: FontStore
    ) -> FlowViewController
}

struct FlowRendererAdapterRegistry {
    private let adaptersByCompilerBackend: [String: any FlowRendererAdapter]
    private let defaultAdapter: any FlowRendererAdapter
    let defaultCompilerBackend: String

    init(
        adapters: [any FlowRendererAdapter],
        defaultCompilerBackend: String = "react"
    ) {
        var indexedAdapters: [String: any FlowRendererAdapter] = [:]
        for adapter in adapters {
            indexedAdapters[adapter.id.lowercased()] = adapter
        }
        precondition(
            !indexedAdapters.isEmpty,
            "FlowRendererAdapterRegistry requires at least one adapter."
        )

        let normalizedDefaultBackend = defaultCompilerBackend.lowercased()
        self.defaultAdapter =
            indexedAdapters[normalizedDefaultBackend] ??
            indexedAdapters.values.first!
        self.defaultCompilerBackend = normalizedDefaultBackend
        self.adaptersByCompilerBackend = indexedAdapters
    }

    func resolve(for compilerBackend: String?) -> any FlowRendererAdapter {
        guard
            let compilerBackend,
            let adapter = adaptersByCompilerBackend[compilerBackend.lowercased()]
        else {
            return defaultAdapter
        }
        return adapter
    }

    static func standard() -> FlowRendererAdapterRegistry {
        FlowRendererAdapterRegistry(
            adapters: [
                ReactFlowRendererAdapter(),
                RiveFlowRendererAdapter(),
            ],
            defaultCompilerBackend: "react"
        )
    }
}

struct ReactFlowRendererAdapter: FlowRendererAdapter {
    let id: String = "react"

    @MainActor
    func makeViewController(
        flow: Flow,
        archiveService: FlowArchiver,
        fontStore: FontStore
    ) -> FlowViewController {
        FlowViewController(
            flow: flow,
            archiveService: archiveService,
            fontStore: fontStore
        )
    }
}

struct RiveFlowRendererAdapter: FlowRendererAdapter {
    let id: String = "rive"
    private let reactFallback = ReactFlowRendererAdapter()

    @MainActor
    func makeViewController(
        flow: Flow,
        archiveService: FlowArchiver,
        fontStore: FontStore
    ) -> FlowViewController {
        // Placeholder behavior until native rive rendering is implemented:
        // route through the known-good React path using the legacy bundle.
        LogWarning(
            "RiveFlowRendererAdapter is a placeholder; falling back to React renderer"
        )
        return reactFallback.makeViewController(
            flow: fallbackReactFlow(for: flow),
            archiveService: archiveService,
            fontStore: fontStore
        )
    }

    private func fallbackReactFlow(for flow: Flow) -> Flow {
        let source = flow.remoteFlow
        let fallbackRemoteFlow = RemoteFlow(
            id: source.id,
            bundle: source.bundle,
            targets: nil,
            screens: source.screens,
            interactions: source.interactions,
            viewModels: source.viewModels,
            viewModelInstances: source.viewModelInstances,
            converters: source.converters
        )
        return Flow(remoteFlow: fallbackRemoteFlow, products: flow.products)
    }
}
