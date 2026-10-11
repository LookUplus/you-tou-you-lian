import Foundation

public enum WorkspaceMode: String, CaseIterable { case demo, personal }
public struct WorkspaceAccount: Identifiable {
    public let id: String
    public let name: String
    public let isDefault: Bool
}
public struct WorkspaceRecord: Identifiable {
    public var id: String { path }
    public let path: String
    public let date: Date
    public let added: Int
    public let pending: Int
    public let notApplied: Int
    public let present: Int
    public let undone: Bool
    public let names: [String]
}

/// Access only from one serial worker. Demo and personal workspaces never share a repository.
public final class DesktopWorkspace {
    public let mode: WorkspaceMode
    public private(set) var runsDirectory: URL
    public private(set) var lastJournalPath: String?
    public private(set) var historyWarnings: [String] = []
    private let baseDirectory: URL
    private var demo = DemoContacts()
    private var observations: [Observation]

    public init(mode: WorkspaceMode, baseDirectory: URL? = nil) {
        self.mode = mode
        let base = baseDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/YellowPage")
        self.baseDirectory = base
        runsDirectory = mode == .demo
            ? base.appendingPathComponent("DemoRuns/" + UUID().uuidString)
            : base.appendingPathComponent("Runs")
        observations = Self.demoObservations()
    }

    public func accounts() throws -> [WorkspaceAccount] {
        if mode == .demo { return [WorkspaceAccount(id: "demo", name: "演示通讯录（虚构）", isDefault: true)] }
        return try ContactsGateway().containers().map { WorkspaceAccount(id: $0.id, name: $0.name, isDefault: $0.isDefault) }
    }

    public func checkMessages() throws -> Int {
        if mode == .demo { return observations.count }
        return try MessagesDatabase.read(MessagesDatabase.defaultPath).count
    }

    public func scan(template: String?, container: String, since: Date) throws -> Plan {
        guard since <= Date() else { throw Failure("开始日期不能晚于今天。") }
        if mode == .demo {
            guard container == "demo" else { throw Failure("演示模式只能使用演示通讯录。") }
            return try Planner.make(observations: observations, people: demo.people(),
                config: ScanConfiguration(database: "demo", since: since, container: "demo",
                    catalogNames: ["示例银行", "示例快递", "示例出行", "示例商店"]))
        }
        guard let template else { throw Failure("请先选择 vCards 的 .vcf 文件或解压后的文件夹。") }
        let names = try VCardCatalog.names(at: template)
        let gateway = ContactsGateway()
        guard try gateway.containers().contains(where: { $0.id == container }) else { throw Failure("请重新选择通讯录账户。") }
        return try Planner.make(observations: MessagesDatabase.read(MessagesDatabase.defaultPath), people: gateway.people(),
            config: ScanConfiguration(database: MessagesDatabase.defaultPath, since: since, container: container, catalogNames: names))
    }

