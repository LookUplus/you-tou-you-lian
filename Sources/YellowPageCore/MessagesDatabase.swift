import Foundation
import CSQLite
import LegacyBody
import Darwin

public struct MessagesAccessError: Error, CustomStringConvertible, Sendable {
    public enum Kind: Sendable { case permission, missingDatabase, cannotOpen }
    public let kind: Kind
    public let path: String
    public let detail: String
    public init(kind: Kind, path: String, detail: String = "") { self.kind = kind; self.path = path; self.detail = detail }
    public var description: String {
        let advice: String
        switch kind {
        case .permission: advice = "目前无法读取本机短信。请为当前运行的 App（命令行使用者为终端）开启完全磁盘访问，退出并重新打开后再检查。即使系统开关已打开，也请重新进入该页面确认；更换新版后可能需要重新授权。"
        case .missingDatabase: advice = "没有找到本机短信数据库。请先打开「信息」App 并确认短信已同步到这台 Mac，再检查访问。"
        case .cannotOpen: advice = "暂时无法打开本机短信数据库。请确认「信息」App 可正常使用；授权状态以实际读取结果为准。"
        }
        return advice + " 路径：" + path + (detail.isEmpty ? "" : "；" + detail)
    }
}

public enum MessagesDatabase {
    public static var defaultPath:String { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path }
    public static func read(_ path:String) throws -> [Observation] {
        var db:OpaquePointer?
        guard sqlite3_open_v2(path,&db,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else {
            let systemError = db.map { sqlite3_system_errno($0) } ?? errno
            let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开文件"
            if db != nil {sqlite3_close(db)}
            let kind: MessagesAccessError.Kind = (systemError == EACCES || systemError == EPERM) ? .permission
                : systemError == ENOENT ? .missingDatabase : .cannotOpen
            throw MessagesAccessError(kind: kind, path: path, detail: detail)
        }
        defer {sqlite3_close(db)}
        sqlite3_busy_timeout(db,5000)
        guard sqlite3_exec(db,"PRAGMA query_only=ON; BEGIN",nil,nil,nil)==SQLITE_OK else {throw Failure("信息数据库正忙，请稍后重试。")}
        defer {sqlite3_exec(db,"ROLLBACK",nil,nil,nil)}
        func columns(_ table:String)->Set<String> {
            var q:OpaquePointer?;var names=Set<String>()
            guard sqlite3_prepare_v2(db,"PRAGMA table_info(\(table))",-1,&q,nil)==SQLITE_OK else {return names};defer{sqlite3_finalize(q)}
            while sqlite3_step(q)==SQLITE_ROW {if let t=sqlite3_column_text(q,1){names.insert(String(cString:t))}}
            return names
        }
        let cols=columns("message")
        guard Set(["text","attributedBody","handle_id","date","is_from_me","service"]).isSubset(of:cols),
              columns("handle").contains("id"),columns("chat_message_join").contains("message_id") else {
            throw Failure("此版本的信息数据库结构不受支持；未作任何修改。")
        }
        let spam=cols.contains("is_spam") ? "coalesce(m.is_spam,0)" : "0"
        let filter=cols.contains("filter_action") ? "coalesce(m.filter_action,0)" : "0"
        let normal=cols.contains("associated_message_type") ? "AND coalesce(m.associated_message_type,0)=0" : ""
        let item=cols.contains("item_type") ? "AND coalesce(m.item_type,0)=0" : ""
        let sql="""
        SELECT h.id,m.date,m.text,m.attributedBody,\(spam),\(filter)
        FROM message m JOIN handle h ON h.ROWID=m.handle_id
        WHERE m.is_from_me=0 AND m.service='SMS' \(normal) \(item)
        AND EXISTS(SELECT 1 FROM chat_message_join j WHERE j.message_id=m.ROWID)
        ORDER BY m.ROWID
        """
        var query:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&query,nil)==SQLITE_OK else {throw Failure("读取短信失败：\(String(cString:sqlite3_errmsg(db)))")}
        defer {sqlite3_finalize(query)}
        var rows=[Observation]();var step=sqlite3_step(query)
        while step==SQLITE_ROW {
            defer {step=sqlite3_step(query)}
            guard let senderBytes=sqlite3_column_text(query,0) else {continue}
            let sender=String(cString:senderBytes);guard TextRules.isSender(sender) else {continue}
            let raw=sqlite3_column_double(query,1)
            let date=Date(timeIntervalSinceReferenceDate:abs(raw)>1e12 ? raw/1e9 : raw)
            var text=sqlite3_column_text(query,2).map{String(cString:$0)}
            var failed=false
            if text == nil || text!.isEmpty {
                if let bytes=sqlite3_column_blob(query,3),sqlite3_column_bytes(query,3)>0 {
                    let count=Int(sqlite3_column_bytes(query,3))
                    text=count<=2*1024*1024 ? YPDecodeBody(Data(bytes:bytes,count:count)) : nil
                    failed=text==nil
                }
            }
            rows.append(Observation(sender:sender,date:date,signature:text.flatMap(TextRules.signature),flagged:sqlite3_column_int(query,4) != 0 || sqlite3_column_int(query,5)==2,decodingFailed:failed))
        }
        guard step==SQLITE_DONE else {throw Failure("短信读取中断，请重新扫描。")}
        return rows
    }
}
