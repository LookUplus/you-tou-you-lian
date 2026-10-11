import SwiftUI
import AppKit
import YellowPageCore

// Injectable read boundaries let permission recovery be tested without changing system settings.
struct PreparationReaders: Sendable {
    var messages: (@Sendable () throws -> Int)? = nil
    var accounts: (@Sendable () throws -> [WorkspaceAccount])? = nil
    var authorization: @Sendable () -> String = { ContactsGateway.authorization }
}

enum AccessCheckState: Equatable {
    case unchecked, checking, available(Int), unavailable(String)
    var isAvailable: Bool { if case .available = self { return true }; return false }
}

actor WorkspaceWorker {
    let workspace: DesktopWorkspace
    let readers: PreparationReaders
    let mode: WorkspaceMode
    init(mode: WorkspaceMode, baseDirectory: URL? = nil, readers: PreparationReaders = PreparationReaders()) {
        self.mode = mode; self.readers = readers
        workspace = DesktopWorkspace(mode: mode, baseDirectory: baseDirectory)
    }
    func validateTemplate(_ path: String) throws -> Int { try VCardCatalog.names(at: path).count }
    func historyWarnings() -> [String] { workspace.historyWarnings }
    func accounts() throws -> [WorkspaceAccount] { if mode == .personal, let read = readers.accounts { return try read() }; return try workspace.accounts() }
    func checkMessages() throws -> Int { if mode == .personal, let read = readers.messages { return try read() }; return try workspace.checkMessages() }
    func scan(template: String?, container: String, since: Date) throws -> Plan { try workspace.scan(template: template, container: container, since: since) }
    func apply(plan: Plan, selected: Set<String>, writer: String) throws -> Journal { try workspace.apply(plan: plan, selected: selected, writer: writer) }
    func undo(_ path: String) throws -> Journal { try workspace.undo(path: path) }
    func history() throws -> [WorkspaceRecord] { try workspace.history() }
    func reset() throws { try workspace.resetDemo() }
    func recordDirectory() -> URL { workspace.runsDirectory }
}

