import Foundation
import Testing
@testable import Kiln

struct REDeviceBenchFormattingTests {
    @Test func addressParsingAcceptsHexWithOrWithoutPrefix() {
        #expect(REHexFormat.parseAddress("0x1000") == 0x1000)
        #expect(REHexFormat.parseAddress("  ff ") == 0xff)
        #expect(REHexFormat.parseAddress("0XDEADBEEF") == 0xdeadbeef)
    }

    @Test func addressParsingRejectsNonHex() {
        #expect(REHexFormat.parseAddress("") == nil)
        #expect(REHexFormat.parseAddress("0x") == nil)
        #expect(REHexFormat.parseAddress("zz") == nil)
        #expect(REHexFormat.parseAddress("12 34") == nil)
    }

    @Test func hexDumpFormatsOffsetsHexAndAsciiPerSixteenBytes() {
        let bytes = Array("Hello, Kiln!!!!!ab".utf8) // 18 bytes: one full row plus two
        let lines = REHexFormat.hexDump(bytes, base: 0x1000).split(separator: "\n").map(String.init)

        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("0x00001000  48 65 6c 6c 6f 2c 20 4b"))
        #expect(lines[0].hasSuffix("Hello, Kiln!!!!!"))
        #expect(lines[1].hasPrefix("0x00001010  61 62"))
        #expect(lines[1].hasSuffix("ab"))
    }

    @Test func hexDumpMasksNonPrintableBytes() {
        let dump = REHexFormat.hexDump([0x00, 0x41, 0xff], base: nil)
        #expect(dump.hasSuffix(".A."))
    }

    @Test func hexDumpOfNothingSaysSo() {
        #expect(REHexFormat.hexDump([], base: nil) == "(empty)")
    }
}
