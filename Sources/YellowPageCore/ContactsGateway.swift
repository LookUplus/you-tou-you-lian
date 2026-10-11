import Foundation
import Contacts
import AppKit

public protocol ContactRepository {
    func people() throws -> [Person]
    /// Replaces only the phone field after checking the expected snapshot.
    func replacePhones(of expected: Person, with phones: [Phone]) throws -> Person
}

public struct ContactContainer {
    public let id: String
    public let name: String
    public let isDefault: Bool
}

public final class ContactsGateway: ContactRepository {
    private let store = CNContactStore()
    public let writer: String
    private let keys = [CNContactIdentifierKey, CNContactOrganizationNameKey, CNContactTypeKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
    public init(writer: String = "native") { self.writer = writer }
    public var effectiveWriter: String { Self.resolvedWriter(writer, systemMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion) }
    public static func resolvedWriter(_ requested: String, systemMajor: Int) -> String {
        guard requested == "automatic" else { return requested }
        // Imported cards can fail CNSaveRequest with 134092 on recent macOS releases,
        // even when notes are never requested. Use the system App's public script interface.
        return systemMajor >= 26 ? "contacts-app" : "native"
    }

    public static var authorization: String {
        switch CNContactStore.authorizationStatus(for: .contacts).rawValue {
        case 0: return "尚未授权"
        case 1: return "系统限制"
        case 2: return "未允许"
        case 3: return "完整访问"
        default: return "有限访问或未知权限"
        }
    }
    public func authorize() throws {
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            let semaphore = DispatchSemaphore(value: 0)
            var accessError: Error?
            store.requestAccess(for: .contacts) { _, error in accessError = error; semaphore.signal() }
            guard semaphore.wait(timeout: .now() + 60) == .success else { throw Failure("等待联系人授权超时。请完成系统提示后，再点击「授权并读取账户」。") }
            if let accessError { throw accessError }
        }
        guard CNContactStore.authorizationStatus(for: .contacts).rawValue == 3 else {
            throw Failure("需要完整的通讯录访问权限，才能检查号码是否已在其他名片中。请在系统设置 → 隐私与安全性 → 联系人中允许完整访问。当前：\(Self.authorization)。")
        }
    }
    public func containers() throws -> [ContactContainer] {
        try authorize()
        let preferred = store.defaultContainerIdentifier()
        return try store.containers(matching: nil).map { ContactContainer(id: $0.identifier, name: $0.name, isDefault: $0.identifier == preferred) }
    }
    public func people() throws -> [Person] {
        try authorize()
        var result = [Person]()
        for container in try store.containers(matching: nil) {
            let request = CNContactFetchRequest(keysToFetch: keys)
            request.unifyResults = false
            request.predicate = CNContact.predicateForContactsInContainer(withIdentifier: container.identifier)
            try store.enumerateContacts(with: request) { contact, _ in
                result.append(Self.person(contact, container: container.identifier))
            }
        }
        return result
    }
    private static func person(_ contact: CNContact, container: String) -> Person {
        Person(id: contact.identifier, container: container, organization: contact.organizationName,
               isCompany: contact.contactType == .organization,
               phones: contact.phoneNumbers.map { Phone(id: $0.identifier, label: $0.label, value: $0.value.stringValue) })
    }
    public func replacePhones(of expected: Person, with phones: [Phone]) throws -> Person {
        try authorize()
        guard let current = try people().first(where: { $0.id == expected.id }), current == expected else {
            throw Failure("写入前联系人发生变化：\(expected.organization)。请重新扫描。")
        }
        if effectiveWriter == "contacts-app" {
            try ContactsScript.replacePhones(of: expected, with: phones)
        } else {
            let request = CNContactFetchRequest(keysToFetch: keys)
            request.unifyResults = false
            request.predicate = CNContact.predicateForContacts(withIdentifiers: [expected.id])
            var found: CNContact?
            try store.enumerateContacts(with: request) { contact, _ in found = contact }
            guard let found, Self.person(found, container: expected.container) == expected,
                  let editable = found.mutableCopy() as? CNMutableContact else { throw Failure("无法重新读取目标名片。") }
            let existing = Dictionary(uniqueKeysWithValues: found.phoneNumbers.map { ($0.identifier, $0) })
            editable.phoneNumbers = try phones.map { phone in
                if let old = existing[phone.id] {
                    guard old.value.stringValue == phone.value, (old.label ?? "") == (phone.label ?? "") else { throw Failure("禁止修改已有号码。") }
                    return old
                }
                guard phone.id.hasPrefix("new:"), TextRules.isSender(phone.value) else { throw Failure("无效的新号码。") }
                return CNLabeledValue(label: phone.label, value: CNPhoneNumber(stringValue: phone.value))
            }
            let save = CNSaveRequest(); save.update(editable)
            do { try store.execute(save) }
            catch {
                let ns = error as NSError
                throw Failure("系统通讯录写入失败（\(ns.domain) / \(ns.code)）。已保留操作记录。先核对已添加的部分，再重新扫描；若是 134092，可以选择「通过『联系人』App（兼容）」保存。请先保存或取消 App 中正在编辑的名片。")
            }
        }
        // A new store avoids observing our own stale fetch cache.
        guard let result = try ContactsGateway().people().first(where: { $0.id == expected.id }) else { throw Failure("保存后无法读回名片，请查看操作记录。") }
        return result
    }
}

