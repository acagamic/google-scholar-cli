import Foundation

func formatRows(_ rows: [ScholarRow], as format: OutputFormat) throws -> Data {
    switch format {
    case .json:
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(rows)
        data.append(0x0A)
        return data
    case .csv:
        return Data(csv(rows).utf8)
    case .table:
        return Data(table(rows).utf8)
    }
}

private func csv(_ rows: [ScholarRow]) -> String {
    var lines = ["rank,title,authors,source,year,cited,url"]
    lines.append(contentsOf: rows.map { row in
        [
            String(row.rank),
            row.title,
            row.authors,
            row.source,
            row.year,
            row.cited,
            row.url,
        ].map(csvField).joined(separator: ",")
    })
    return lines.joined(separator: "\n") + "\n"
}

private func csvField(_ value: String) -> String {
    guard value.contains(",")
            || value.contains("\"")
            || value.contains("\n")
            || value.contains("\r") else {
        return value
    }
    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

private func table(_ rows: [ScholarRow]) -> String {
    let headings = ["Rank", "Title", "Authors", "Source", "Year", "Cited", "URL"]
    let body = rows.map { row in
        [
            String(row.rank),
            cleanTableCell(row.title),
            cleanTableCell(row.authors),
            cleanTableCell(row.source),
            cleanTableCell(row.year),
            cleanTableCell(row.cited),
            cleanTableCell(row.url),
        ]
    }
    let allRows = [headings] + body
    let widths = headings.indices.map { column in
        allRows.map { $0[column].count }.max() ?? headings[column].count
    }
    let lines = allRows.map { fields in
        fields.enumerated().map { column, field in
            guard column < fields.count - 1 else {
                return field
            }
            return field + String(repeating: " ", count: widths[column] - field.count)
        }.joined(separator: "  ")
    }
    return lines.joined(separator: "\n") + "\n"
}

private func cleanTableCell(_ value: String) -> String {
    let scalars = Array(value.unicodeScalars)
    var visible = String.UnicodeScalarView()
    var index = 0

    while index < scalars.count {
        let scalar = scalars[index].value
        if scalar == 0x1B {
            index = consumeEscapeSequence(in: scalars, after: index)
            continue
        }
        if scalar <= 0x1F || scalar == 0x7F || (0x80...0x9F).contains(scalar) {
            visible.append(" ")
            index += 1
            continue
        }
        visible.append(scalars[index])
        index += 1
    }

    return String(visible).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func consumeEscapeSequence(
    in scalars: [Unicode.Scalar],
    after escapeIndex: Int
) -> Int {
    var index = escapeIndex + 1
    guard index < scalars.count else {
        return index
    }

    let introducer = scalars[index].value
    if introducer == 0x5B {
        index += 1
        while index < scalars.count {
            let value = scalars[index].value
            index += 1
            if (0x40...0x7E).contains(value) {
                break
            }
        }
        return index
    }

    if introducer == 0x5D || introducer == 0x50
        || introducer == 0x58 || introducer == 0x5E || introducer == 0x5F {
        index += 1
        while index < scalars.count {
            if scalars[index].value == 0x07 {
                return index + 1
            }
            if scalars[index].value == 0x1B,
               index + 1 < scalars.count,
               scalars[index + 1].value == 0x5C {
                return index + 2
            }
            index += 1
        }
        return index
    }

    return index + 1
}
