enum StartupCommand: Codable, Equatable, Sendable {
    case shell
    case custom(String)

    private enum Kind: String, Codable {
        case shell
        case custom
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case command
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .shell:
            self = .shell
        case .custom:
            self = .custom(try container.decode(String.self, forKey: .command))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .shell:
            try container.encode(Kind.shell, forKey: .kind)
        case .custom(let command):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(command, forKey: .command)
        }
    }
}
