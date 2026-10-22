import Foundation

let scholarVersion = "0.1.0"

let scholarHelp = """
Usage:
  scholar search <query> [options]
  scholar --help
  scholar --version

Search options:
  --limit <1-20>          Maximum results to return (default: 10)
  --format, -f <format>   Output: table, json, or csv (default: table)
  --json                  Shortcut for --format json
  --lang <code>           Scholar language code (default: en)
  --timeout <ms>          Total deadline in milliseconds (default: 30000)
  --headed                Show the browser window for manual verification
  --                      Stop option parsing

No browser setup, package manager, API key, or language runtime is required.
Each invocation uses an ephemeral WebKit session. Hidden mode is the default;
headed mode shows only the window owned by this invocation.

Exit codes:
  0    Success
  2    Invalid arguments
  3    Local browser or session failure
  4    Service or network failure
  5    Unreadable page
  130  Interrupted
"""

func parseArguments(_ args: [String]) throws -> CLIAction {
    guard let command = args.first else {
        throw argumentFailure("Missing command. Run scholar --help for usage.")
    }

    if args.count == 1 {
        switch command {
        case "--help", "-h":
            return .help
        case "--version", "-V":
            return .version
        default:
            break
        }
    }

    guard command == "search" else {
        throw argumentFailure("Unknown command '\(command)'. Run scholar --help for usage.")
    }

    var query: String?
    var limit = 10
    var format = OutputFormat.table
    var language = "en"
    var timeoutMilliseconds = 30_000
    var headed = false
    var jsonShortcut = false
    var explicitFormat: OutputFormat?
    var optionsEnded = false
    var index = 1

    while index < args.count {
        let argument = args[index]

        if !optionsEnded, argument == "--" {
            optionsEnded = true
            index += 1
            continue
        }

        if !optionsEnded {
            switch argument {
            case "--help", "-h":
                return .help
            case "--version", "-V":
                return .version
            case "--json":
                jsonShortcut = true
                format = .json
                index += 1
                continue
            case "--headed":
                headed = true
                index += 1
                continue
            case "--limit":
                let value = try optionValue(args, at: &index, name: "--limit")
                limit = try parseLimit(value)
                continue
            case "--format", "-f":
                let value = try optionValue(args, at: &index, name: argument)
                let parsedFormat = try parseFormat(value)
                explicitFormat = parsedFormat
                format = parsedFormat
                continue
            case "--lang":
                language = try optionValue(args, at: &index, name: "--lang")
                continue
            case "--timeout":
                let value = try optionValue(args, at: &index, name: "--timeout")
                timeoutMilliseconds = try parseTimeout(value)
                continue
            default:
                if let value = attachedValue(argument, option: "--limit") {
                    limit = try parseLimit(value)
                    index += 1
                    continue
                }
                if let value = attachedValue(argument, option: "--format") {
                    let parsedFormat = try parseFormat(value)
                    explicitFormat = parsedFormat
                    format = parsedFormat
                    index += 1
                    continue
                }
                if let value = attachedValue(argument, option: "--lang") {
                    language = value
                    index += 1
                    continue
                }
                if let value = attachedValue(argument, option: "--timeout") {
                    timeoutMilliseconds = try parseTimeout(value)
                    index += 1
                    continue
                }
                if argument.hasPrefix("-") {
                    throw argumentFailure("Unknown option '\(argument)'.")
                }
            }
        }

        guard query == nil else {
            throw argumentFailure("Search accepts one quoted query argument.")
        }
        query = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        index += 1
    }

    guard let query, !query.isEmpty else {
        throw argumentFailure("Search query must not be blank.")
    }
    if jsonShortcut, let explicitFormat, explicitFormat != .json {
        throw argumentFailure("--json cannot be combined with a non-JSON --format value.")
    }
    let options = SearchOptions(
        query: query,
        limit: limit,
        format: format,
        lang: language,
        timeout: TimeInterval(timeoutMilliseconds) / 1_000,
        headed: headed
    )
    try options.validate()
    return .search(options)
}

private func argumentFailure(_ message: String) -> ScholarFailure {
    ScholarFailure(message: message, exitCode: 2)
}

private func attachedValue(_ argument: String, option: String) -> String? {
    let prefix = option + "="
    guard argument.hasPrefix(prefix) else {
        return nil
    }
    return String(argument.dropFirst(prefix.count))
}

private func optionValue(
    _ arguments: [String],
    at index: inout Int,
    name: String
) throws -> String {
    let valueIndex = index + 1
    guard valueIndex < arguments.count else {
        throw argumentFailure("Option \(name) requires a value.")
    }
    index += 2
    return arguments[valueIndex]
}

private func parseLimit(_ value: String) throws -> Int {
    guard let limit = Int(value), (1...20).contains(limit) else {
        throw argumentFailure("Limit must be an integer from 1 through 20.")
    }
    return limit
}

private func parseFormat(_ value: String) throws -> OutputFormat {
    guard let format = OutputFormat(rawValue: value) else {
        throw argumentFailure("Format must be table, json, or csv.")
    }
    return format
}

private func parseTimeout(_ value: String) throws -> Int {
    guard let timeout = Int(value),
          timeout > 0,
          timeout <= Int32.max else {
        throw argumentFailure(
            "Timeout must be a positive integer of at most \(Int32.max) milliseconds."
        )
    }
    return timeout
}
