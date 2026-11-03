import ArgumentParser
import CadenceCore
import Foundation

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config", abstract: "Read and change settings.",
        subcommands: [ConfigGet.self, ConfigSet.self, ConfigPath.self])
}

struct ConfigPath: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "path", abstract: "Print where config.json lives.")

    @OptionGroup var output: OutputOptions

    func run() throws {
        try output.run { context in
            Rendered(human: context.roots.config.path, json: ["path": .string(context.roots.config.path)])
        }
    }
}

struct ConfigGet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Print one setting, such as tickets.titleWindow.")

    @OptionGroup var output: OutputOptions
    @Argument(help: "A dotted path.") var path: String

    func run() throws {
        try output.run { context in
            let value = try context.loadConfig().config.value(at: path)
            let human: String
            if let text = value.stringValue { human = text } else { human = try OutputOptions.canonical(value) }
            return Rendered(human: human, json: ["path": .string(path), "value": value])
        }
    }
}

struct ConfigSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Change one setting and save config.json with mode 0600.")

    @OptionGroup var output: OutputOptions
    @Argument(help: "A dotted path.") var path: String
    @Argument(help: "A JSON value, or a bare word for a string.") var value: String

    func run() throws {
        try output.run { context in
            let current = try context.loadConfig().config
            let updated = try current.setting(path, to: value)
            try ConfigStore.save(updated, to: context.roots.config)
            // The ticket rules decide how entries are classified, so a change to them is recorded as digests.
            if updated.tickets.pattern != current.tickets.pattern
                || updated.tickets.selfInitiated != current.tickets.selfInitiated
            {
                try context.openJournal().recordClassifier(actor: .cli)
            }
            let stored = try updated.value(at: path)
            let shown = try stored.stringValue ?? OutputOptions.canonical(stored)
            let human = "Set \(path) to \(shown)"
            return Rendered(human: human, json: ["path": .string(path), "value": stored])
        }
    }
}
