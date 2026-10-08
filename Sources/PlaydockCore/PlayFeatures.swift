import Foundation
import CryptoKit

public enum GameSessionPhase: String, Codable, CaseIterable, Sendable {
    case launching, playing, stopping, disconnected, finished, failed, crashed, interrupted
    public var active: Bool { [.launching,.playing,.stopping,.disconnected].contains(self) }
    public var title: String { rawValue.capitalized }
}
public struct GameSessionRecord: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var gameID: String
    public var name: String
    public var platform: GamePlatform
    public var environmentID: String?
    public var phase: GameSessionPhase = .launching
    public var requestedAt = Date()
    public var startedAt: Date?
    public var endedAt: Date?
    public var message = "Waiting for the game to start."
    public init(gameID:String,name:String,platform:GamePlatform,environmentID:String?) { self.gameID=gameID;self.name=name;self.platform=platform;self.environmentID=environmentID }
    public mutating func observe(running:Bool?, now:Date = Date()) {
        guard phase.active else { return }
        guard let running else { if startedAt != nil { phase = .disconnected; message="Game status unavailable. Reconnect Steam to check it." }; return }
        if running { if startedAt == nil { startedAt=now }; if phase != .stopping { phase = .playing; message="Game is running." } }
        else if startedAt != nil { phase = .finished; endedAt=now; message="Session ended." }
        else if now.timeIntervalSince(requestedAt)>120 { phase = .failed;endedAt=now;message="Steam did not report the game running. Check Steam for updates or a confirmation, then retry." }
    }
    public var duration: TimeInterval { guard let startedAt else { return 0 }; return max(0,(endedAt ?? Date()).timeIntervalSince(startedAt)) }
}

/// Retry only known disconnected sessions. Offline mode is a user choice.
public struct BackendRecovery: Sendable {
    public init() {}
    public private(set) var failures=0
    public private(set) var attempts=0
    public private(set) var nextAttempt=Date.distantPast
    public private(set) var wasConnected=false
    public mutating func connected() { failures=0;attempts=0;wasConnected=true;nextAttempt = .distantPast }
    public mutating func failed() { failures += 1 }
    public func shouldRetry(now:Date=Date(),safe:Bool,enabled:Bool) -> Bool { enabled && wasConnected && safe && failures>=2 && attempts<3 && now>=nextAttempt }
    public mutating func attempted(now:Date=Date()) { attempts += 1;nextAttempt=now.addingTimeInterval(pow(2,Double(attempts))*15) }
}
public enum CompatibilityRating: String, Codable, CaseIterable, Sendable {
    case playable, needsTweaks, broken
    public var title:String { switch self { case .playable:return "Works well";case .needsTweaks:return "Works with tweaks";case .broken:return "Does not work" } }
}
public struct CompatibilityTest: Codable, Identifiable, Sendable {
    public var id=UUID()
    public var gameID:String
    public var environmentID:String
    public var engine:String
    public var fingerprint:String
    public var options:String
    public var rating:CompatibilityRating
    public var notes:String
    public var testedAt=Date()
    public init(gameID:String,environmentID:String,engine:String,fingerprint:String,options:String,rating:CompatibilityRating,notes:String) { self.gameID=gameID;self.environmentID=environmentID;self.engine=engine;self.fingerprint=fingerprint;self.options=options;self.rating=rating;self.notes=String(notes.prefix(2000)) }
    public static func fingerprint(_ profile:RuntimeProfile)->String {
        let values=try? FileManager.default.attributesOfItem(atPath:profile.runtime.executable.resolvingSymlinksInPath().path)
        return "\(profile.id)|\((values?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\((values?[.size] as? NSNumber)?.uint64Value ?? 0)"
    }
}
public enum ControllerGrid {
    public static func destination(index:Int,count:Int,columns:Int,dx:Int,dy:Int)->Int {
        guard count>0 else{return 0}; return min(count-1,max(0,index+dx+dy*max(1,columns)))
    }
}
public enum QuickSearch {
    public static func matches(_ query:String,name:String,tags:[String])->Bool {
        let haystack=([name]+tags).joined(separator:" ").folding(options:[.diacriticInsensitive,.caseInsensitive],locale:.current)
        return query.folding(options:[.diacriticInsensitive,.caseInsensitive],locale:.current).split(whereSeparator:{$0.isWhitespace}).allSatisfy{haystack.contains($0)}
    }
}

