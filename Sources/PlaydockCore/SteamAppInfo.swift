import Foundation

public enum SteamAppInfo {
    public struct Metadata: Equatable { public let name: String, type: String, osList: String }
    /// Bounded, read-only appinfo v39–41 reader. PICS tokens and hashes are skipped.
    public static func read(_ data: Data, appIDs: Set<UInt32>) throws -> [UInt32: Metadata] {
        guard data.count <= 64_000_000 else { throw PlaydockError.message("Steam's metadata cache is too large.") }
        var reader = Reader(data: data, limit: data.count)
        let magic = try reader.u32(), version = magic & 255
        guard magic >> 8 == 0x075644, (39...41).contains(version), try reader.u32() == 1 else {
            throw PlaydockError.message("This Steam metadata cache version is not supported. Open Steam's library to browse it.")
        }
        var strings: [String]? = nil
        if version == 41 {
            let offset = try reader.u64()
            guard offset >= 16, offset < data.count else { throw Reader.bad }
            let saved = reader.cursor; reader.cursor = Int(offset)
            let count = try reader.u32(); guard count <= 200_000 else { throw Reader.bad }
            strings = []; strings!.reserveCapacity(Int(count))
            for _ in 0..<count { strings!.append(try reader.text()) }
            reader.cursor = saved; reader.limit = Int(offset)
        }
        var result: [UInt32: Metadata] = [:], entries = 0
        while reader.cursor < reader.limit {
            let id = try reader.u32(); if id == 0 { return result }
            entries += 1; guard entries <= 200_000 else { throw Reader.bad }
            let size = try reader.u32()
            let start = reader.cursor
            guard Int(size) <= reader.limit - start, size >= (version >= 40 ? 60 : 40) else { throw Reader.bad }
            let end = start + Int(size)
            if appIDs.contains(id) {
                var object = Reader(data: data, cursor: start + (version >= 40 ? 60 : 40), limit: end)
                var fields: [String: String] = [:]
                try object.object(strings: strings, path: [], depth: 0, fields: &fields)
                if let name = fields["name"], !name.isEmpty, let type = fields["type"] {
                    result[id] = Metadata(name: String(name.prefix(512)), type: type, osList: fields["oslist"] ?? "")
                }
            }
            reader.cursor = end
        }
        throw Reader.bad
    }
    public static func packageApps(_ data: Data, packageIDs: Set<UInt32>) throws -> [UInt32: Set<UInt32>] {
        guard data.count <= 64_000_000 else { throw Reader.bad }
        var reader = Reader(data: data, limit: data.count)
        let magic = try reader.u32()
        guard [UInt32(0x06565527), 0x06565528].contains(magic), try reader.u32() == 1 else { throw Reader.bad }
        var result: [UInt32: Set<UInt32>] = [:], entries = 0
        while reader.cursor < reader.limit {
            let id = try reader.u32(); if id == UInt32.max { return result }
            entries += 1; guard entries <= 200_000 else { throw Reader.bad }
            try reader.skip(magic == 0x06565528 ? 32 : 24)
            reader.appIDs = []; var ignored: [String: String] = [:]
            try reader.object(strings: nil, path: [], depth: 0, fields: &ignored)
            if packageIDs.contains(id) { result[id] = Set(reader.appIDs) }
        }
        throw Reader.bad
    }

    private struct Reader {
        static var bad: PlaydockError { .message("Steam's metadata cache is incomplete. Let Steam finish loading and refresh the library.") }
        let data: Data
        var cursor = 0
        var limit: Int
        var nodes = 0
        var appIDs: [UInt32] = []
        mutating func skip(_ count: Int) throws {
            guard count >= 0, cursor <= limit - count else { throw Self.bad }; cursor += count
        }
        mutating func u8() throws -> UInt8 { guard cursor < limit else { throw Self.bad }; defer { cursor += 1 }; return data[cursor] }
        mutating func u32() throws -> UInt32 { try number(4) }
        mutating func u64() throws -> UInt64 { try number(8) }
        mutating func number<T: FixedWidthInteger>(_ bytes: Int) throws -> T {
            guard cursor <= limit - bytes else { throw Self.bad }
            var value: T = 0
            for i in 0..<bytes { value |= T(data[cursor+i]) << (i*8) }
            cursor += bytes; return value
        }
        mutating func text() throws -> String {
            let start = cursor
            while cursor < limit && data[cursor] != 0 && cursor - start <= 65_536 { cursor += 1 }
            guard cursor < limit, data[cursor] == 0, let text = String(data: data[start..<cursor], encoding: .utf8) else { throw Self.bad }
            cursor += 1; return text
        }
        mutating func object(strings: [String]?, path: [String], depth: Int, fields: inout [String: String]) throws {
            guard depth < 64 else { throw Self.bad }
            while true {
                let tag = try u8(); if tag == 8 { return }
                nodes += 1; guard nodes < 1_000_000 else { throw Self.bad }
                let key: String
                if let strings {
                    let index = try u32(); guard index < strings.count else { throw Self.bad }; key = strings[Int(index)]
                } else { key = try text() }
                switch tag {
                case 0: try object(strings: strings, path: path + [key], depth: depth+1, fields: &fields)
                case 1:
                    let value = try text()
                    if path.last == "appids", let id = UInt32(value), id > 0 { appIDs.append(id) }
                    if path.last == "common", ["name", "type", "oslist"].contains(key) { fields[key] = value }
                case 2:
                    let value = try u32()
                    if path.last == "appids", value > 0 { appIDs.append(value) }
                case 3, 4, 6: try skip(4)
                case 7, 10: try skip(8)
                default: throw Self.bad
                }
            }
        }
    }
}
