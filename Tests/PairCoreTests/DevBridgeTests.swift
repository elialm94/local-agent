import XCTest
@testable import PairCore

final class DevBridgeTests: XCTestCase {
    func testRoundTripThroughClassList() throws {
        let cls = DevBridgeSourceResolver.encode(file: "src/features/offers/SendOfferButton.tsx", line: 84, component: "SendOfferButton")
        XCTAssertTrue(cls.hasPrefix("pair-src--"))
        XCTAssertFalse(cls.contains("="), "class names must not contain padding")
        let ref = DevBridgeSourceResolver.decode(classList: ["btn", cls, "primary"])
        XCTAssertEqual(ref?.file, "src/features/offers/SendOfferButton.tsx")
        XCTAssertEqual(ref?.line, 84)
        XCTAssertEqual(ref?.component, "SendOfferButton")
        XCTAssertEqual(ref?.confidence ?? 0, 0.97, accuracy: 0.001)
    }

    func testMatchesBrowserRuntimeEncoding() {
        // Produced by devtools/vite-plugin-ai-pair/src/runtime.js for "src/App.tsx:12:App".
        let fromBrowser = "pair-src--c3JjL0FwcC50c3g6MTI6QXBw"
        let ref = DevBridgeSourceResolver.decode(classList: [fromBrowser])
        XCTAssertEqual(ref?.file, "src/App.tsx")
        XCTAssertEqual(ref?.line, 12)
        XCTAssertEqual(ref?.component, "App")
    }

    func testComponentOnlyIsLowerConfidenceAndIgnoresGarbage() {
        let cls = DevBridgeSourceResolver.encode(file: "src/App.tsx", line: nil, component: "App")
        let ref = DevBridgeSourceResolver.decode(classList: [cls])
        XCTAssertNil(ref?.line)
        XCTAssertLessThan(ref?.confidence ?? 1, 0.95)
        XCTAssertNil(DevBridgeSourceResolver.decode(classList: ["pair-src--!!!not-base64"]))
        XCTAssertNil(DevBridgeSourceResolver.decode(classList: ["btn"]))
    }

    func testResolverPrefersBridgeOverGrep() async throws {
        let cls = DevBridgeSourceResolver.encode(file: "src/X.tsx", line: 3, component: "X")
        var t = AttentionTarget(role: "AXButton", label: "Go", bounds: .zero, application: "Chrome", confidence: 0.9, source: .explicitClick)
        t.accessibility.domClassList = [cls]
        let project = ProjectContext(name: "p", rootPath: "/nonexistent", confidence: 1, signals: [.explicitSelection])
        let composite = CompositeSourceResolver([DevBridgeSourceResolver(), GrepSourceResolver()])
        let ref = await composite.resolve(target: t, project: project)
        XCTAssertEqual(ref?.method, "dev-bridge class")
        XCTAssertEqual(ref?.file, "src/X.tsx")
    }
}