/// Uses only the documented Contacts scripting dictionary. Never edits its database.
public enum ContactsScript {
    public static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
    private static func execute(_ source: String) throws -> NSAppleEventDescriptor {
        if !Thread.isMainThread {
            return try DispatchQueue.main.sync { try execute(source) }
        }
        guard let script = NSAppleScript(source: source) else { throw Failure("无法创建通讯录脚本。") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            let message = String(describing: error[NSAppleScript.errorMessage] ?? "未知错误")
            throw Failure(scriptErrorMessage(number: number, message: message))
        }
        return result
    }
    public static func scriptErrorMessage(number: Int, message: String) -> String {
        let recovery = number == -1743 ? "请在系统设置 → 隐私与安全性 → 自动化中允许「有头有脸」控制「联系人」。" : ""
        return "「联系人」App 操作未完成（\(number)）：\(message)" + recovery
    }
    public static func preamble(_ expected: Person) -> String {
        """
        tell application id "com.apple.AddressBook"
            if unsaved then error "「联系人」App 有未保存的编辑，请先保存或取消。"
            set matches to every person whose organization is \(literal(expected.organization))
            if (count of matches) is not 1 then error "「联系人」App 内同名名片不唯一，已停止。"
            set targetCard to item 1 of matches
            if id of targetCard is not \(literal(expected.id)) then error "名片标识不一致，已停止。"
        """
    }
    public static func replacementScript(_ expected: Person, phones: [Phone]) -> String {
        var lines = [preamble(expected)]
        // Recheck values and IDs inside the same script immediately before changing anything.
        lines.append("if (count of phones of targetCard) is not \(expected.phones.count) then error \"电话号码已变化。\"")
        for phone in expected.phones {
            lines.append("set matchingPhones to every phone of targetCard whose id is \(literal(phone.id))")
            lines.append("if (count of matchingPhones) is not 1 then error \"号码标识不一致，已停止。\"")
            lines.append("if value of item 1 of matchingPhones is not \(literal(phone.value)) then error \"号码内容已变化。\"")
            // Contacts.app presents empty labels as a localized title such as 电话;
            // CNContact returns the raw empty string. Comparing those creates a false conflict.
            // We append/remove fields only: old labels are never rewritten. Nonempty labels,
            // all values/IDs/counts, and the CN snapshot remain protected.
            if let label = phone.label, !label.isEmpty {
                lines.append("if label of item 1 of matchingPhones is not \(literal(label)) then error \"号码标签已变化。\"")
            }
        }
        for old in expected.phones where !phones.contains(where: { $0.id == old.id }) {
            lines.append("delete (every phone of targetCard whose id is \(literal(old.id)))")
        }
        for phone in phones where phone.id.hasPrefix("new:") {
            lines.append("make new phone at end of phones of targetCard with properties {label:\(literal(phone.label ?? "短信")), value:\(literal(phone.value))}")
        }
        lines.append("save\nend tell")
        return lines.joined(separator: "\n")
    }
    static func replacePhones(of expected: Person, with phones: [Phone]) throws {
        guard phones.allSatisfy({ phone in expected.phones.contains(phone) || (phone.id.hasPrefix("new:") && TextRules.isSender(phone.value)) }) else { throw Failure("无效的号码变更。") }
        try ContactsAppStartup.ensureRunning()
        _ = try execute(replacementScript(expected, phones: phones))
    }
}

public enum VCardCatalog {
    public static func names(at path: String) throws -> [String] {
        let url = URL(fileURLWithPath: path)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else { throw Failure("找不到 vCards 文件或目录：\(path)") }
        let files: [URL]
        if directory.boolValue {
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { throw Failure("无法读取 vCards 目录。") }
            files = enumerator.compactMap { $0 as? URL }.filter {
                $0.pathExtension.lowercased() == "vcf" && ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true)
            }.sorted { $0.path < $1.path }
        } else {
            guard url.pathExtension.lowercased() == "vcf" else {
                throw Failure(url.pathExtension.lowercased() == "zip" ? "请先解压 archive.zip，再选择解压后的文件夹。" : "请选择 .vcf 文件或包含 .vcf 的文件夹。")
            }
            files = [url]
        }
        guard !files.isEmpty else { throw Failure("没有找到 .vcf 文件。请选择官方 Releases 的 archive.zip 解压目录，而不是源码 data 目录。") }
        var names = Set<String>()
        for file in files {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 100 * 1024 * 1024 else { throw Failure("vCard 文件过大：\(file.lastPathComponent)") }
            let data = try Data(contentsOf: file)
            let cards: [CNContact]
            do { cards = try CNContactVCardSerialization.contacts(with: data) }
            catch { throw Failure("无法解析 \(file.lastPathComponent)。请重新下载黄页；这次扫描未修改通讯录。") }
            guard !cards.isEmpty else { throw Failure("\(file.lastPathComponent) 中没有有效名片，请重新下载或选择黄页资料。") }
            for contact in cards {
                let name = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { names.insert(name) }
            }
        }
        guard !names.isEmpty else { throw Failure("模板中没有公司名称（ORG），无法安全匹配。") }
        return names.sorted()
    }
}
