import Foundation
import CryptoKit
import Darwin

public struct Failure: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}
public struct Phone: Codable, Equatable, Hashable {
    public var id: String
    public var label: String?
    public var value: String
    public init(id: String, label: String? = "短信", value: String) { self.id=id; self.label=label; self.value=value }
    // Contacts can normalize an absent label to an empty string when saving.
    // Keep the raw representation in backups; compare only those two empty forms
    // as equivalent. IDs, values and all nonempty labels remain exact.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.value == rhs.value && (lhs.label ?? "") == (rhs.label ?? "")
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(value); hasher.combine(label ?? "")
    }
}
public struct Person: Codable, Equatable {
    public var id: String
    public var container: String
    public var organization: String
    public var isCompany: Bool
    public var phones: [Phone]
    public init(id: String, container: String="default", organization: String, isCompany: Bool=true, phones: [Phone]=[]) {
        self.id=id; self.container=container; self.organization=organization; self.isCompany=isCompany; self.phones=phones
    }
}
public struct Observation: Equatable {
    public var sender: String
    public var date: Date
    public var signature: String?
    public var flagged: Bool
    public var decodingFailed: Bool
    public init(sender: String, date: Date, signature: String?, flagged: Bool=false, decodingFailed: Bool=false) {
        self.sender=sender; self.date=date; self.signature=signature; self.flagged=flagged; self.decodingFailed=decodingFailed
    }
}
public struct ScanConfiguration: Codable {
    public var database: String
    public var since: Date
    public var container: String
    public var catalogNames: [String]?
    public init(database: String, since: Date, container: String, catalogNames: [String]?=nil) {
        self.database=database; self.since=since; self.container=container; self.catalogNames=catalogNames
    }
}
public enum DecisionStatus: String, Codable {
    case add, alreadySaved, outsidePeriod, unsigned, decodingFailed, flagged
    case unknownSignature, ambiguousContact, conflictingSignatures, assignedElsewhere, outsideCatalog
}
public struct Decision: Codable, Equatable {
    public var sender: String
    public var signatures: [String]
    public var messageCount: Int
    public var lastDate: Date
    public var status: DecisionStatus
    public var contactID: String?
    public var contactName: String?
    public var reason: String
    public var before: Person?
}
public struct Plan: Codable {
    public var version = 1
    public var createdAt: Date
    public var configuration: ScanConfiguration
    public var decisions: [Decision]
    public var scannedMessages: Int
    public var additions: [Decision] { decisions.filter { $0.status == .add } }
}
public enum TextRules {
    public static func name(_ input: String) -> String {
        input.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier:"en_US_POSIX"))
            .filter { !$0.isWhitespace }
    }
    public static func phone(_ input: String) -> String {
        let s = input.trimmingCharacters(in:.whitespacesAndNewlines)
        var digits = s.filter { $0.isASCII && $0.isNumber }
        if s.hasPrefix("+86") || s.hasPrefix("0086") { digits=String(digits.dropFirst(s.hasPrefix("+86") ? 2 : 4)) }
        else if digits.count == 13 && digits.hasPrefix("861") && !digits.hasPrefix("86106") { digits=String(digits.dropFirst(2)) }
        return digits
    }
    public static func isSender(_ input: String) -> Bool {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.contains("+") && (!input.hasPrefix("+86") || input.filter({$0 == "+"}).count != 1) { return false }
        let allowed = CharacterSet(charactersIn:"+0123456789 -()")
        guard input.unicodeScalars.allSatisfy({allowed.contains($0)}) else { return false }
        let n=phone(input)
        return n.hasPrefix("106") && (6...24).contains(n.count)
    }
    public static func signature(_ text: String) -> String? {
        let s=text.trimmingCharacters(in:.whitespacesAndNewlines.union(CharacterSet(charactersIn:"\u{feff}\u{200b}")))
        guard let first=s.first, first == "【" || first == "[" else { return nil }
        let close: Character = first == "【" ? "】" : "]"
        guard let end=s.dropFirst().firstIndex(of:close) else { return nil }
        let value=String(s[s.index(after:s.startIndex)..<end]).trimmingCharacters(in:.whitespacesAndNewlines)
        guard (1...64).contains(value.count), !value.contains(where:{$0.isNewline}),
              !value.contains("【"), !value.contains("["),
              value.contains(where:{$0.isLetter}), !value.contains("://") else { return nil }
        return value
    }
}
public enum JSONFile {
    public static func data<T:Encodable>(_ value:T) throws -> Data {
        let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes];e.dateEncodingStrategy = .iso8601
        return try e.encode(value)
    }
    public static func read<T:Decodable>(_ type:T.Type, from path:String) throws -> T {
        let d=JSONDecoder();d.dateDecodingStrategy = .iso8601
        return try d.decode(type,from:Data(contentsOf:URL(fileURLWithPath:path)))
    }
    public static func write<T:Encodable>(_ value:T, to path:String, overwrite:Bool=false) throws {
        let url=URL(fileURLWithPath:path)
        let temporary=url.deletingLastPathComponent().appendingPathComponent(".yellowpage-" + UUID().uuidString).path
        let fd=open(temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,S_IRUSR|S_IWUSR)
        guard fd>=0 else { throw Failure("无法创建私密输出文件，请确认目录存在且可写：\(path)") }
        defer {close(fd);unlink(temporary)}
        let bytes=try data(value)
        try bytes.withUnsafeBytes { buffer in
            var offset=0
            while offset<buffer.count {
                let count=Darwin.write(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                if count<0 && errno==EINTR {continue}
                guard count>0 else {throw Failure("写入操作记录失败，请检查磁盘空间。")}
                offset+=count
            }
        }
        guard fsync(fd)==0 else {throw Failure("无法将操作记录保存到磁盘，未开始后续操作。")}
        // link is exclusive: a concurrent scan cannot overwrite an existing plan.
        let status = overwrite ? rename(temporary,path) : link(temporary,path)
        guard status==0 else {throw Failure("无法保存文件（可能已经存在）：\(path)。请选择新的文件名。")}
    }
    public static func digest<T:Encodable>(_ value:T) throws -> String { SHA256.hash(data:try data(value)).map{String(format:"%02x",$0)}.joined() }
}