enum Page: String, CaseIterable, Identifiable {
    case prepare = "准备资料", review = "核对号码", history = "操作记录"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .prepare: return "folder"; case .review: return "checklist"; case .history: return "clock.arrow.circlepath" }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var confirmAdd = false
    @Published var undoRecord: WorkspaceRecord?
    @Published var confirmReset = false
    @Published var mode: WorkspaceMode = .demo
    @Published var page: Page? = .prepare
    @Published var accounts: [WorkspaceAccount] = []
    @Published var accountID = ""
    @Published var template: URL?
    @Published var templateCount = 0
    @Published var templateStatus = "请先选择黄页资料"
    @Published var historyWarning = ""
    @Published var choosingTemplate = false
    @Published var errorDetails = ""
    @Published var mutating = false
    @Published var limitDate = false
    @Published var since = Calendar.current.startOfDay(for: Date())
    @Published var writer = "automatic"
    @Published var plan: Plan?
    @Published var selected = Set<String>()
    @Published var records: [WorkspaceRecord] = []
    @Published var busy = false
    @Published var activity = ""
    @Published var notice = "先用演示数据熟悉操作，也可以切换到自己的数据。"
    @Published var error: String?
    @Published private(set) var messageState: AccessCheckState = .unchecked
    @Published private(set) var contactState: AccessCheckState = .unchecked
    @Published var filter = "全部"
    private var worker: WorkspaceWorker
    private let defaults: UserDefaults
    private let baseDirectory: URL?
    private let restoreAccountsOnStart: Bool
    private let readers: PreparationReaders
    private var preferences: DesktopPreferences
    private var started = false

    init(defaults: UserDefaults = .standard, baseDirectory: URL? = nil, restoreAccountsOnStart: Bool = true, readers: PreparationReaders = PreparationReaders()) {
        self.defaults = defaults; self.baseDirectory = baseDirectory; self.restoreAccountsOnStart = restoreAccountsOnStart; self.readers = readers
        preferences = DesktopPreferences.load(from: defaults)
        let mode = WorkspaceMode(rawValue: preferences.mode) ?? .demo
        self.mode = mode
        template = preferences.templatePath.map { URL(fileURLWithPath: $0) }
        accountID = mode == .personal ? preferences.accountID : ""
        limitDate = preferences.limitDate; since = preferences.since
        worker = WorkspaceWorker(mode: mode, baseDirectory: baseDirectory, readers: readers)
    }
    func savePreferences() {
        preferences.mode = mode.rawValue
        if !isDemo {
            preferences.templatePath = template?.path; preferences.accountID = accountID
            preferences.limitDate = limitDate; preferences.since = since
        }
        preferences.save(to: defaults)
    }
    var messageAccess: String {
        switch messageState {
        case .unchecked: return "尚未检查：以实际读取结果为准"
        case .checking: return "正在检查能否读取短信…"
        case .available(let count): return "可以读取 · \(count) 条 106 短信"
        case .unavailable(let detail): return detail
        }
    }
    var contactAccess: String {
        switch contactState {
        case .unchecked: return "首次使用，请点击下方按钮发起系统授权。"
        case .checking: return "正在请求授权并读取账户…"
        case .available(let count): return count == 0 ? "已获授权，但没有找到账户。请先在「联系人」App 中添加账户。" : "已读取 \(count) 个账户，请选择导入黄页的账户。"
        case .unavailable(let detail): return detail
        }
    }
    var preparationHint: String {
        if isDemo { return accounts.isEmpty ? "正在准备演示资料…" : "演示已准备好，可以扫描。" }
        if !messageState.isAvailable { return "请先完成第 1 步，检查能否读取本机短信。" }
        if !contactState.isAvailable || !accounts.contains(where: { $0.id == accountID }) { return "请点击「授权并读取账户」，再选择导入黄页的账户。" }
        if template == nil || templateCount == 0 { return templateStatus }
        return "准备好了，可以扫描短信。"
    }

    var isDemo: Bool { mode == .demo }
    var canScan: Bool {
        !busy && !choosingTemplate && accounts.contains { $0.id == accountID }
            && (isDemo || (templateCount > 0 && messageState.isAvailable && contactState.isAvailable))
    }
    var rows: [Decision] {
        guard let plan else { return [] }
        return plan.decisions.filter {
            switch filter {
            case "可添加": return $0.status == .add
            case "已保存": return $0.status == .alreadySaved
            case "已跳过": return $0.status != .add && $0.status != .alreadySaved
            default: return true
            }
        }
    }
    var targetName: String { accounts.first { $0.id == accountID }?.name ?? "未选择账户" }

    func perform(_ description: String, _ body: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; activity = description; error = nil
        Task {
            defer { busy = false; activity = "" }
            do { try await body() }
            catch {
                if error is MessagesAccessError {
                    self.messageState = .unavailable(DesktopError.message(error)); self.invalidate(); self.page = .prepare
                }
                self.errorDetails = String(describing: error)
                self.error = DesktopError.message(error)
            }
        }
    }

    func start() {
        guard !started else { return }; started = true
        perform("准备资料…") {
            if self.isDemo { try await self.readAccounts() }
            else {
                if let template = self.template {
                    do { self.templateCount = try await self.worker.validateTemplate(template.path); self.templateStatus = "已识别 \(self.templateCount) 家企业" }
                    catch { self.templateCount = 0; self.templateStatus = DesktopError.message(error) }
                }
                // Previously granted access can be restored silently; first-run authorization is explicit.
                await self.refreshMessages()
                if self.restoreAccountsOnStart && self.readers.authorization() == "完整访问" {
                    // Account failure stays in its own step; it must not block the other preparation checks.
                    do { try await self.readAccounts() } catch { }
                }
            }
            try await self.readHistory()
        }
    }
    private func readAccounts() async throws {
        contactState = .checking
        do { accounts = try await worker.accounts(); contactState = .available(accounts.count) }
        catch {
            accounts = []; contactState = .unavailable(DesktopError.message(error)); invalidate()
            throw error
        }
        if !accounts.contains(where: { $0.id == accountID }) {
            accountID = accounts.first(where: \.isDefault)?.id ?? accounts.first?.id ?? ""
        }
        if accounts.isEmpty { notice = "没有找到通讯录账户。请先在「联系人」App 中添加账户并导入企业名片。" }
        if isDemo { messageState = .available(0) }
        savePreferences()
    }
    private func readHistory() async throws {
        records = try await worker.history()
        let warnings = await worker.historyWarnings()
        historyWarning = warnings.isEmpty ? "" : "有 \(warnings.count) 份记录无法读取，已保留原文件；其他记录仍可查看。"
    }
    func changeMode(_ newMode: WorkspaceMode) {
        guard !busy, !choosingTemplate, mode != newMode else { return }
        savePreferences()
        mode = newMode; worker = WorkspaceWorker(mode: newMode, baseDirectory: baseDirectory, readers: readers)
        plan = nil; selected = []; accounts = []; accountID = ""; records = []; error = nil
        historyWarning = ""; messageState = .unchecked; contactState = .unchecked; page = .prepare; writer = "automatic"
        limitDate = isDemo ? false : preferences.limitDate
        if !isDemo { accountID = preferences.accountID }
        savePreferences()
        notice = isDemo ? "演示数据完全虚构，可以反复扫描、添加和撤销。" : "选择黄页和账户后扫描；添加前会再次请你确认。"
        started = false; start()
    }
    func loadAccounts() {
        perform("读取账户…") {
            try await self.readAccounts(); self.invalidate()
        }
    }
    private func refreshMessages() async {
        // An old successful check, or a remembered preference, is never evidence of current access.
        messageState = .checking; invalidate()
        do { messageState = .available(try await worker.checkMessages()) }
        catch { messageState = .unavailable(DesktopError.message(error)); errorDetails = String(describing: error) }
    }
    func checkMessages() {
        perform("检查短信访问…") { await self.refreshMessages() }
    }
    func invalidateMessageAccess() {
        messageState = .unchecked; invalidate()
    }
    func invalidateContactAccess() {
        accounts = []; contactState = .unchecked; invalidate()
    }
    func refreshContactAuthorization() {
        guard !isDemo, !busy, contactState.isAvailable, readers.authorization() != "完整访问" else { return }
        invalidateContactAccess()
        contactState = .unavailable("联系人权限已变化。请在系统设置中允许完整访问，再点「授权并读取账户」。")
    }
    func chooseTemplate() {
        guard !busy, !choosingTemplate, !isDemo else { return }
        choosingTemplate = true
        let panel = NSOpenPanel()
        panel.title = "选择 vCards 黄页"; panel.prompt = "选择"
        panel.message = "选择 archive 解压文件夹，或 default.vcf 等 vCard 文件。"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.begin { result in
            Task { @MainActor in
                self.choosingTemplate = false
                if result == .OK, let url = panel.url { self.selectTemplate(url) }
            }
        }
    }
    func selectTemplate(_ url: URL) {
        guard !busy, !isDemo else { return }
        template = url; templateCount = 0; invalidate(); savePreferences()
        perform("检查黄页资料…") {
            do { self.templateCount = try await self.worker.validateTemplate(url.path); self.templateStatus = "已识别 \(self.templateCount) 家企业" }
            catch { self.templateStatus = DesktopError.message(error); throw error }
        }
    }
    func invalidate() { plan = nil; selected = []; savePreferences() }
    func scan() {
        guard canScan else { notice = preparationHint; return }
        perform("正在读取和匹配短信…") {
            self.invalidate()
            // Recheck immediately before scanning too: permissions may have changed while the window stayed open.
            if !self.isDemo {
                await self.refreshMessages()
                guard self.messageState.isAvailable else { self.page = .prepare; self.notice = "短信暂时无法读取，请按第 1 步的提示重新检查。"; return }
                let originalAccount = self.accountID
                do { try await self.readAccounts() }
                catch { self.page = .prepare; throw error }
                guard self.accountID == originalAccount, self.accounts.contains(where: { $0.id == originalAccount }) else {
                    self.page = .prepare; self.notice = "原来选择的账户已不可用，请重新选择账户后扫描。"; return
                }
            }
            let plan = try await self.worker.scan(template: self.template?.path, container: self.accountID,
                since: self.limitDate ? Calendar.current.startOfDay(for: self.since) : Date(timeIntervalSince1970: 0))
            self.plan = plan; self.selected = Set(plan.additions.map(\.sender)); self.filter = plan.additions.isEmpty ? "全部" : "可添加"
            self.page = .review
            self.notice = plan.additions.isEmpty ? "本次没有需要补充的号码，可以查看已保存和跳过的原因。" : "已找到 \(plan.additions.count) 个可添加号码，请核对企业和号码。"
        }
    }
    func apply() {
        guard !busy, let plan, !selected.isEmpty else { return }
        mutating = true
        let selection = selected
        perform(self.isDemo ? "正在模拟添加…" : "正在添加号码…") {
            defer { self.invalidate(); self.mutating = false }
            do {
                let journal = try await self.worker.apply(plan: plan, selected: selection, writer: self.writer)
                let count = journal.entries.reduce(0) { $0 + $1.added.count }
                self.notice = self.isDemo ? "演示完成：已在虚构名片里添加 \(count) 个号码。可以撤销，或重置后重新录制。" : "已保存 \(count) 个号码。iCloud 同步由系统处理，可到「联系人」App 核对。"
                self.page = .history
                do { try await self.readHistory() } catch { self.historyWarning = "号码已保存，但暂时无法读取记录列表；请点击刷新记录。" }
            } catch {
                try? await self.readHistory()
                self.page = .history
                self.notice = "操作未全部完成，请先查看记录；重新扫描后再继续。"
                throw error
            }
        }
    }
    func undo(_ record: WorkspaceRecord) {
        guard !busy else { return }; mutating = true
        perform("正在撤销…") {
            defer { self.mutating = false }
            self.invalidate()
            let journal = try await self.worker.undo(record.path)
            let pending = journal.entries.filter { $0.state == "prepared" }.count
            try await self.readHistory()
            self.notice = pending == 0 ? "已撤销这次可核实的新增号码，其他号码保留。" : "已撤销可核实的部分；仍有 \(pending) 张名片保存结果不确定，请人工核对。"
        }
    }
    func loadHistory() {
        perform("读取操作记录…") { try await self.readHistory() }
    }
    func resetDemo() {
        guard isDemo else { return }
        perform("重置演示…") {
            try await self.worker.reset(); self.invalidate(); self.records = []; self.page = .prepare
            self.limitDate = false; self.notice = "演示已重置，可以重新扫描。真实通讯录未被修改。"
        }
    }
    func revealRecords() {
        Task {
            let directory = await worker.recordDirectory()
            if FileManager.default.fileExists(atPath: directory.path) { NSWorkspace.shared.open(directory) }
        }
    }
    func revealCurrentApp() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    func settings(_ pane: String) {
        guard !busy, !isDemo else { return }
        if pane == "Privacy_AllFiles" { invalidateMessageAccess() }
        if pane == "Privacy_Contacts" { invalidateContactAccess() }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) }
    }
}
