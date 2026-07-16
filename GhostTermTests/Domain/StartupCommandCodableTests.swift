import Foundation
import Testing

@testable import GhostTerm

struct StartupCommandCodableTests {
    @Test
    func shellUsesStableTaggedSchema() throws {
        let data = try JSONEncoder().encode(StartupCommand.shell)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object.count == 1)
        #expect(object["kind"] as? String == "shell")
        #expect(object["command"] == nil)
        #expect(object["_0"] == nil)
        #expect(try JSONDecoder().decode(StartupCommand.self, from: data) == .shell)
    }

    @Test
    func customUsesStableTaggedSchemaWithoutSynthesizedPayloadKeys() throws {
        let command = "printf '猫 Привет'"
        let data = try JSONEncoder().encode(StartupCommand.custom(command))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object.count == 2)
        #expect(object["kind"] as? String == "custom")
        #expect(object["command"] as? String == command)
        #expect(object["_0"] == nil)
        #expect(try JSONDecoder().decode(StartupCommand.self, from: data) == .custom(command))
    }

    @Test(arguments: [
        "{\"kind\":\"future\"}",
        "{\"kind\":\"custom\"}",
        "{\"kind\":\"custom\",\"command\":null}",
    ])
    func malformedTaggedSchemaIsRejected(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(StartupCommand.self, from: Data(json.utf8))
        }
    }

    @Test
    func decoderIgnoresUnknownFields() throws {
        let data = Data("{\"kind\":\"shell\",\"future\":true}".utf8)

        let decoded = try JSONDecoder().decode(StartupCommand.self, from: data)

        #expect(decoded == .shell)
    }
}
