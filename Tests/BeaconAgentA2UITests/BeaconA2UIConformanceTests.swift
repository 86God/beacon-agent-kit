import Testing
import BeaconAgentCore
@testable import BeaconAgentA2UI

struct BeaconA2UIConformanceTests {
    @Test
    func createUpdatePatchCompleteAndSnapshotRecoveryAreAtomic() throws {
        var store = BeaconA2UIStore()
        try store.create(validSurface(revision: 0))
        try store.update(
            surfaceID: "surface-1",
            component: BeaconA2UIComponent(
                id: "title",
                type: "Text",
                properties: ["text": .string("Tomorrow shoulder plan")]
            ),
            revision: 1
        )
        try store.patch(
            surfaceID: "surface-1",
            baseRevision: 1,
            revision: 2,
            operations: [
                .upsert(
                    BeaconA2UIComponent(
                        id: "metric",
                        type: "Metric",
                        properties: ["label": .string("Exercises"), "value": .string("5")]
                    )
                ),
                .setChildren(componentID: "root", children: ["title", "metric", "confirm"])
            ]
        )
        try store.complete(surfaceID: "surface-1", revision: 3)

        #expect(store.surface(id: "surface-1")?.revision == 3)
        #expect(store.surface(id: "surface-1")?.status == .complete)
        #expect(store.surface(id: "surface-1")?.components["metric"]?.type == "Metric")

        do {
            try store.patch(
                surfaceID: "surface-1",
                baseRevision: 3,
                revision: 5,
                operations: [.remove(componentID: "metric")]
            )
            Issue.record("Expected revision gap")
        } catch let error as BeaconA2UIStoreError {
            #expect(error == .revisionGap(expected: 4, received: 5))
        }
        #expect(store.surface(id: "surface-1")?.components["metric"] != nil)

        try store.applySnapshot(validSurface(revision: 5))
        #expect(store.surface(id: "surface-1")?.revision == 5)
        #expect(store.surface(id: "surface-1")?.status == .streaming)
    }

    @Test(arguments: InvalidFixture.allCases)
    func validatorRejectsUnsafeOrMalformedSurfaces(fixture: InvalidFixture) {
        let validator = BeaconA2UIValidator(maximumTextLength: 32)

        do {
            try validator.validate(fixture.surface)
            Issue.record("Expected validation failure")
        } catch let error as BeaconA2UIValidationError {
            #expect(error == fixture.expectedError)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func invalidPatchDoesNotPartiallyMutateSurface() throws {
        var store = BeaconA2UIStore()
        try store.create(validSurface(revision: 0))

        do {
            try store.patch(
                surfaceID: "surface-1",
                baseRevision: 0,
                revision: 1,
                operations: [
                    .upsert(BeaconA2UIComponent(id: "metric", type: "Metric")),
                    .setChildren(componentID: "root", children: ["title", "missing"])
                ]
            )
            Issue.record("Expected dangling-reference failure")
        } catch {
            #expect(error as? BeaconA2UIValidationError == .danglingReference("missing"))
        }

        #expect(store.surface(id: "surface-1")?.revision == 0)
        #expect(store.surface(id: "surface-1")?.components["metric"] == nil)
    }

    private func validSurface(revision: Int) -> BeaconA2UISurface {
        BeaconA2UISurface(
            id: "surface-1",
            revision: revision,
            rootComponentID: "root",
            components: [
                "root": BeaconA2UIComponent(
                    id: "root",
                    type: "Column",
                    children: ["title", "confirm"]
                ),
                "title": BeaconA2UIComponent(
                    id: "title",
                    type: "Text",
                    properties: ["text": .string("Draft")]
                ),
                "confirm": BeaconA2UIComponent(
                    id: "confirm",
                    type: "Button",
                    properties: ["label": .string("Confirm")],
                    actions: [
                        BeaconA2UIAction(id: "confirm", name: "approve", payload: [:])
                    ]
                )
            ],
            status: .streaming
        )
    }
}

enum InvalidFixture: CaseIterable, Sendable {
    case unknownComponent, cycle, danglingReference, identityInjection, oversizedText, invalidAction

    var surface: BeaconA2UISurface {
        var components: [String: BeaconA2UIComponent] = [
            "root": BeaconA2UIComponent(id: "root", type: "Column", children: ["child"]),
            "child": BeaconA2UIComponent(id: "child", type: "Text", properties: ["text": .string("ok")])
        ]
        switch self {
        case .unknownComponent:
            components["child"] = BeaconA2UIComponent(id: "child", type: "WebView")
        case .cycle:
            components["child"] = BeaconA2UIComponent(id: "child", type: "Row", children: ["root"])
        case .danglingReference:
            components["root"] = BeaconA2UIComponent(id: "root", type: "Column", children: ["missing"])
        case .identityInjection:
            components["child"] = BeaconA2UIComponent(
                id: "child",
                type: "Text",
                properties: ["accountId": .string("model-account")]
            )
        case .oversizedText:
            components["child"] = BeaconA2UIComponent(
                id: "child",
                type: "Text",
                properties: ["text": .string(String(repeating: "x", count: 33))]
            )
        case .invalidAction:
            components["child"] = BeaconA2UIComponent(
                id: "child",
                type: "Button",
                actions: [BeaconA2UIAction(id: "bad", name: "run_shell", payload: [:])]
            )
        }
        return BeaconA2UISurface(
            id: "surface-invalid",
            revision: 0,
            rootComponentID: "root",
            components: components,
            status: .streaming
        )
    }

    var expectedError: BeaconA2UIValidationError {
        switch self {
        case .unknownComponent: .unknownComponent("WebView")
        case .cycle: .cycle("root")
        case .danglingReference: .danglingReference("missing")
        case .identityInjection: .identityInjection("accountId")
        case .oversizedText: .oversizedText("child")
        case .invalidAction: .invalidAction("run_shell")
        }
    }
}
