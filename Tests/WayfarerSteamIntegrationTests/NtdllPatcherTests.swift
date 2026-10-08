// Adapted from NotProton c3a49486; GPL-3.0. See Sources/WayfarerSteamIntegration/NOTICE.
import Foundation
import Testing

@testable import WayfarerSteamIntegration

// A stand-in PE with one file-backed section and one with nothing behind it, so the section
// walk and every refusal run without CrossOver. Deliberately not an identity mapping.
private struct StubPE {
    static let peOffset = 0x80
    static let sectionVirtualAddress = 0x1000
    static let sectionRawOffset = 0x400
    static let sectionSize = 0x4000

    // A .bss style section placed before the real one, to prove it is skipped rather
    // than matched.
    static let bssVirtualAddress = 0x200
    static let bssSize = 0x200

    static let imageSize = sectionVirtualAddress + sectionSize
    static let tableEnd = peOffset + 24 + 0xf0 + 2 * 40

    static func rva(forOffset offset: Int) -> Int {
        sectionVirtualAddress + (offset - sectionRawOffset)
    }

    static func make(machine: UInt16, magic: UInt16, imageBase: UInt64) -> Data {
        var bytes = [UInt8](repeating: 0, count: sectionRawOffset + sectionSize)

        write(&bytes, 0x3c, UInt32(peOffset))
        write(&bytes, peOffset, UInt32(0x0000_4550))
        write(&bytes, peOffset + 4, machine)

        let optionalSize: UInt16 = 0xf0
        write(&bytes, peOffset + 6, UInt16(2))
        write(&bytes, peOffset + 20, optionalSize)
        write(&bytes, peOffset + 24, magic)

        write(&bytes, peOffset + 24 + 36, UInt32(0x200))
        write(&bytes, peOffset + 24 + 56, UInt32(imageSize))
        write(&bytes, peOffset + 24 + 60, UInt32(sectionRawOffset))

        if magic == 0x20b {
            write(&bytes, peOffset + 24 + 24, imageBase)
        } else {
            write(&bytes, peOffset + 24 + 28, UInt32(truncatingIfNeeded: imageBase))
        }

        let table = peOffset + 24 + Int(optionalSize)
        write(&bytes, table + 8, UInt32(bssSize))
        write(&bytes, table + 12, UInt32(bssVirtualAddress))
        write(&bytes, table + 16, UInt32(0))
        write(&bytes, table + 20, UInt32(0))

        write(&bytes, table + 40 + 8, UInt32(sectionSize))
        write(&bytes, table + 40 + 12, UInt32(sectionVirtualAddress))
        write(&bytes, table + 40 + 16, UInt32(sectionSize))
        write(&bytes, table + 40 + 20, UInt32(sectionRawOffset))

        return Data(bytes)
    }

    private static func write<T: FixedWidthInteger>(_ bytes: inout [UInt8], _ offset: Int, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { raw in
            for (index, byte) in raw.enumerated() { bytes[offset + index] = byte }
        }
    }
}

@Suite("ntdll patcher")
struct NtdllPatcherTests {

    private let stolen: [UInt8] = [0x48, 0x83, 0xbc, 0x24, 0xf0, 0x00, 0x00, 0x00, 0x00]

    private func stubPatch(caveSize: Int = 0x100, cavePad: UInt8 = 0) -> NtdllPatch {
        NtdllPatch(
            arch: .x86_64Windows,
            payloadResource: "detour2",
            payloadSHA256: "unused",
            caveRVA: StubPE.rva(forOffset: StubPE.sectionRawOffset + 0x800),
            payloadRVA: StubPE.rva(forOffset: StubPE.sectionRawOffset + 0x800),
            hooks: [
                NtdllHook(rva: StubPE.rva(forOffset: StubPE.sectionRawOffset + 0x100), stolen: stolen)
            ],
            caveSize: caveSize,
            cavePad: cavePad,
            machine: 0x8664,
            magic: 0x20b,
            imageBase: 0x1_7000_0000
        )
    }

    private func stubImage() -> Data {
        var bytes = [UInt8](StubPE.make(machine: 0x8664, magic: 0x20b, imageBase: 0x1_7000_0000))
        let hookOffset = StubPE.sectionRawOffset + 0x100
        for (index, byte) in stolen.enumerated() { bytes[hookOffset + index] = byte }
        return Data(bytes)
    }

    // MARK: - The patch itself

