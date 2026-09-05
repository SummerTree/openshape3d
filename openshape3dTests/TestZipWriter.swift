//
//  TestZipWriter.swift
//  openshape3dTests
//
//  A minimal stored (uncompressed) zip writer for fixtures. MeshImportTests
//  keeps its own deflating variant; this one is for any test that just
//  needs "these files, in an archive".
//

import Foundation

enum ZipWriterForTests {
    static func archive(_ entries: [(String, Data)]) -> Data {
        var out = Data(); var central = Data()
        func u16(_ v: Int, into d: inout Data) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        func u32(_ v: Int, into d: inout Data) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        for (name, bytes) in entries {
            let offset = out.count
            let nameData = Data(name.utf8)
            u32(0x04034b50, into: &out); u16(20, into: &out); u16(0, into: &out); u16(0, into: &out)
            u16(0, into: &out); u16(0, into: &out); u32(0, into: &out)
            u32(bytes.count, into: &out); u32(bytes.count, into: &out)
            u16(nameData.count, into: &out); u16(0, into: &out); out.append(nameData); out.append(bytes)
            u32(0x02014b50, into: &central); u16(20, into: &central); u16(20, into: &central); u16(0, into: &central)
            u16(0, into: &central); u16(0, into: &central); u16(0, into: &central); u32(0, into: &central)
            u32(bytes.count, into: &central); u32(bytes.count, into: &central)
            u16(nameData.count, into: &central); u16(0, into: &central); u16(0, into: &central)
            u16(0, into: &central); u16(0, into: &central); u32(0, into: &central); u32(offset, into: &central)
            central.append(nameData)
        }
        let centralOffset = out.count
        out.append(central)
        u32(0x06054b50, into: &out); u16(0, into: &out); u16(0, into: &out)
        u16(entries.count, into: &out); u16(entries.count, into: &out)
        u32(central.count, into: &out); u32(centralOffset, into: &out); u16(0, into: &out)
        return out
    }
}
