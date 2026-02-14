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