    @Test("A patch writes the detour into the cave and a reachable jump at the hook")
    func patchWritesBothSites() throws {
        let patch = stubPatch()
        let payload = Data([0x90, 0x91, 0x92, 0x93])
        let result = [UInt8](try NtdllPatcher.apply(patch, to: stubImage(), payload: payload))

        let caveOffset = StubPE.sectionRawOffset + 0x800
        #expect(Array(result[caveOffset ..< caveOffset + 4]) == [0x90, 0x91, 0x92, 0x93])

        let hookOffset = StubPE.sectionRawOffset + 0x100
        #expect(result[hookOffset] == 0xe9)

        let displacement = result[(hookOffset + 1) ..< (hookOffset + 5)]
            .reversed()
            .reduce(Int32(0)) { $0 << 8 | Int32($1) }
        #expect(Int(displacement) == patch.payloadRVA - (patch.hooks[0].rva + 5))

        // The stolen bytes past the jump are int3, not left as the tail of the
        // instruction that was overwritten.
        #expect(Array(result[(hookOffset + 5) ..< (hookOffset + stolen.count)]) == [0xcc, 0xcc, 0xcc, 0xcc])
    }

    @Test("A padding cave keeps the file length, because a PE cannot absorb inserted bytes")
    func patchDoesNotResize() throws {
        let patch = stubPatch()
        let image = stubImage()
        let result = try NtdllPatcher.apply(patch, to: image, payload: Data(repeating: 0x90, count: 64))
        #expect(result.count == image.count)
    }

    private func sectionPatch() -> NtdllPatch {
        let base = stubPatch()
        return NtdllPatch(
            arch: base.arch, payloadResource: base.payloadResource, payloadSHA256: base.payloadSHA256,
            caveRVA: StubPE.imageSize, payloadRVA: StubPE.imageSize, hooks: base.hooks,
            caveSize: 0x1000, cavePad: 0, machine: base.machine, magic: base.magic,
            imageBase: base.imageBase, placement: .section
        )
    }

    private func u32(_ bytes: [UInt8], _ offset: Int) -> Int {
        bytes[offset ..< offset + 4].reversed().reduce(0) { $0 << 8 | Int($1) }
    }

