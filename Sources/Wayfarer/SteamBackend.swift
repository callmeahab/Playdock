import AppKit
import CryptoKit
import Security
import WayfarerCore

/// Presentation state belongs to one Steam installation, never to its games.
/// The native adapter consumes this file before ordering a Steam window.
@MainActor
final class SteamBackend {
    private var directories=Set<URL>()
    private var termination:NSObjectProtocol?
    private var currentAdapterStamp:String?
    private var preparedAdapter:URL?

    init() {
        termination=NotificationCenter.default.addObserver(forName:NSApplication.willTerminateNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideAll() }
        }
    }
    func directory(root:URL,prefix:URL?) throws -> URL {
        let key=(prefix ?? root).resolvingSymlinksInPath().path
        let hash=SHA256.hash(data:Data(key.utf8)).map { String(format:"%02x",$0) }.joined()
        let directory=AppPaths.support.appendingPathComponent("SteamBackend/\(hash)",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        guard directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL else {
            throw WayfarerError.message("Steam’s background presentation folder is redirected. Choose a local Wayfarer support folder.")
        }
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        if directories.insert(directory).inserted { try Data("{}".utf8).write(to:directory.appendingPathComponent("presentation.json"),options:.atomic) }
        return directory
    }
    func isAttached(_ app:NSRunningApplication,root:URL,prefix:URL?) -> Bool {
        guard let directory=try? directory(root:root,prefix:prefix),let token=RuntimeProcessIdentity.token(for:app.processIdentifier),
              let ready=try? String(contentsOf:directory.appendingPathComponent("\(token.pid).ready"),encoding:.utf8) else { return false }
        guard let identity=try? adapterIdentity() else { return false }
        return ready=="\(token.startedSeconds):\(token.startedMicroseconds)\n\(identity)"
    }
    func present(root:URL,prefix:URL?,in window:NSWindow?) {
        guard let directory=try? directory(root:root,prefix:prefix) else { return }
        var state:[String:Any]=[:]
        if let window,let token=RuntimeProcessIdentity.token(for:getpid()) {
            state=["window":window.windowNumber,"pid":token.pid,"seconds":token.startedSeconds,"microseconds":token.startedMicroseconds]
        }
        if let data=try? JSONSerialization.data(withJSONObject:state) { try? data.write(to:directory.appendingPathComponent("presentation.json"),options:.atomic) }
    }
    func hideAll() {
        for directory in directories { try? Data("{}".utf8).write(to:directory.appendingPathComponent("presentation.json"),options:.atomic) }
    }
    private func adapter() throws -> URL {
        if let preparedAdapter { return preparedAdapter }
        guard let adapter=Bundle.main.privateFrameworksURL?.appendingPathComponent("libWayfarerWineDisplay.dylib"),FileManager.default.fileExists(atPath:adapter.path) else {
            throw WayfarerError.message("Steam’s background presentation adapter is missing from this build.")
        }
        let prepared=try NativeRuntime.prepareAdapter(source:adapter)
        preparedAdapter=prepared
        return prepared
    }
    private func adapterIdentity() throws -> String {
        if let currentAdapterStamp { return currentAdapterStamp }
        let file=try adapter().resolvingSymlinksInPath()
        let hash=SHA256.hash(data:try Data(contentsOf:file)).map { String(format:"%02x",$0) }.joined()
        let identity=file.path+"\n"+hash
        currentAdapterStamp=identity
        return identity
    }
    func attach(_ command:LaunchCommand,profile:RuntimeProfile) throws -> LaunchCommand {
        guard let steam=profile.steamExecutable else { throw WayfarerError.message("Steam is missing from this environment.") }
        let directory=try directory(root:steam.deletingLastPathComponent(),prefix:profile.prefix)
        return try NativeRuntime.attachSteamBackend(command,runtime:profile.runtime,loader:NativeRuntime.prepare(runtime:profile.runtime),adapter:adapter(),directory:directory)
    }
    func macCommand(arguments:[String],port:UInt16) throws -> LaunchCommand {
        let root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
        // Launch the installed client directly. LaunchServices would first show
        // the regular Steam bootstrap app and register its Dock icon.
        let executable=root.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/steam_osx")
        guard FileManager.default.isExecutableFile(atPath:executable.path) else {
            throw WayfarerError.message("Complete the macOS Steam installation before connecting its backend in Wayfarer.")
        }
        var code:SecStaticCode?, info:CFDictionary?
        guard SecStaticCodeCreateWithPath(executable as CFURL,[],&code)==errSecSuccess,let code,
              SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&info)==errSecSuccess,
              let flags=(info as? [String:Any])?[kSecCodeInfoFlags as String] as? UInt32,flags & 0x10000 == 0 else {
            throw WayfarerError.message("This Mac Steam build blocks Wayfarer’s background adapter.")
        }
        let directory=try directory(root:root,prefix:nil)
        return LaunchCommand(executable:executable,arguments:["-silent","-cef-enable-debugging","-devtools-port",String(port)]+arguments,
                             environment:["WAYFARER_STEAM_BACKEND":directory.path,"DYLD_INSERT_LIBRARIES":try adapter().path],workingDirectory:root)
    }
}
