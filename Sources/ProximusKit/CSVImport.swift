import Foundation

public enum PasswordCSV {
    /// RFC 4180-style quoting, including escaped quotes and embedded line breaks.
    public static func parse(_ data: Data) throws -> [VaultItem] {
        guard data.count <= VaultCrypto.maximumPayload, var text = String(data: data, encoding: .utf8) else { throw ProximusError.invalid("Import a UTF-8 CSV file smaller than 8 MiB.") }
        if text.first == "\u{feff}" { text.removeFirst() }
        var rows = [[String]](), row = [String](), field = "", quoted = false, closed = false
        let characters = Array(text)
        var i = 0
        func appendField() { row.append(field); field = ""; closed = false }
        func appendRow() throws {
            appendField()
            if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
            row = []
            guard rows.count <= 10001 else { throw ProximusError.invalid("A CSV import supports at most 10,000 passwords.") }
        }
        while i < characters.count {
            let c = characters[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < characters.count && characters[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(c) }
            } else if c == "," { appendField() }
            else if c == "\n" || c == "\r" || c == "\r\n" {
                if c == "\r", i + 1 < characters.count, characters[i + 1] == "\n" { i += 1 }
                try appendRow()
            } else if c == "\"", field.isEmpty, !closed { quoted = true }
            else {
                guard !closed, c != "\"" else { throw ProximusError.invalid("The CSV contains invalid quoting.") }
                field.append(c)
            }
            guard field.utf8.count <= 65536, row.count <= 64 else { throw ProximusError.invalid("A CSV field exceeds its size limit.") }
            i += 1
        }
        guard !quoted else { throw ProximusError.invalid("The CSV ends inside a quoted field.") }
        if !field.isEmpty || !row.isEmpty || closed { try appendRow() }
        guard let header = rows.first else { throw ProximusError.invalid("This CSV is empty.") }
        let names = header.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        guard Set(names).count == names.count else { throw ProximusError.invalid("The CSV contains duplicate column names.") }
        func index(_ aliases: [String]) -> Int? { aliases.compactMap { names.firstIndex(of: $0) }.first }
        guard let passwordIndex = index(["password", "login_password"]) else { throw ProximusError.invalid("The CSV needs a password column.") }
        let titleIndex = index(["name", "title"]), userIndex = index(["username", "login_username"]), websiteIndex = index(["url", "website", "login_uri"]), notesIndex = index(["notes", "note"])
        let otpIndex = index(["otpauth", "totp", "login_totp"])
        var items = [VaultItem]()
        for (offset, row) in rows.dropFirst().enumerated() {
            guard row.count == header.count else { throw ProximusError.invalid("CSV row \(offset + 2) has a different number of columns than the header.") }
            if let otpIndex, !row[otpIndex].isEmpty { throw ProximusError.invalid("CSV row \(offset + 2) includes a one-time-code secret. Keep that code in its existing authenticator before importing a password-only export.") }
            func value(_ index: Int?) -> String { index.map { row[$0] } ?? "" }
            let site = value(websiteIndex), title = value(titleIndex)
            let item = VaultItem(title: title.isEmpty ? (site.isEmpty ? "Imported account" : site) : title, username: value(userIndex), website: site, password: row[passwordIndex], notes: value(notesIndex))
            do { items.append(try item.validated()) } catch { throw ProximusError.invalid("CSV row \(offset + 2) contains an unsupported URL or an oversized field. \(error.localizedDescription)") }
        }
        guard !items.isEmpty else { throw ProximusError.invalid("No password rows were found.") }
        return items
    }
}
