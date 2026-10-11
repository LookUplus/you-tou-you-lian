import Foundation
import YellowPageCore
import Darwin

let help = """
有头有脸 · yellowpage 0.1.0
给已经导入通讯录的 vCards 企业名片补充 106 短信号码。

用法：
  yellowpage doctor
  yellowpage accounts
  yellowpage scan --vcards <官方 .vcf 或解压目录> --out <计划.json>
                  [--since YYYY-MM-DD] [--container <账户标识>]
  yellowpage review <计划.json>
  yellowpage apply <计划.json> --yes [--writer native|contacts-app]
                  [--journal-dir <备份目录>]
  yellowpage undo <操作记录.json> --yes
  yellowpage demo

scan 只读本机已下载的短信和通讯录；不会自动写入。
apply 重新核对短信、号码和名片后，只追加号码，并保存可撤销的操作记录。
undo 只移除该次操作新增且之后没有被编辑的号码。
不创建联系人，不替换姓名或头像，不内置个人品牌归属规则，不连接网络。
第一次运行需要终端的完全磁盘访问权限和完整通讯录访问权限。
"""

struct Arguments {
    var positional = [String]()
    var options = [String: String]()
    var yes = false
    init(_ values: [String], allowed: Set<String>) throws {
        var i = 0
        while i < values.count {
            let value = values[i]
            if value == "--yes" {
                guard allowed.contains("yes"), !yes else { throw Failure("不支持或重复的参数：--yes") }
                yes = true
            } else if value.hasPrefix("--") {
                let name = String(value.dropFirst(2))
                guard allowed.contains(name), options[name] == nil, i + 1 < values.count, !values[i+1].hasPrefix("--") else { throw Failure("未知、重复或缺少值的参数：\(value)") }
                i += 1; options[name] = values[i]
            } else { positional.append(value) }
            i += 1
        }
    }
    func required(_ key: String) throws -> String {
        guard let value = options[key], !value.isEmpty else { throw Failure("缺少 --\(key)。使用 yellowpage help 查看用法。") }
        return value
    }
    func oneFile() throws -> String {
        guard positional.count == 1 else { throw Failure("请提供一个 JSON 文件路径。") }
        return path(positional[0])
    }
}
func path(_ input: String) -> String { URL(fileURLWithPath: (input as NSString).expandingTildeInPath).standardizedFileURL.path }
func date(_ value: String) throws -> Date {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
    guard let result = formatter.date(from: value), formatter.string(from: result) == value, result <= Date() else { throw Failure("日期格式应为 YYYY-MM-DD，且不能晚于今天。") }
    return result
}
func present(_ plan: Plan, details: Bool = false) {
    let cards = Set(plan.additions.compactMap { $0.contactID }).count
    print("读取 \(plan.scannedMessages) 条 106 短信，涉及 \(plan.decisions.count) 个号码。")
    print("待补充 \(plan.additions.count) 个号码，涉及 \(cards) 张已有名片。")
    for row in plan.decisions where details || row.status == .add {
        print("[\(row.status.rawValue)] \(row.sender) → \(row.contactName ?? row.signatures.joined(separator: " / "))  · \(row.reason)")
    }
    let skips = Dictionary(grouping: plan.decisions.filter { $0.status != .add }, by: { $0.status.rawValue })
    if !skips.isEmpty { print("其他：" + skips.keys.sorted().map { "\($0) \(skips[$0]!.count)" }.joined(separator: "；")) }
}
func ensurePlan(_ plan: Plan) throws {
    guard plan.version == 1, let names = plan.configuration.catalogNames, !names.isEmpty,
          path(plan.configuration.database) == path(MessagesDatabase.defaultPath) else {
        throw Failure("此计划不是本版本生成的本机 vCards 扫描计划，请重新 scan。")
    }
}
func run() throws {
    let values = Array(CommandLine.arguments.dropFirst())
    let command = values.first ?? "help"
    let rest = Array(values.dropFirst())
    switch command {
    case "help", "--help", "-h": print(help)
    case "--version", "version": print("yellowpage 0.1.0")
    case "doctor":
        guard rest.isEmpty else { throw Failure("doctor 不接受参数。") }
        print("macOS：\(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("通讯录：\(ContactsGateway.authorization)")
        do { let rows = try MessagesDatabase.read(MessagesDatabase.defaultPath); print("信息数据库：只读访问正常（\(rows.count) 条符合范围的短信）") }
        catch { print("信息数据库：\(error)") }
        print("需要完整通讯录权限时运行 accounts。不会修改系统权限、代理或 iCloud 设置。")
    case "accounts":
        guard rest.isEmpty else { throw Failure("accounts 不接受参数。") }
        let containers = try ContactsGateway().containers()
        for c in containers { print("\(c.isDefault ? "*" : " ") \(c.name)  \(c.id)") }
        print("* 是默认账户。要同步到其他设备，应选择你启用了通讯录同步的 iCloud 账户。")
    case "scan":
        let args = try Arguments(rest, allowed: ["vcards", "out", "since", "container"])
        guard args.positional.isEmpty else { throw Failure("scan 不接受额外位置参数。") }
        let output = path(try args.required("out"))
        guard !FileManager.default.fileExists(atPath: output) else { throw Failure("输出文件已存在，请换一个文件名。") }
        let names = try VCardCatalog.names(at: path(args.required("vcards")))
        let since = try args.options["since"].map(date) ?? Date(timeIntervalSince1970: 0)
        let observations = try MessagesDatabase.read(MessagesDatabase.defaultPath)
        let gateway = ContactsGateway()
        let containers = try gateway.containers()
        guard let container = args.options["container"].flatMap({ id in containers.first { $0.id == id } }) ?? (args.options["container"] == nil ? containers.first { $0.isDefault } : nil) else { throw Failure("找不到目标账户，请运行 accounts 查看标识。") }
        let people = try gateway.people()
        let plan = try Planner.make(observations: observations, people: people,
            config: ScanConfiguration(database: MessagesDatabase.defaultPath, since: since, container: container.id, catalogNames: names))
        try JSONFile.write(plan, to: output)
        print("目标账户：\(container.name)；模板企业：\(names.count)。")
        present(plan)
        print("已保存预览：\(output)\n尚未修改通讯录。用 review 查看全部原因，再用 apply --yes 写入。")
    case "review":
        let args = try Arguments(rest, allowed: [])
        let plan = try JSONFile.read(Plan.self, from: args.oneFile())
        present(plan, details: true)
    case "apply":
        let args = try Arguments(rest, allowed: ["yes", "writer", "journal-dir"])
        let plan = try JSONFile.read(Plan.self, from: args.oneFile())
        try ensurePlan(plan)
        guard args.yes else { present(plan); throw Failure("尚未写入。核对计划后加 --yes 执行。") }
        let writer = args.options["writer"] ?? "native"
        guard ["native", "contacts-app"].contains(writer) else { throw Failure("writer 只能是 native 或 contacts-app。") }
        let lock = try RunLock(); defer { withExtendedLifetime(lock) {} }
        let gateway = ContactsGateway(writer: writer)
        let people = try gateway.people()
        let refreshed = try Planner.make(observations: MessagesDatabase.read(plan.configuration.database), people: people, config: plan.configuration)
        let additions = try Planner.validateForApply(plan, refreshed: refreshed, people: people)
        guard !additions.isEmpty else { print("没有需要添加的号码；已存在的号码不会重复写入。"); return }
        let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/YellowPage/Runs").path
        let directory = path(args.options["journal-dir"] ?? defaultDirectory)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let journalPath = URL(fileURLWithPath: directory).appendingPathComponent("\(UUID().uuidString).journal.json").path
        print("开始追加 \(additions.count) 个号码。操作记录：\(journalPath)")
        let journal = try MutationEngine.apply(additions, plan: plan, repository: gateway, writer: writer, journalPath: journalPath)
        print("已核对并追加 \(journal.entries.reduce(0) { $0 + $1.added.count }) 个号码。头像、姓名和其他资料未主动修改。")
        print("如需撤销：yellowpage undo \"\(journalPath)\" --yes")
        print("云端同步由所选账户和系统处理，本工具不强制触发或保证同步完成。")
    case "undo":
        let args = try Arguments(rest, allowed: ["yes"])
        let file = try args.oneFile()
        let old = try JSONFile.read(Journal.self, from: file)
        guard args.yes else { throw Failure("将尝试撤销 \(old.entries.filter { $0.state == "applied" }.count) 张名片的新增号码；加 --yes 执行。") }
        guard ["native", "contacts-app"].contains(old.writer) else { throw Failure("未知的写入方式。") }
        let lock = try RunLock(); defer { withExtendedLifetime(lock) {} }
        let result = try MutationEngine.undo(journalPath: file, repository: ContactsGateway(writer: old.writer))
        print("已完成可核实条目的撤销；不会移除原有号码或之后手动添加的号码。")
        let uncertain = result.entries.filter { $0.state == "prepared" }
        if !uncertain.isEmpty { print("另有 \(uncertain.count) 张名片保存结果未确认，未自动撤销，请按记录人工核对。") }
    case "demo":
        guard rest.isEmpty else { throw Failure("demo 不接受参数。") }
        print("以下为虚构示例，不读取短信或通讯录：")
        let now = Date()
        let people = [Person(id: "demo-a", organization: "示例银行"), Person(id: "demo-b", organization: "示例出行")]
        let rows = [Observation(sender: "10600000001", date: now, signature: "示例银行"),
                    Observation(sender: "10600000002", date: now, signature: "示例银行"),
                    Observation(sender: "10600000002", date: now, signature: "示例出行"),
                    Observation(sender: "10600000003", date: now, signature: "未导入的企业")]
        let config = ScanConfiguration(database: "demo", since: .distantPast, container: "default", catalogNames: ["示例银行", "示例出行", "未导入的企业"])
        present(try Planner.make(observations: rows, people: people, config: config), details: true)
    default: throw Failure("未知命令：\(command)。运行 yellowpage help 查看用法。")
    }
}
do { try run() }
catch { FileHandle.standardError.write(Data("错误：\(error)\n".utf8)); exit(1) }
