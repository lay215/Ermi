import Foundation
import Testing
@testable import Ermi

@MainActor struct MenuBarSpacingTests {
    // 独立偏好域验证真实 CFPreferences 读写，不改变测试机器的菜单栏设置。
    private func store() -> MenuBarSpacingStore {
        MenuBarSpacingStore(domain: "app.ermi.tests.spacing.\(UUID().uuidString)" as CFString)
    }

    @Test func draftDoesNotWriteUntilSave() {
        let store = store()
        defer { _ = store.reset() }
        let model = MenuBarSpacing(store: store)
        model.spacing = 12
        model.padding = 8
        #expect(store.read(MenuBarSpacingStore.spacingKey) == nil)
        model.save()
        let reopened = MenuBarSpacing(store: store)
        #expect(reopened.savedSpacing == 12)
        #expect(reopened.savedPadding == 8)
        #expect(model.message.contains("重新登录"))
    }

    @Test func resetClearsBothScopesAndPreservesUnrelatedPreferences() {
        let store = store()
        let unrelated = "UnrelatedTestKey" as CFString
        defer {
            _ = store.reset()
            CFPreferencesSetValue(unrelated, nil, store.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(store.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        CFPreferencesSetValue(MenuBarSpacingStore.spacingKey as CFString, 22 as CFNumber, store.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSetValue(unrelated, 99 as CFNumber, store.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(store.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        #expect(store.read(MenuBarSpacingStore.spacingKey) == 22)
        #expect(store.save(spacing: 6, padding: 6))
        #expect(store.read(MenuBarSpacingStore.spacingKey) == 6)
        #expect(store.reset())
        #expect(store.read(MenuBarSpacingStore.spacingKey) == nil)
        #expect(store.read(MenuBarSpacingStore.paddingKey) == nil)
        #expect(store.read("UnrelatedTestKey") == 99)
    }

    @Test func invalidSavePreservesExistingValues() {
        let store = store()
        defer { _ = store.reset() }
        #expect(store.save(spacing: 0, padding: 20))
        #expect(!store.save(spacing: 31, padding: 10))
        #expect(!store.save(spacing: 12, padding: -1))
        #expect(store.read(MenuBarSpacingStore.spacingKey) == 0)
        #expect(store.read(MenuBarSpacingStore.paddingKey) == 20)
    }
}
