import Testing
@testable import BeaconAgentSwiftUI

struct BeaconSurfaceRendererCatalogTests {
    @Test
    func genericCatalogSupportsEverySafeComponent() {
        let catalog = BeaconSurfaceRendererCatalog.generic
        let supported = [
            "Text", "Row", "Column", "Card", "Button", "Metric", "List", "Table",
            "Notice", "Error", "Retry", "Approval", "Receipt"
        ]

        #expect(supported.allSatisfy(catalog.supports))
        #expect(!catalog.supports("WebView"))
        #expect(!catalog.actionsEnabled(for: "WebView"))
        #expect(catalog.actionsEnabled(for: "Button"))
    }
}
