import Foundation

enum OutputFormat: String {
    case table
    case json
    case csv
}

struct SearchOptions: Equatable {
    let query: String
    let limit: Int
    let format: OutputFormat
    let lang: String
    let timeout: TimeInterval
    let headed: Bool

    init(
        query: String,
        limit: Int = 10,
        format: OutputFormat = .table,
        lang: String = "en",
        timeout: TimeInterval = 30,
        headed: Bool = false
    ) {
        self.query = query
        self.limit = limit
        self.format = format
        self.lang = lang
        self.timeout = timeout
        self.headed = headed
    }

    var searchURL: URL {
        get throws {
            try validate()

            var components = URLComponents()
            components.scheme = "https"
            components.host = "scholar.google.com"
            components.path = "/scholar"
            components.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "num", value: String(limit)),
                URLQueryItem(name: "hl", value: lang),
            ]
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
            guard let url = components.url else {
                throw ScholarFailure(
                    message: "Could not construct a Google Scholar search URL.",
                    exitCode: 2
                )
            }
            return url
        }
    }

    func validate() throws {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScholarFailure(message: "Search query must not be blank.", exitCode: 2)
        }
        guard (1...20).contains(limit) else {
            throw ScholarFailure(message: "Limit must be an integer from 1 through 20.", exitCode: 2)
        }
        guard isValidLanguageCode(lang) else {
            throw ScholarFailure(message: "Language must be a valid language code, such as en or fr-CA.", exitCode: 2)
        }
        let maximumTimeout = TimeInterval(Int32.max) / 1_000
        guard timeout.isFinite, timeout > 0, timeout <= maximumTimeout else {
            throw ScholarFailure(
                message: "Timeout must be a positive integer of at most \(Int32.max) milliseconds.",
                exitCode: 2
            )
        }
    }
}

struct ScholarRow: Codable, Equatable {
    let rank: Int
    let title: String
    let authors: String
    let source: String
    let year: String
    let cited: String
    let url: String
}

struct PageSnapshot: Decodable {
    let state: String
    let items: [ScholarRow]
    let resultCount: Int
}

struct ScholarFailure: Error {
    let message: String
    let exitCode: Int32
}

enum CLIAction {
    case help
    case version
    case doctor
    case search(SearchOptions)
}

func isValidLanguageCode(_ value: String) -> Bool {
    value.range(
        of: #"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$"#,
        options: .regularExpression
    ) != nil
}