    public func apply(plan: Plan, selected: Set<String>, writer: String) throws -> Journal {
        guard !selected.isEmpty, selected.isSubset(of: Set(plan.additions.map(\.sender))) else {
            throw Failure("请选择预览中可以添加的号码，不能添加被跳过的号码。")
        }
        guard ["automatic", "native", "contacts-app"].contains(writer) else { throw Failure("未知的保存方式。") }
        let repository: ContactRepository
        let currentObservations: [Observation]
        let actualWriter: String
        if mode == .demo {
            guard plan.configuration.database == "demo", plan.configuration.container == "demo" else {
                throw Failure("演示模式不能使用真实扫描结果。")
            }
            repository = demo; currentObservations = observations; actualWriter = "demo"
        } else {
            guard plan.version == 1,
                  URL(fileURLWithPath: plan.configuration.database).standardizedFileURL == URL(fileURLWithPath: MessagesDatabase.defaultPath).standardizedFileURL,
                  let names = plan.configuration.catalogNames, !names.isEmpty else {
                throw Failure("请重新扫描自己的短信，演示结果不能写入通讯录。")
            }
            let gateway = ContactsGateway(writer: writer)
            repository = gateway
            currentObservations = try MessagesDatabase.read(MessagesDatabase.defaultPath)
            actualWriter = gateway.effectiveWriter
        }
        if mode == .demo { try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let lock = try RunLock(path: mode == .demo ? baseDirectory.appendingPathComponent("demo-\(runsDirectory.lastPathComponent).lock").path : nil); defer { withExtendedLifetime(lock) {} }
        let people = try repository.people()
        let refreshed = try Planner.make(observations: currentObservations, people: people, config: plan.configuration)
        var chosen = plan
        chosen.decisions = plan.decisions.filter { $0.status != .add || selected.contains($0.sender) }
        let additions = try Planner.validateForApply(chosen, refreshed: refreshed, people: people)
        guard !additions.isEmpty else { throw Failure("这些号码已经保存，请重新扫描。") }
        try FileManager.default.createDirectory(at: runsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = runsDirectory.appendingPathComponent(UUID().uuidString + ".journal.json").path
        lastJournalPath = path
        return try MutationEngine.apply(additions, plan: chosen, repository: repository, writer: actualWriter, journalPath: path)
    }

    public func undo(path: String) throws -> Journal {
        // Only operate on records in this workspace, including its demo session identity.
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent() == runsDirectory.standardizedFileURL else {
            throw Failure("这份操作记录不属于当前模式或演示会话。")
        }
        let record = try JSONFile.read(Journal.self, from: path)
        let repository: ContactRepository
        if mode == .demo {
            guard record.writer == "demo" else { throw Failure("演示模式不能撤销真实记录。") }
            repository = demo
        } else {
            guard ["native", "contacts-app"].contains(record.writer) else { throw Failure("演示记录不能用于真实通讯录。") }
            repository = ContactsGateway(writer: record.writer)
        }
        if mode == .demo { try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let lock = try RunLock(path: mode == .demo ? baseDirectory.appendingPathComponent("demo-\(runsDirectory.lastPathComponent).lock").path : nil); defer { withExtendedLifetime(lock) {} }
        return try MutationEngine.undo(journalPath: path, repository: repository)
    }

    public func history() throws -> [WorkspaceRecord] {
        historyWarnings = []
        guard FileManager.default.fileExists(atPath: runsDirectory.path) else { return [] }
        historyWarnings = []
        // No authorization prompt from the records screen. Reconcile only already-granted access.
        let snapshot = mode == .personal && ContactsGateway.authorization == "完整访问" ? try? ContactsGateway().people() : nil
        var records = [WorkspaceRecord]()
        for url in try FileManager.default.contentsOfDirectory(at: runsDirectory, includingPropertiesForKeys: [.isRegularFileKey])
            .filter({ $0.lastPathComponent.hasSuffix(".journal.json") }).sorted(by: { $0.path < $1.path }) {
            do {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                var journal = try JSONFile.read(Journal.self, from: url.path)
                guard journal.version == 1, journal.entries.allSatisfy({ ["prepared", "applied", "undone", "notApplied", "verifiedPresent"].contains($0.state) }),
                      (mode == .demo ? journal.writer == "demo" : ["native", "contacts-app"].contains(journal.writer)) else {
                    throw Failure("不支持的记录版本或来源")
                }
                if let snapshot, journal.entries.contains(where: { ["prepared", "notApplied", "verifiedPresent"].contains($0.state) }) {
                    do { journal = try MutationEngine.reconcile(journalPath: url.path, people: snapshot) }
                    catch { historyWarnings.append("\(url.lastPathComponent)：无法更新核对状态，已保留原记录。") }
                }
                records.append(WorkspaceRecord(path: url.path, date: journal.createdAt,
                    added: journal.entries.filter { $0.state == "applied" }.reduce(0) { $0 + $1.added.count },
                    pending: journal.entries.filter { $0.state == "prepared" }.count,
                    notApplied: journal.entries.filter { $0.state == "notApplied" }.count,
                    present: journal.entries.filter { $0.state == "verifiedPresent" }.count,
                    undone: !journal.entries.isEmpty && journal.entries.allSatisfy { $0.state == "undone" },
                    names: Array(Set(journal.entries.map { $0.before.organization })).sorted()))
            } catch { historyWarnings.append("\(url.lastPathComponent)：无法读取，已保留原文件。") }
        }
        return records.sorted { $0.date > $1.date }
    }

    public func resetDemo() throws {
        guard mode == .demo else { throw Failure("自己的通讯录不能重置。") }
        demo = DemoContacts(); observations = Self.demoObservations(); lastJournalPath = nil
        runsDirectory = baseDirectory.appendingPathComponent("DemoRuns/" + UUID().uuidString)
    }

    private static func demoObservations() -> [Observation] {
        let now = Date()
        return [
            Observation(sender: "10600000001", date: now, signature: "示例银行"),
            Observation(sender: "10600000002", date: now, signature: "示例快递"),
            Observation(sender: "10600000003", date: now, signature: "示例出行"),
            Observation(sender: "10600000004", date: now, signature: "示例银行"),
            Observation(sender: "10600000005", date: now, signature: "示例银行"),
            Observation(sender: "10600000005", date: now, signature: "示例商店"),
            Observation(sender: "10600000006", date: now, signature: "未收录品牌"),
            Observation(sender: "10600000007", date: now, signature: nil)]
    }
}

private final class DemoContacts: ContactRepository {
    private var records = [
        Person(id: "demo-bank", container: "demo", organization: "示例银行", phones: [Phone(id: "saved", value: "10600000004")]),
        Person(id: "demo-delivery", container: "demo", organization: "示例快递"),
        Person(id: "demo-travel", container: "demo", organization: "示例出行")]
    func people() throws -> [Person] { records }
    func replacePhones(of expected: Person, with phones: [Phone]) throws -> Person {
        guard let index = records.firstIndex(of: expected) else { throw Failure("演示名片已变化，请重新扫描。") }
        records[index].phones = phones.map {
            $0.id.hasPrefix("new:") ? Phone(id: UUID().uuidString, label: $0.label, value: $0.value) : $0
        }
        return records[index]
    }
}
