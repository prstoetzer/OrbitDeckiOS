import Foundation

struct XLSXSheet: Sendable {
    enum Cell: Sendable {
        case text(String)
        case number(Double)
        case integer(Int)
    }

    let name: String
    let rows: [[Cell]]

    init(name: String, rows: [[Cell]]) {
        self.name = name
        self.rows = rows
    }
}

/// Minimal dependency-free Office Open XML workbook writer.
///
/// XLSX is a ZIP container of XML parts. This writer deliberately uses ZIP's
/// "stored" method (no compression), which keeps the implementation small and
/// deterministic while remaining a normal .xlsx file readable by Excel,
/// Numbers, LibreOffice and other OOXML consumers.
struct XLSXExportService {
    static func workbook(sheets: [XLSXSheet]) -> Data {
        let safeSheets = sheets.isEmpty ? [XLSXSheet(name: "Sheet1", rows: [])] : sheets
        var entries: [(String, Data)] = []
        entries.append(("[Content_Types].xml", Data(contentTypes(sheetCount: safeSheets.count).utf8)))
        entries.append(("_rels/.rels", Data(rootRelationships.utf8)))
        entries.append(("docProps/core.xml", Data(coreProperties.utf8)))
        entries.append(("docProps/app.xml", Data(appProperties(sheetNames: safeSheets.map(\.name)).utf8)))
        entries.append(("xl/workbook.xml", Data(workbookXML(sheetNames: safeSheets.map(\.name)).utf8)))
        entries.append(("xl/_rels/workbook.xml.rels", Data(workbookRelationships(sheetCount: safeSheets.count).utf8)))
        entries.append(("xl/styles.xml", Data(stylesXML.utf8)))
        for (index, sheet) in safeSheets.enumerated() {
            entries.append(("xl/worksheets/sheet\(index + 1).xml", Data(worksheetXML(sheet).utf8)))
        }
        return StoredZIP.archive(entries)
    }

