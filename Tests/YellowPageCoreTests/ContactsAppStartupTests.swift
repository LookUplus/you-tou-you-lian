import Foundation
import Testing
@testable import YellowPageCore

@Suite struct ContactsAppStartupTests {
    @Test func alreadyRunningAppIsNotRelaunched() throws {
        var launches = 0
        try ContactsAppStartup.prepare(isReady: { true }, launch: { launches += 1 }, pause: {})
        #expect(launches == 0)
    }
    @Test func coldStartWaitsForAppToFinishLaunching() throws {
        var polls = 0; var launches = 0
        try ContactsAppStartup.prepare(isReady: { polls >= 3 }, launch: { launches += 1 }, pause: { polls += 1 })
        #expect(launches == 1); #expect(polls == 3)
    }
    @Test func failedLaunchStopsBeforeWaitingOrSaving() {
        var pauses = 0
        #expect(throws: Failure.self) {
            try ContactsAppStartup.prepare(isReady: { false }, launch: { throw Failure("launch failed") }, pause: { pauses += 1 })
        }
        #expect(pauses == 0)
    }
    @Test func unreadyAppTimesOutInsteadOfSendingMutation() {
        var time = Date(timeIntervalSince1970: 0); var launches = 0
        #expect(throws: Failure.self) {
            try ContactsAppStartup.prepare(isReady: { false }, launch: { launches += 1 },
                pause: { time.addTimeInterval(1) }, now: { time }, timeout: 2)
        }
        #expect(launches == 1)
    }
    @Test func applicationNotRunningErrorHasSpecificRecovery() {
        let message = DesktopError.message(Failure("「联系人」App 操作未完成（-600）：应用程序没有运行。 prepared 条目"))
        #expect(message.contains("手动打开"))
        #expect(!message.contains("本次保存未全部确认"))
    }
}
