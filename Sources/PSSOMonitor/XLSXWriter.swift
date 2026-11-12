import Foundation

/// Minimal .xlsx writer: text cells, a few fills, frozen header row, filters. Zipped with /usr/bin/zip.
enum XLSXWriter {
    enum Style: Int { case plain = 0, header = 1, pass = 2, fail = 3, wrap = 4, bold = 5, neutral = 6 }

    struct Cell {
        let text: String
        let style: Style
        init(_ text: String, _ style: Style = .plain) { self.text = text; self.style = style }
    }

    struct Sheet {
        let name: String
        let widths: [Double]
        let rows: [[Cell]]
        var hasHeader = true
    }

    enum WriteError: LocalizedError {
        case zipFailed(String)
        var errorDescription: String? {
            switch self { case .zipFailed(let m): return "Could not create the Excel file: \(m)" }
        }
    }

    static func write(_ sheets: [Sheet], to url: URL) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("psso-xlsx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        for sub in ["_rels", "xl/_rels", "xl/worksheets"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        func put(_ path: String, _ s: String) throws {
            try s.write(to: dir.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        let ns = "http://schemas.openxmlformats.org"

        try put("[Content_Types].xml", xml + """
        <Types xmlns="\(ns)/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        \(sheets.indices.map { #"<Override PartName="/xl/worksheets/sheet\#($0 + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"# }.joined(separator: "\n"))
        </Types>
        """)
        try put("_rels/.rels", xml + """
        <Relationships xmlns="\(ns)/package/2006/relationships">
        <Relationship Id="rId1" Type="\(ns)/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """)
        try put("xl/workbook.xml", xml + """
        <workbook xmlns="\(ns)/spreadsheetml/2006/main" xmlns:r="\(ns)/officeDocument/2006/relationships">
        <sheets>
        \(sheets.enumerated().map { #"<sheet name="\#(esc($1.name))" sheetId="\#($0 + 1)" r:id="rId\#($0 + 1)"/>"# }.joined(separator: "\n"))
        </sheets>
        </workbook>
        """)
        try put("xl/_rels/workbook.xml.rels", xml + """
        <Relationships xmlns="\(ns)/package/2006/relationships">
        \(sheets.indices.map { #"<Relationship Id="rId\#($0 + 1)" Type="\#(ns)/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#($0 + 1).xml"/>"# }.joined(separator: "\n"))
        <Relationship Id="rId\(sheets.count + 1)" Type="\(ns)/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """)
        try put("xl/styles.xml", xml + """
        <styleSheet xmlns="\(ns)/spreadsheetml/2006/main">
        <fonts count="3">
        <font><sz val="11"/><name val="Calibri"/></font>
        <font><b/><sz val="11"/><name val="Calibri"/></font>
        <font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font>
        </fonts>
        <fills count="6">
        <fill><patternFill patternType="none"/></fill>
        <fill><patternFill patternType="gray125"/></fill>
        <fill><patternFill patternType="solid"><fgColor rgb="FF1F2937"/></patternFill></fill>
        <fill><patternFill patternType="solid"><fgColor rgb="FFC6EFCE"/></patternFill></fill>
        <fill><patternFill patternType="solid"><fgColor rgb="FFFFC7CE"/></patternFill></fill>
        <fill><patternFill patternType="solid"><fgColor rgb="FFEDEDED"/></patternFill></fill>
        </fills>
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        <cellXfs count="7">
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top"/></xf>
        <xf numFmtId="0" fontId="2" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
        <xf numFmtId="0" fontId="1" fillId="3" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment vertical="top"/></xf>
        <xf numFmtId="0" fontId="1" fillId="4" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment vertical="top"/></xf>
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
        <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
        <xf numFmtId="0" fontId="1" fillId="5" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment vertical="top"/></xf>
        </cellXfs>
        </styleSheet>
        """)

        for (i, sheet) in sheets.enumerated() {
            var s = xml + #"<worksheet xmlns="\#(ns)/spreadsheetml/2006/main">"#
            if sheet.hasHeader {
                s += #"<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>"#
            }
            s += "<cols>" + sheet.widths.enumerated().map {
                #"<col min="\#($0 + 1)" max="\#($0 + 1)" width="\#($1)" customWidth="1"/>"#
            }.joined() + "</cols><sheetData>"
            for (r, row) in sheet.rows.enumerated() {
                s += #"<row r="\#(r + 1)">"#
                for (c, cell) in row.enumerated() {
                    s += #"<c r="\#(col(c))\#(r + 1)" s="\#(cell.style.rawValue)" t="inlineStr"><is><t xml:space="preserve">\#(esc(cell.text))</t></is></c>"#
                }
                s += "</row>\n"
            }
            s += "</sheetData>"
            if sheet.hasHeader, let first = sheet.rows.first, sheet.rows.count > 1 {
                s += #"<autoFilter ref="A1:\#(col(first.count - 1))\#(sheet.rows.count)"/>"#
            }
            s += "</worksheet>"
            try put("xl/worksheets/sheet\(i + 1).xml", s)
        }

        try? fm.removeItem(at: url)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = dir
        zip.arguments = ["-q", "-r", "-X", "-D", url.path, "[Content_Types].xml", "_rels", "xl"]
        let err = Pipe()
        zip.standardError = err
        zip.standardOutput = err
        try zip.run()
        zip.waitUntilExit()
        if zip.terminationStatus != 0 {
            throw WriteError.zipFailed(String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        }
    }

    private static func col(_ i: Int) -> String {
        var n = i, s = ""
        repeat { s = String(UnicodeScalar(UInt8(65 + n % 26))) + s; n = n / 26 - 1 } while n >= 0
        return s
    }

    /// XML-escapes and drops characters Excel rejects; caps at Excel's cell limit.
    private static func esc(_ text: String) -> String {
        var out = ""
        for u in text.unicodeScalars.prefix(32_000) {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                let v = u.value
                if v == 9 || v == 10 || v == 13 || (v >= 0x20 && v != 0xFFFE && v != 0xFFFF) { out.unicodeScalars.append(u) }
            }
        }
        return out
    }
}
