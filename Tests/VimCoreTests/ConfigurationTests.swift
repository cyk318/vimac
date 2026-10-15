import Testing
import Foundation
import VimCore

struct ConfigurationTests {
    @Test func testPartialConfigMergesDefaults() throws {
        let config = try Configuration.decode(Data(##"{"cursor":{"color":"#123456"},"key_mapping":{"normal":{"H":"moveLeft"}}}"##.utf8))
        #expect(config.cursor.color == "#123456")
        #expect(config.cursor.opacity == 0.55)
        #expect(config.mappings(for: .normal)["H"] == .moveLeft)
        #expect(config.mappings(for: .normal)["dd"] == .deleteLine)
        _ = try Configuration.decode(config.encoded())
    }
    @Test func testInvalidFieldsAreRejected() {
        for json in [#"{"typo":true}"#, #"{"cursor":{"width":-1}}"#,
                     #"{"cursor":{"color":"white"}}"#, #"{"toggle_key":"cmd+v"}"#,
                     #"{"key_mapping":{"normal":{"d":"moveLeft"}}}"#,
                     #"{"key_mapping":{"insert":{"a":"moveLeft"}}}"#,
                     #"{"key_mapping":{"normal":{"Esc":"insert"}}}"#] {
            #expect(throws: (any Error).self) { try Configuration.decode(Data(json.utf8)) }
        }
    }
    @Test func testPrefixTimeoutEscapeAndRepeat() {
        var parser = KeyParser()
        let map = Configuration.normalKeys
        #expect(parser.command(for: "d", time: 1, repeated: false, mappings: map) == nil)
        #expect(parser.command(for: "d", time: 1.1, repeated: true, mappings: map) == nil)
        #expect(parser.command(for: "d", time: 1.2, repeated: false, mappings: map) == .deleteLine)
        #expect(parser.command(for: "d", time: 2, repeated: false, mappings: map) == nil)
        #expect(parser.command(for: "d", time: 3, repeated: false, mappings: map) == nil)
        #expect(parser.command(for: "Esc", time: 3.1, repeated: false, mappings: map) == .normal)
        #expect(parser.command(for: "j", time: 4, repeated: true, mappings: map) == .moveDown)
        #expect(parser.command(for: "x", time: 4.1, repeated: true, mappings: map) == nil)
    }
}
