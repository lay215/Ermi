import Testing
@testable import Ermi

@MainActor struct MenuBarSpacingRefreshTests {
    @Test func failedSaveNeverRestartsApps() async {
        let model = MenuBarSpacingRefresh()
        var restarts = 0
        await model.apply(targets: [.init(id: "one", name: "One", restart: { restarts += 1; return nil })], save: { false })
        #expect(restarts == 0)
        #expect(model.message.contains("保存失败"))
        #expect(!model.busy)
    }

    @Test func partialFailureStillRefreshesRemainingApps() async {
        let model = MenuBarSpacingRefresh()
        var order: [String] = []
        await model.apply(targets: [
            .init(id: "one", name: "One", restart: { order.append("one"); return "拒绝退出" }),
            .init(id: "two", name: "Two", restart: { order.append("two"); return nil })
        ], save: { order.append("save"); return true })
        #expect(order == ["save", "one", "two"])
        #expect(model.message.contains("已刷新 1 项"))
        #expect(model.message.contains("One：拒绝退出"))
    }

    @Test func duplicateApplyDoesNotSaveOrRestartAgain() async {
        let model = MenuBarSpacingRefresh()
        var gate: CheckedContinuation<Void, Never>?
        let first = Task {
            await model.apply(targets: [.init(id: "one", name: "One", restart: {
                await withCheckedContinuation { gate = $0 }
                return nil
            })], save: { true })
        }
        while gate == nil { await Task.yield() }
        var duplicateSaves = 0
        await model.apply(targets: [], save: { duplicateSaves += 1; return true })
        #expect(model.busy)
        #expect(duplicateSaves == 0)
        gate?.resume()
        await first.value
        #expect(!model.busy)
    }
}