    @Test("A section cave appends one executable page and jumps into it")
    func sectionPlacementAppendsPage() throws {
        let patch = sectionPatch()
        let image = stubImage()
        let payload = Data([0x90, 0x91, 0x92, 0x93])
        let result = [UInt8](try NtdllPatcher.apply(patch, to: image, payload: payload))

        #expect(result.count == image.count + 0x1000)
        #expect(result[StubPE.peOffset + 6] == 3)
        #expect(u32(result, StubPE.peOffset + 24 + 56) == StubPE.imageSize + 0x1000)

        let header = StubPE.tableEnd
        #expect(Array(result[header ..< header + 8]) == Array(".npdet".utf8) + [0, 0])
        #expect(u32(result, header + 8) == 0x1000)
        #expect(u32(result, header + 12) == StubPE.imageSize)
        #expect(u32(result, header + 16) == 0x1000)
        #expect(u32(result, header + 20) == image.count)
        #expect(u32(result, header + 36) == 0x6000_0020)
        #expect(Array(result[image.count ..< image.count + 4]) == [0x90, 0x91, 0x92, 0x93])

        let hookOffset = StubPE.sectionRawOffset + 0x100
        #expect(result[hookOffset] == 0xe9)
        #expect(Int(Int32(truncatingIfNeeded: u32(result, hookOffset + 1)))
            == patch.payloadRVA - (patch.hooks[0].rva + 5))
    }

    @Test("A section cave pinned somewhere other than the image end is refused")
    func sectionPlacementNeedsImageEnd() throws {
        let base = sectionPatch()
        let moved = NtdllPatch(
            arch: base.arch, payloadResource: base.payloadResource, payloadSHA256: base.payloadSHA256,
            caveRVA: base.caveRVA + 0x1000, payloadRVA: base.caveRVA + 0x1000, hooks: base.hooks,
            caveSize: base.caveSize, cavePad: 0, machine: base.machine, magic: base.magic,
            imageBase: base.imageBase, placement: .section
        )
        #expect(throws: StepFailure.self) {
            try NtdllPatcher.apply(moved, to: stubImage(), payload: Data([0x90]))
        }
    }

    @Test("A section cave with no free header slot is refused, so a second patch cannot stack")
    func sectionPlacementNeedsFreeHeader() throws {
        var bytes = [UInt8](stubImage())
        bytes[StubPE.tableEnd] = 0x2e
        #expect(throws: StepFailure.self) {
            try NtdllPatcher.apply(sectionPatch(), to: Data(bytes), payload: Data([0x90]))
        }
    }

    // MARK: - Refusals

    @Test("A hook site holding something else is refused")
    func wrongStolenBytesRefused() throws {
        let patch = stubPatch()
        var bytes = [UInt8](stubImage())
        bytes[StubPE.sectionRawOffset + 0x100] = 0x90

        #expect(throws: StepFailure.self) {
            try NtdllPatcher.apply(patch, to: Data(bytes), payload: Data([0x90]))
        }
    }

    @Test("A cave with anything in it is refused, so a second patch cannot stack")
    func occupiedCaveRefused() throws {
        let patch = stubPatch()
        let payload = Data(repeating: 0x90, count: 32)
        let once = try NtdllPatcher.apply(patch, to: stubImage(), payload: payload)

        #expect(throws: StepFailure.self) {
            try NtdllPatcher.apply(patch, to: once, payload: payload)
        }
    }

    @Test("A detour larger than the cave is refused rather than overrunning it")
    func oversizePayloadRefused() throws {
        let patch = stubPatch(caveSize: 16)
        #expect(throws: StepFailure.self) {
            try NtdllPatcher.apply(patch, to: stubImage(), payload: Data(repeating: 0x90, count: 17))
        }
    }

    @Test("A mismatched machine, optional header or image base is refused")
    func headerMismatchRefused() throws {
        let patch = stubPatch()
        let payload = Data([0x90])

        let wrongMachine = StubPE.make(machine: 0x14c, magic: 0x20b, imageBase: 0x1_7000_0000)
        #expect(throws: StepFailure.self) { try NtdllPatcher.apply(patch, to: wrongMachine, payload: payload) }

        let wrongMagic = StubPE.make(machine: 0x8664, magic: 0x10b, imageBase: 0x1_7000_0000)
        #expect(throws: StepFailure.self) { try NtdllPatcher.apply(patch, to: wrongMagic, payload: payload) }

        let wrongBase = StubPE.make(machine: 0x8664, magic: 0x20b, imageBase: 0x1_8000_0000)
        #expect(throws: StepFailure.self) { try NtdllPatcher.apply(patch, to: wrongBase, payload: payload) }
    }

    @Test("A truncated file is refused instead of read past its end")
    func truncatedFileRefused() throws {
        let patch = stubPatch()
        let image = stubImage().prefix(StubPE.sectionRawOffset)

        #expect(throws: StepFailure.self) {
            try NtdllPatcher.apply(patch, to: Data(image), payload: Data([0x90]))
        }
    }

    // The size check on its own read an address below the cave as extra room rather than as
    // being outside it, so the detour was written into the code in front of the cave.
    @Test("A detour addressed below its cave is refused")
    func detourBelowItsCaveRefused() throws {
        let base = stubPatch()
        let below = NtdllPatch(
            arch: base.arch, payloadResource: base.payloadResource, payloadSHA256: base.payloadSHA256,
            caveRVA: base.caveRVA, payloadRVA: base.caveRVA - 0x100, hooks: base.hooks,
            caveSize: base.caveSize, cavePad: base.cavePad, machine: base.machine,
            magic: base.magic, imageBase: base.imageBase
        )

        #expect(throws: StepFailure.self) {
            try NtdllPatcher.apply(below, to: stubImage(), payload: Data(repeating: 0x90, count: 0x10))
        }
    }

    @Test("An RVA in no mapped section is refused, including one inside an unbacked section")
    func unmappedRVARefused() throws {
        let base = stubPatch()
        let payload = Data([0x90])

        let beyond = NtdllPatch(
            arch: base.arch, payloadResource: base.payloadResource, payloadSHA256: base.payloadSHA256,
            caveRVA: 0x9000_0000, payloadRVA: 0x9000_0000, hooks: base.hooks, caveSize: base.caveSize,
            cavePad: base.cavePad, machine: base.machine, magic: base.magic, imageBase: base.imageBase
        )
        #expect(throws: StepFailure.self) {
            try NtdllPatcher.apply(beyond, to: stubImage(), payload: payload)
        }

        // Inside the .bss style section, which has no file offset to resolve to.
        let unbacked = NtdllPatch(
            arch: base.arch, payloadResource: base.payloadResource, payloadSHA256: base.payloadSHA256,
            caveRVA: StubPE.bssVirtualAddress + 0x10, payloadRVA: StubPE.bssVirtualAddress + 0x10,
            hooks: base.hooks,
            caveSize: base.caveSize, cavePad: base.cavePad, machine: base.machine, magic: base.magic,
            imageBase: base.imageBase
        )
        #expect(throws: StepFailure.self) {
            try NtdllPatcher.apply(unbacked, to: stubImage(), payload: payload)
        }
    }

}
