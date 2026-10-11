import Foundation

/// Only interface preferences are persisted; scans and selected numbers are never restored.
public struct DesktopPreferences: Codable, Equatable {
    public var mode: String = "demo"
    public var templatePath: String?
    public var accountID: String = ""
    public var limitDate = false
    public var since: Date = Calendar.current.startOfDay(for: Date())
    public init() {}
    public static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: "desktop.preferences.v1"),
              var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        if WorkspaceMode(rawValue: value.mode) == nil { value.mode = "demo" }
        if value.since > Date() { value.since = Calendar.current.startOfDay(for: Date()) }
        return value
    }
    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "desktop.preferences.v1") }
    }
}

public enum DesktopError {
    public static func message(_ error: Error) -> String {
        if let access = error as? MessagesAccessError {
            // Keep private paths and diagnostic codes in Copy Details, not in the onboarding instruction.
            if access.kind == .permission {
                return "目前无法读取本机短信。请为当前这份「有头有脸」App 开启完全磁盘访问，退出并重新打开后再检查。即使系统开关已打开，也请重新进入该页面确认；更换新版后可能需要重新授权。"
            }
            return access.description.components(separatedBy: " 路径：")[0]
        }
        let ns = error as NSError
        if let url = error as? CocoaError, url.code == .fileReadNoPermission {
            return "没有权限读取所选文件。请将黄页资料放到可访问的位置，再重新选择。"
        }
        let raw = String(describing: error)
        if raw.contains("134092") {
            return "系统没有完成名片保存。先到「操作记录」和「联系人」App 核对已添加的部分，再重新扫描；需要时可选择「通过『联系人』App（兼容）」保存。"
        }
        if raw.contains("-1743") { return "未允许控制「联系人」App。请在系统设置 → 隐私与安全性 → 自动化中允许「有头有脸」控制「联系人」，再重新扫描。" }
        if raw.contains("-600") { return "未能连接到「联系人」App，本次保存未完成。请手动打开「联系人」App，再重新扫描；已经成功添加的部分可在操作记录中查看。" }
        if raw.contains("-1712") { return "「联系人」App 响应超时。先检查操作记录和实际名片，确认保存结果后再重新扫描。" }
        if ns.domain == NSCocoaErrorDomain && [4, 260].contains(ns.code) {
            return "所选文件已被移动或删除，请重新选择黄页文件或解压后的文件夹。"
        }
        if ns.domain == NSCocoaErrorDomain && [3840, 4864].contains(ns.code) {
            return "无法读取这份资料。请重新下载并解压官方黄页，或选择有效的 .vcf 文件。"
        }
        if raw.contains("prepared 条目") {
            return "本次保存未全部确认。先查看「操作记录」，到「联系人」App 核对结果，再重新扫描。请勿反复添加同一份旧结果。"
        }
        return raw
            .replacingOccurrences(of: "请重新 scan", with: "请重新扫描")
            .replacingOccurrences(of: "运行工具的终端，然后重新打开终端", with: "「有头有脸」App，然后退出并重新打开 App")
            .replacingOccurrences(of: "当前终端", with: "「有头有脸」App")
            .replacingOccurrences(of: "通讯录 App", with: "「联系人」App")
    }
}
