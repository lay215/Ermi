import Testing
@testable import ErmiCore

struct MenuBarVisibilityPlanTests {
    @Test func hidesOnlyExplicitlySelectedReadableRunningApps() {
        let plan = MenuBarVisibilityPlan(selected: ["cloud", "quit", "unreadable"], discovered: ["cloud", "quit", "music"], running: ["cloud", "music", "unreadable", "new-app"], own: "ermi")
        #expect(plan.hidden == ["cloud"])
        #expect(plan.allowed.isSuperset(of: ["music", "unreadable", "new-app", "ermi"]))
        #expect(!plan.allowed.contains("cloud"))
    }

    @Test func protectsRecoveryEntryAndSystemControlsAgainstModifiedPreferences() {
        let all = MenuBarVisibilityPlan.systemOwners.union(["ermi", "cloud"])
        let plan = MenuBarVisibilityPlan(selected: all, discovered: all, running: all, own: "ermi")
        #expect(plan.hidden == ["cloud"])
        #expect(plan.allowed == all.subtracting(["cloud"]))
    }

    @Test func missingInventoryNeverHidesPersistedChoices() {
        let plan = MenuBarVisibilityPlan(selected: ["cloud"], discovered: [], running: ["cloud", "new-app"], own: "ermi")
        #expect(plan.hidden.isEmpty)
        #expect(plan.allowed.isSuperset(of: ["cloud", "new-app", "ermi"]))
    }
}
