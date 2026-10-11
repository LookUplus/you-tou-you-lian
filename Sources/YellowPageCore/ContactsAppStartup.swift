import Foundation
import AppKit

/// AppleScript's implicit launch can fail with -600. Launch the system App and
/// wait for it before sending any script that can modify a contact.
public enum ContactsAppStartup {
    private static let bundleID = "com.apple.AddressBook"

    public static func ensureRunning() throws {
        try prepare(isReady: {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .contains { !$0.isTerminated && $0.isFinishedLaunching }
        }, launch: {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                throw Failure("找不到系统「联系人」App，尚未修改名片。")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            let result = LaunchResult()
            // NSWorkspace documents that completion runs on a concurrent queue,
            // so this wait does not depend on the GUI's main queue.
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                result.finish(app: app, error: error)
            }
            guard result.signal.wait(timeout: .now() + 20) == .success else {
                throw Failure("启动「联系人」App 超时，尚未修改名片。请手动打开后重新扫描。")
            }
            if let error = result.error {
                throw Failure("无法启动「联系人」App，尚未修改名片：\(error.localizedDescription)")
            }
            guard result.app != nil else { throw Failure("系统未能启动「联系人」App，尚未修改名片。") }
        }, pause: {
            if Thread.isMainThread {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        })
    }

    static func prepare(isReady: () -> Bool, launch: () throws -> Void,
                        pause: () -> Void, now: () -> Date = Date.init,
                        timeout: TimeInterval = 20) throws {
        if isReady() { return }
        try launch()
        let deadline = now().addingTimeInterval(timeout)
        while !isReady() {
            guard now() < deadline else {
                throw Failure("「联系人」App 尚未就绪，尚未修改名片。请手动打开后重新扫描。")
            }
            pause()
        }
    }
}

private final class LaunchResult {
    let signal = DispatchSemaphore(value: 0)
    private(set) var app: NSRunningApplication?
    private(set) var error: Error?
    func finish(app: NSRunningApplication?, error: Error?) {
        self.app = app; self.error = error; signal.signal()
    }
}