    private static func contentTypes(sheetCount: Int) -> String {
        var overrides = ""
        for index in 1...sheetCount {
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(index).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        \(overrides)
        </Types>
        """
    }

    private static let rootRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
      <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
    </Relationships>
    """

    private static let coreProperties = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <dc:creator>OrbitDeck</dc:creator>
      <cp:lastModifiedBy>OrbitDeck</cp:lastModifiedBy>
      <dc:title>OrbitDeck export</dc:title>
      <dc:subject>Amateur satellite operating data</dc:subject>
    </cp:coreProperties>
    """

    private static func appProperties(sheetNames: [String]) -> String {
        let titles = sheetNames.map { "<vt:lpstr>\(xmlEscape($0))</vt:lpstr>" }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
          <Application>OrbitDeck iOS</Application>
          <HeadingPairs><vt:vector size="2" baseType="variant"><vt:variant><vt:lpstr>Worksheets</vt:lpstr></vt:variant><vt:variant><vt:i4>\(sheetNames.count)</vt:i4></vt:variant></vt:vector></HeadingPairs>
          <TitlesOfParts><vt:vector size="\(sheetNames.count)" baseType="lpstr">\(titles)</vt:vector></TitlesOfParts>
        </Properties>
        """
    }

    private static func workbookXML(sheetNames: [String]) -> String {
        let sheets = sheetNames.enumerated().map { index, raw in
            let name = sanitizeSheetName(raw, fallback: "Sheet\(index + 1)")
            return "<sheet name=\"\(xmlAttributeEscape(name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <bookViews><workbookView xWindow="0" yWindow="0" windowWidth="24000" windowHeight="12000"/></bookViews>
          <sheets>\(sheets)</sheets>
          <calcPr calcId="191029" fullCalcOnLoad="1"/>
        </workbook>
        """
    }

    private static func workbookRelationships(sheetCount: Int) -> String {
        var rels = ""
        for index in 1...sheetCount {
            rels += "<Relationship Id=\"rId\(index)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(index).xml\"/>"
        }
        rels += "<Relationship Id=\"rId\(sheetCount + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
        """
    }

    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <fonts count="2"><font><sz val="11"/><name val="Aptos"/></font><font><b/><sz val="11"/><name val="Aptos"/></font></fonts>
      <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
      <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
      <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
      <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>
      <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
    </styleSheet>
    """

    private static func worksheetXML(_ sheet: XLSXSheet) -> String {
        let maxColumns = sheet.rows.map(\.count).max() ?? 1
        var rowsXML = ""
        for (rowIndex, row) in sheet.rows.enumerated() {
            let r = rowIndex + 1
            var cells = ""
            for (columnIndex, cell) in row.enumerated() {
                let ref = "\(columnName(columnIndex + 1))\(r)"
                let style = rowIndex == 0 ? " s=\"1\"" : ""
                switch cell {
                case .text(let value):
                    cells += "<c r=\"\(ref)\" t=\"inlineStr\"\(style)><is><t xml:space=\"preserve\">\(xmlEscape(value))</t></is></c>"
                case .number(let value):
                    let safe = value.isFinite ? String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value) : "0"
                    cells += "<c r=\"\(ref)\"\(style)><v>\(safe)</v></c>"
                case .integer(let value):
                    cells += "<c r=\"\(ref)\"\(style)><v>\(value)</v></c>"
                }
            }
            rowsXML += "<row r=\"\(r)\">\(cells)</row>"
        }
        let endRef = "\(columnName(maxColumns))\(max(sheet.rows.count, 1))"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <dimension ref="A1:\(endRef)"/>
          <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>
          <sheetFormatPr defaultRowHeight="15"/>
          <sheetData>\(rowsXML)</sheetData>
          <autoFilter ref="A1:\(columnName(maxColumns))1"/>
        </worksheet>
        """
    }

    private static func columnName(_ oneBased: Int) -> String {
        var n = max(1, oneBased)
        var out = ""
        while n > 0 {
            n -= 1
            out = String(UnicodeScalar(65 + (n % 26))!) + out
            n /= 26
        }
        return out
    }

    private static func sanitizeSheetName(_ value: String, fallback: String) -> String {
        let forbidden = CharacterSet(charactersIn: "[]:*?/\\")
        let scalars = value.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined()
        let trimmed = scalars.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        let chosen = trimmed.isEmpty ? fallback : trimmed
        return String(chosen.prefix(31))
    }

    private static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func xmlAttributeEscape(_ value: String) -> String {
        xmlEscape(value).replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private struct StoredZIP {
    private struct Entry {
        let name: Data
        let data: Data
        let crc: UInt32
        let offset: UInt32
    }

    static func archive(_ files: [(String, Data)]) -> Data {
        var output = Data()
        var records: [Entry] = []
        for (nameString, payload) in files {
            let name = Data(nameString.utf8)
            let crc = crc32(payload)
            let offset = UInt32(output.count)
            output.appendLE(UInt32(0x04034b50))
            output.appendLE(UInt16(20))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0)) // stored, no compression
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(33)) // 1980-01-01
            output.appendLE(crc)
            output.appendLE(UInt32(payload.count))
            output.appendLE(UInt32(payload.count))
            output.appendLE(UInt16(name.count))
            output.appendLE(UInt16(0))
            output.append(name)
            output.append(payload)
            records.append(.init(name: name, data: payload, crc: crc, offset: offset))
        }

        let centralStart = UInt32(output.count)
        for record in records {
            output.appendLE(UInt32(0x02014b50))
            output.appendLE(UInt16(20))
            output.appendLE(UInt16(20))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(33))
            output.appendLE(record.crc)
            output.appendLE(UInt32(record.data.count))
            output.appendLE(UInt32(record.data.count))
            output.appendLE(UInt16(record.name.count))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(UInt32(0))
            output.appendLE(record.offset)
            output.append(record.name)
        }
        let centralSize = UInt32(output.count) - centralStart
        output.appendLE(UInt32(0x06054b50))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(records.count))
        output.appendLE(UInt16(records.count))
        output.appendLE(centralSize)
        output.appendLE(centralStart)
        output.appendLE(UInt16(0))
        return output
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xEDB88320 & mask)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
