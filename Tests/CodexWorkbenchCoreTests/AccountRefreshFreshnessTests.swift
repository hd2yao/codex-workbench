import CodexWorkbenchCore
import Foundation

func runAccountRefreshFreshnessTests(_ runner: inout TestRunner) {
    let firstSuccess = Date(timeIntervalSince1970: 2_000_000)
    var freshness = AccountRefreshFreshness()
    freshness.recordSuccess(at: firstSuccess)

    let message = freshness.failureMessage(
        error: "账号状态刷新失败。",
        hasCachedPayload: true,
        now: firstSuccess.addingTimeInterval(10 * 60)
    )
    runner.expect(
        freshness.lastSuccessfulAt == firstSuccess,
        "A failed refresh must not overwrite the last successful account timestamp"
    )
    runner.expect(
        message == "账号状态刷新失败。正在展示 10 分钟前成功读取的暂存数据。",
        "A production refresh failure should expose the age of retained account data"
    )
    runner.expect(
        freshness.failureMessage(
            error: "账号模块不可用。",
            hasCachedPayload: false,
            now: firstSuccess.addingTimeInterval(10 * 60)
        ) == "账号模块不可用。",
        "An initial failure without cached data must not invent a cache age"
    )

    let laterSuccess = firstSuccess.addingTimeInterval(20 * 60)
    freshness.recordSuccess(at: laterSuccess)
    runner.expect(
        freshness.lastSuccessfulAt == laterSuccess,
        "A later successful payload should advance the account timestamp"
    )
}
