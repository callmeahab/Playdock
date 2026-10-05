import Foundation
import Darwin

public struct RuntimeProcessToken: Sendable, Equatable {
    public let pid: pid_t
    public let startedSeconds: UInt64
    public let startedMicroseconds: UInt64
}

public enum RuntimeProcessIdentity {
    public struct WindowsProcess:Sendable {
        public let token:RuntimeProcessToken
        public let program:String
    }
    public static func steamProcesses(root:URL,prefix:URL?) throws -> [RuntimeProcessToken] {
        let capacity=proc_listallpids(nil,0)
        guard capacity>0,capacity<100_000 else { throw WayfarerError.message("Steam process state is unavailable.") }
        var pids=[pid_t](repeating:0,count:Int(capacity)+256)
        let count=pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress,Int32($0.count)) }
        guard count>0,count<pids.count else { throw WayfarerError.message("Steam process state is unavailable.") }
        return pids.prefix(Int(count)).compactMap { pid in
            guard isSteamClient(pid:pid,root:root,prefix:prefix) else { return nil }
            return token(for:pid)
        }
    }
    public static func windowsProcesses(prefix:URL) throws -> [WindowsProcess] {
        let capacity=proc_listallpids(nil,0)
        guard capacity>0,capacity<100_000 else { throw WayfarerError.message("Windows process state is unavailable.") }
        var pids=[pid_t](repeating:0,count:Int(capacity)+256)
        let count=pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress,Int32($0.count)) }
        guard count>0,count<pids.count else { throw WayfarerError.message("Windows process state is unavailable.") }
        return pids.prefix(Int(count)).compactMap { pid in
            guard let token=token(for:pid),belongsToPrefix(pid:pid,prefix:prefix),let program=windowsProgram(for:pid) else { return nil }
            return WindowsProcess(token:token,program:program.lowercased())
        }
    }
    public static func hasWineServer(prefix:URL) throws -> Bool {
        let process=Process(); process.executableURL=URL(fileURLWithPath:"/usr/sbin/lsof")
        process.arguments=["-nP","-a","-c","wineserver","-Fpn",prefix.resolvingSymlinksInPath().path]
        let output=Pipe(); process.standardOutput=output; process.standardError=FileHandle.nullDevice
        try process.run(); let data=output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard data.count<65536,[0,1].contains(process.terminationStatus) else { throw WayfarerError.message("Windows server state is unavailable.") }
        return process.terminationStatus==0 && String(decoding:data,as:UTF8.self).split(separator:"\n").contains("n\(prefix.resolvingSymlinksInPath().path)")
    }
    public static func isSteamClient(pid:pid_t,root:URL,prefix:URL?=nil) -> Bool {
        guard belongsToPrefix(pid:pid,prefix:prefix ?? root) else { return false }
        if prefix != nil {
            return ["steam.exe","steamwebhelper.exe","steamerrorreporter.exe"].contains(windowsProgram(for:pid)?.lowercased() ?? "")
        }
        let name=arguments(pid).first.map { URL(fileURLWithPath:$0).lastPathComponent.lowercased() } ?? ""
        return name=="steam_osx" || name=="steam helper"
    }
    /// Used only for authenticated display peers. Read argv, never environment.
    public static func windowsProgram(for pid: pid_t) -> String? {
        arguments(pid).first { $0.lowercased().hasSuffix(".exe") }.map {
            $0.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? $0
        }
    }

    public static func token(for pid: pid_t) -> RuntimeProcessToken? {
        guard let info = processInfo(pid) else { return nil }
        return RuntimeProcessToken(pid: pid, startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec)
    }

    /// Match the selected prefix or a verified descendant of this launch. Never inspect environments.
    public static func belongsToPrefix(pid: pid_t, prefix: URL, launch: RuntimeProcessToken? = nil) -> Bool {
        guard pid > 0 else { return false }
        let expected = prefix.resolvingSymlinksInPath().standardizedFileURL.path
        var current = pid
        var visited = Set<pid_t>()
        for _ in 0..<32 {
            guard current > 1, visited.insert(current).inserted, let info = processInfo(current) else { return false }
            if let launch, current == launch.pid,
               info.pbi_start_tvsec == launch.startedSeconds, info.pbi_start_tvusec == launch.startedMicroseconds { return true }
            if let directory = workingDirectory(current), isInside(directory, prefix: expected) { return true }
            for argument in arguments(current) where argument.hasPrefix("/") {
                if isInside(argument, prefix: expected) { return true }
            }
            current = pid_t(info.pbi_ppid)
        }
        return false
    }

    private static func isInside(_ path: String, prefix: String) -> Bool {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return canonical == prefix || canonical.hasPrefix(prefix + "/")
    }

    private static func processInfo(_ pid: pid_t) -> proc_bsdinfo? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
        return info
    }

    private static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size)) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    private static func arguments(_ pid: pid_t) -> [String] {
        var argmax: Int32 = 0
        var length = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.argmax", &argmax, &length, nil, 0) == 0, argmax > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: Int(argmax))
        var size = bytes.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let result = mib.withUnsafeMutableBufferPointer { pointer in
            bytes.withUnsafeMutableBytes { buffer in sysctl(pointer.baseAddress, u_int(pointer.count), buffer.baseAddress, &size, nil, 0) }
        }
        guard result == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0, argc < 100_000 else { return [] }
        var index = MemoryLayout<Int32>.size
        func nextString() -> String {
            let start = index
            while index < size && bytes[index] != 0 { index += 1 }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            if index < size { index += 1 }
            return text
        }
        _ = nextString() // Executable path, followed by NUL padding.
        while index < size && bytes[index] == 0 { index += 1 }
        var output: [String] = []
        for _ in 0..<Int(argc) where index < size { output.append(nextString()) }
        return output
    }
}