public struct SteamStorageFolder: Codable, Identifiable, Sendable {
    public var id:Int
    public var path:String
    public var name:String
    public var freeBytes:UInt64
    public var apps:[SteamStorageApp]
    public var usedBytes:UInt64 { apps.reduce(0){$0 &+ $1.bytes} }
}
public struct SteamStorageApp: Codable, Identifiable, Sendable {
    public var id:String
    public var bytes:UInt64
}
public struct SteamMaintenanceProgress: Codable, Sendable {
    public init(kind:String,progress:Double?,task:String,completed:Bool,failed:Bool){self.kind=kind;self.progress=progress;self.task=task;self.completed=completed;self.failed=failed}
    public var kind:String
    public var progress:Double?
    public var task:String
    public var completed:Bool
    public var failed:Bool
}
public struct SteamAchievement: Codable, Identifiable, Sendable {
    public var id:String
    public var name:String
    public var description:String
    public var achieved:Bool
    public var hidden:Bool
    public var unlockedAt:TimeInterval?
    public var currentProgress:Double?
    public var globalPercent:Double?
}
public struct AchievementSnapshot: Codable, Sendable {
    public init(scope:String,appID:String,updatedAt:Date,achievements:[SteamAchievement],offline:Bool=false){self.scope=scope;self.appID=appID;self.updatedAt=updatedAt;self.achievements=achievements;self.offline=offline}
    public var offline:Bool?
    public var scope:String
    public var appID:String
    public var updatedAt:Date
    public var achievements:[SteamAchievement]
}
public struct AchievementCache {
    public var directory:URL
    public init(directory:URL=AppPaths.support.appendingPathComponent("Achievements")){self.directory=directory}
    private func file(scope:String,appID:String)->URL { directory.appendingPathComponent(SHA256.hash(data:Data((scope+":"+appID).utf8)).map{String(format:"%02x",$0)}.joined()+".json") }
    public func load(scope:String,appID:String)throws->AchievementSnapshot {
        let url=file(scope:scope,appID:appID);let data=try Data(contentsOf:url);guard data.count<2_000_000 else{throw CocoaError(.fileReadCorruptFile)}
        let snapshot=try JSONDecoder().decode(AchievementSnapshot.self,from:data);guard snapshot.scope==scope,snapshot.appID==appID else{throw CocoaError(.fileReadCorruptFile)};return snapshot
    }
    public func save(_ snapshot:AchievementSnapshot)throws {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);try JSONEncoder().encode(snapshot).write(to:file(scope:snapshot.scope,appID:snapshot.appID),options:.atomic)}
}

public enum InstalledSize {
    /// Measure the selected app bundle only; never follow symlinks into other libraries.
    public static func bytes(at url:URL,maximumEntries:Int=250_000)throws->UInt64 {
        let keys:Set<URLResourceKey>=[.isSymbolicLinkKey,.isRegularFileKey,.isDirectoryKey,.totalFileAllocatedSizeKey,.fileSizeKey]
        let info=try url.resourceValues(forKeys:keys)
        guard info.isSymbolicLink != true else{throw PlaydockError.message("Size unavailable for a symbolic link.")}
        if info.isRegularFile==true{return UInt64(max(0,info.totalFileAllocatedSize ?? info.fileSize ?? 0))}
        guard info.isDirectory==true,let enumerator=FileManager.default.enumerator(at:url,includingPropertiesForKeys:Array(keys),options:[])else{throw CocoaError(.fileReadUnknown)}
        var bytes:UInt64=0,count=0
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            count += 1;guard count<=maximumEntries else{throw PlaydockError.message("This folder is too large to measure automatically.")}
            let values=try file.resourceValues(forKeys:keys)
            if values.isSymbolicLink==true{enumerator.skipDescendants();continue}
            if values.isRegularFile==true{let sum=bytes.addingReportingOverflow(UInt64(max(0,values.totalFileAllocatedSize ?? values.fileSize ?? 0)));guard !sum.overflow else{throw CocoaError(.fileReadCorruptFile)};bytes=sum.partialValue}
        };return bytes
    }
}
/// Steam reports -1 when exit information is unavailable. Only a tracked root
/// process with a known nonzero status provides crash evidence.
public enum SteamGameExit {
    public static func abnormalCode(root:URL,appID:String,since:Date)->Int? {
        guard UInt32(appID) != nil else{return nil}
        let url=root.appendingPathComponent("logs/gameprocess_log.txt")
        guard let handle=try? FileHandle(forReadingFrom:url) else{return nil};defer{try? handle.close()}
        guard let size=try? handle.seekToEnd() else{return nil};try? handle.seek(toOffset:size>131072 ? size-131072:0)
        guard let data=try? handle.read(upToCount:131072) else{return nil}
        return abnormalCode(text:String(decoding:data,as:UTF8.self),appID:appID,since:since)
    }
    public static func abnormalCode(text:String,appID:String,since:Date)->Int? {
        guard UInt32(appID) != nil else{return nil}
        let format=DateFormatter();format.locale=Locale(identifier:"en_US_POSIX");format.dateFormat="yyyy-MM-dd HH:mm:ss"
        let adding=try! NSRegularExpression(pattern:"^AppID "+appID+" adding PID ([0-9]+) as a tracked process")
        let exit=try! NSRegularExpression(pattern:"^AppID "+appID+" no longer tracking PID ([0-9]+), exit code (-?[0-9]+)$")
        var primary:String?,code:Int?
        for line in text.split(separator:"\n") {
            guard line.count>=23,line.first=="[",let date=format.date(from:String(line.dropFirst().prefix(19))),date>=since.addingTimeInterval(-1)else{continue}
            let body=String(line.dropFirst(22)),range=NSRange(body.startIndex...,in:body)
            if primary==nil,let match=adding.firstMatch(in:body,range:range),let group=Range(match.range(at:1),in:body){primary=String(body[group])}
            if let primary,let match=exit.firstMatch(in:body,range:range),let pid=Range(match.range(at:1),in:body),String(body[pid])==primary,let group=Range(match.range(at:2),in:body){code=Int(body[group])}
        }
        guard let code,code != 0,code != -1 else{return nil};return code
    }
}
