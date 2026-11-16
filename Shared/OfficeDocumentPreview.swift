import AppKit
import Foundation

enum OfficeDocumentKind {
    case word
    case spreadsheet
    case presentation
    case openDocumentText
    case openDocumentSheet
    case openDocumentPresentation
    case richText

    static func detect(fileName: String) -> OfficeDocumentKind? {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "docx", "docm", "dotx", "dotm":
            return .word
        case "xlsx", "xlsm", "xltx", "xltm":
            return .spreadsheet
        case "pptx", "pptm", "potx", "potm", "ppsx", "ppsm":
            return .presentation
        case "odt", "ott", "odm":
            return .openDocumentText
        case "ods", "ots":
            return .openDocumentSheet
        case "odp", "otp":
            return .openDocumentPresentation
        case "rtf":
            return .richText
        default:
            return nil
        }
    }
}

struct OfficePreviewDocument {
    let attributedText: NSAttributedString
    let summary: String
}

enum OfficeDocumentPreview {
    static let maxPackageBytes = 48 * 1024 * 1024
    private static let maxRows = 40
    private static let maxColumns = 12
    private static let maxSheets = 4
    private static let maxSlides = 24
    private static let maxParagraphs = 400

    static func isPreviewable(fileName: String) -> Bool {
        OfficeDocumentKind.detect(fileName: fileName) != nil
    }

    static func preview(of data: Data, fileName: String) -> OfficePreviewDocument? {
        guard let kind = OfficeDocumentKind.detect(fileName: fileName) else { return nil }
        if data.count > maxPackageBytes { return nil }

        switch kind {
        case .richText:
            return richTextPreview(data)
        case .word:
            return wordPreview(data)
        case .spreadsheet:
            return spreadsheetPreview(data)
        case .presentation:
            return presentationPreview(data)
        case .openDocumentText:
            return openDocumentPreview(data, mode: .text)
        case .openDocumentSheet:
            return openDocumentPreview(data, mode: .sheet)
        case .openDocumentPresentation:
            return openDocumentPreview(data, mode: .slides)
        }
    }

    static func loadPackage(at url: URL) -> Data? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > maxPackageBytes { return nil }

        var loaded: Data?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinatorError) { readURL in
            loaded = try? Data(contentsOf: readURL)
        }
        if let loaded, loaded.count > maxPackageBytes { return nil }
        return loaded
    }

    // MARK: - Word

    private static func wordPreview(_ data: Data) -> OfficePreviewDocument? {
        guard let xml = ZipArchiveReader.extractEntry(path: "word/document.xml", from: data) else { return nil }
        let paragraphs = ParagraphXMLParser.parse(xml, limit: maxParagraphs)
        guard !paragraphs.isEmpty else { return nil }
        return OfficePreviewDocument(
            attributedText: renderParagraphs(paragraphs),
            summary: "Word document"
        )
    }

    // MARK: - PowerPoint

    private static func presentationPreview(_ data: Data) -> OfficePreviewDocument? {
        let slides = ZipArchiveReader.listEntryPaths(in: data)
            .filter { path in
                let lower = path.lowercased()
                return lower.contains("ppt/slides/slide")
                    && lower.hasSuffix(".xml")
                    && !lower.contains("/_rels/")
            }
            .sorted { slideNumber($0) < slideNumber($1) }

        guard !slides.isEmpty else { return nil }
        let result = NSMutableAttributedString()
        var shown = 0
        for path in slides.prefix(maxSlides) {
            guard let xml = ZipArchiveReader.extractEntry(path: path, from: data) else { continue }
            let paragraphs = ParagraphXMLParser.parse(xml, limit: 80)
            guard !paragraphs.isEmpty else { continue }
            shown += 1
            appendSectionTitle("Slide \(slideNumber(path))", to: result, isFirst: shown == 1)
            result.append(renderParagraphs(paragraphs))
        }
        guard result.length > 0 else { return nil }
        let extra = slides.count > maxSlides ? " · first \(maxSlides) slides" : ""
        return OfficePreviewDocument(
            attributedText: result,
            summary: "\(slides.count) slide\(slides.count == 1 ? "" : "s")\(extra)"
        )
    }

    // MARK: - Excel

    private static func spreadsheetPreview(_ data: Data) -> OfficePreviewDocument? {
        let shared = ZipArchiveReader.extractEntry(path: "xl/sharedStrings.xml", from: data)
            .map { SharedStringXMLParser.parse($0) } ?? []
        let sheets = workbookSheets(in: data)
        guard !sheets.isEmpty else { return nil }

        let result = NSMutableAttributedString()
        var shown = 0
        for sheet in sheets.prefix(maxSheets) {
            guard let xml = ZipArchiveReader.extractEntry(path: sheet.path, from: data) else { continue }
            let rows = SheetXMLParser.parse(xml, sharedStrings: shared, maxRows: maxRows, maxColumns: maxColumns)
            let visible = rows.filter { row in row.contains { !$0.isEmpty } }
            guard !visible.isEmpty else { continue }
            shown += 1
            appendSectionTitle(sheet.name, to: result, isFirst: shown == 1)
            result.append(renderTable(visible))
            if rows.count >= maxRows {
                appendNote("Showing the first \(maxRows) rows.", to: result)
            }
        }
        guard result.length > 0 else { return nil }
        let extra = sheets.count > maxSheets ? " · first \(maxSheets)" : ""
        return OfficePreviewDocument(
            attributedText: result,
            summary: "\(sheets.count) sheet\(sheets.count == 1 ? "" : "s")\(extra)"
        )
    }

    private struct WorkbookSheet {
        let name: String
        let path: String
    }

    private static func workbookSheets(in data: Data) -> [WorkbookSheet] {
        let relationships = workbookRelationships(in: data)
        if let workbook = ZipArchiveReader.extractEntry(path: "xl/workbook.xml", from: data) {
            let declared = WorkbookXMLParser.parse(workbook)
            let resolved = declared.compactMap { sheet -> WorkbookSheet? in
                guard let target = relationships[sheet.relationshipID] else { return nil }
                return WorkbookSheet(name: sheet.name, path: normalizeWorkbookTarget(target))
            }
            if !resolved.isEmpty { return resolved }
        }

        return ZipArchiveReader.listEntryPaths(in: data)
            .filter { path in
                let lower = path.lowercased()
                return lower.contains("xl/worksheets/sheet") && lower.hasSuffix(".xml")
            }
            .sorted { slideNumber($0) < slideNumber($1) }
            .map { WorkbookSheet(name: "Sheet \(slideNumber($0))", path: $0) }
    }

    private static func workbookRelationships(in data: Data) -> [String: String] {
        guard let rels = ZipArchiveReader.extractEntry(path: "xl/_rels/workbook.xml.rels", from: data) else {
            return [:]
        }
        return RelationshipXMLParser.parse(rels)
    }

    private static func normalizeWorkbookTarget(_ target: String) -> String {
        let trimmed = target.hasPrefix("/") ? String(target.dropFirst()) : target
        if trimmed.lowercased().hasPrefix("xl/") { return trimmed }
        return "xl/" + trimmed
    }

    // MARK: - OpenDocument

    private enum OpenDocumentMode {
        case text
        case sheet
        case slides
    }

    private static func openDocumentPreview(_ data: Data, mode: OpenDocumentMode) -> OfficePreviewDocument? {
        guard let xml = ZipArchiveReader.extractEntry(path: "content.xml", from: data) else { return nil }
        switch mode {
        case .text:
            let paragraphs = ParagraphXMLParser.parse(xml, limit: maxParagraphs)
            guard !paragraphs.isEmpty else { return nil }
            return OfficePreviewDocument(attributedText: renderParagraphs(paragraphs), summary: "OpenDocument text")
        case .sheet:
            let tables = OpenDocumentSheetParser.parse(xml, maxRows: maxRows, maxColumns: maxColumns, maxSheets: maxSheets)
            return renderOpenDocumentTables(tables, summaryPrefix: "sheet")
        case .slides:
            let pages = OpenDocumentSlideParser.parse(xml, maxSlides: maxSlides)
            guard !pages.isEmpty else { return nil }
            let result = NSMutableAttributedString()
            for (index, page) in pages.enumerated() {
                appendSectionTitle(page.name.isEmpty ? "Slide \(index + 1)" : page.name, to: result, isFirst: index == 0)
                result.append(renderParagraphs(page.paragraphs))
            }
            return OfficePreviewDocument(
                attributedText: result,
                summary: "\(pages.count) slide\(pages.count == 1 ? "" : "s")"
            )
        }
    }

    private static func renderOpenDocumentTables(_ tables: [(name: String, rows: [[String]])], summaryPrefix: String) -> OfficePreviewDocument? {
        let visibleTables = tables.filter { table in table.rows.contains { row in row.contains { !$0.isEmpty } } }
        guard !visibleTables.isEmpty else { return nil }
        let result = NSMutableAttributedString()
        for (index, table) in visibleTables.enumerated() {
            appendSectionTitle(table.name.isEmpty ? "Sheet \(index + 1)" : table.name, to: result, isFirst: index == 0)
            result.append(renderTable(table.rows))
        }
        return OfficePreviewDocument(
            attributedText: result,
            summary: "\(visibleTables.count) \(summaryPrefix)\(visibleTables.count == 1 ? "" : "s")"
        )
    }

    // MARK: - RTF

    private static func richTextPreview(_ data: Data) -> OfficePreviewDocument? {
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ), attributed.length > 0 else { return nil }
        return OfficePreviewDocument(attributedText: attributed, summary: "Rich text")
    }

    // MARK: - Rendering

    private static func renderParagraphs(_ paragraphs: [(text: String, heading: Bool)]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for paragraph in paragraphs {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = paragraph.heading ? 10 : 7
            style.lineSpacing = 1
            let font: NSFont = paragraph.heading
                ? .systemFont(ofSize: 16, weight: .semibold)
                : .systemFont(ofSize: 13)
            result.append(NSAttributedString(string: paragraph.text + "\n", attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style
            ]))
        }
        return result
    }

    private static func renderTable(_ rows: [[String]]) -> NSAttributedString {
        let columnCount = min(maxColumns, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return NSAttributedString() }

        var widths = Array(repeating: 3, count: columnCount)
        let displayRows = Array(rows.prefix(maxRows))
        for row in displayRows {
            for column in 0..<columnCount {
                let value = column < row.count ? cellDisplay(row[column]) : ""
                widths[column] = min(28, max(widths[column], value.count))
            }
        }

        let result = NSMutableAttributedString()
        let bodyFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let headerFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 1
        style.lineBreakMode = .byClipping

        for (index, row) in displayRows.enumerated() {
            var line = ""
            for column in 0..<columnCount {
                let value = column < row.count ? cellDisplay(row[column]) : ""
                line += value.padding(toLength: widths[column], withPad: " ", startingAt: 0)
                if column < columnCount - 1 { line += "  " }
            }
            result.append(NSAttributedString(string: line + "\n", attributes: [
                .font: index == 0 ? headerFont : bodyFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style
            ]))
        }
        return result
    }

    private static func appendSectionTitle(_ title: String, to result: NSMutableAttributedString, isFirst: Bool) {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 6
        style.paragraphSpacingBefore = isFirst ? 0 : 14
        result.append(NSAttributedString(string: title + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style
        ]))
    }

    private static func appendNote(_ text: String, to result: NSMutableAttributedString) {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 6
        result.append(NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: style
        ]))
    }

    private static func cellDisplay(_ value: String) -> String {
        let flattened = value.replacingOccurrences(of: "\n", with: " ")
        if flattened.count <= 28 { return flattened }
        return String(flattened.prefix(27)) + "…"
    }

    private static func slideNumber(_ path: String) -> Int {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let digits = name.filter(\.isNumber)
        return Int(digits) ?? 0
    }
}

// MARK: - XML parsers

private final class ParagraphXMLParser: NSObject, XMLParserDelegate {
    private var paragraphs: [(text: String, heading: Bool)] = []
    private var current = ""
    private var captureDepth = 0
    private var isHeading = false
    private var paragraphIsOpenDocument = false
    private var limit = 400

    static func parse(_ data: Data, limit: Int) -> [(text: String, heading: Bool)] {
        let parser = ParagraphXMLParser()
        parser.limit = limit
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.delegate = parser
        xml.parse()
        return parser.paragraphs
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "p", "h":
            current = ""
            isHeading = elementName == "h"
            paragraphIsOpenDocument = namespaceURI?.contains("opendocument") == true
            if paragraphIsOpenDocument {
                captureDepth += 1
            }
        case "pStyle":
            let style = (attributeDict["val"] ?? "").lowercased()
            isHeading = style.contains("heading") || style.contains("title")
        case "t", "span":
            captureDepth += 1
        case "tab":
            current += "\t"
        case "br", "cr", "line-break":
            current += "\n"
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard captureDepth > 0 else { return }
        current += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "t", "span":
            captureDepth = max(0, captureDepth - 1)
        case "p", "h":
            if paragraphIsOpenDocument {
                captureDepth = max(0, captureDepth - 1)
            }
            let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                paragraphs.append((text, isHeading || elementName == "h"))
            }
            current = ""
            paragraphIsOpenDocument = false
            if paragraphs.count >= limit {
                parser.abortParsing()
            }
        default:
            break
        }
    }
}

private final class SharedStringXMLParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var capture = false
    private var inItem = false
    private var inPhonetic = false

    static func parse(_ data: Data) -> [String] {
        let parser = SharedStringXMLParser()
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.delegate = parser
        xml.parse()
        return parser.strings
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "si" {
            inItem = true
            current = ""
        } else if elementName == "rPh" {
            inPhonetic = true
        } else if elementName == "t", inItem, !inPhonetic {
            capture = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capture else { return }
        current += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "t" {
            capture = false
        } else if elementName == "rPh" {
            inPhonetic = false
        } else if elementName == "si" {
            strings.append(current)
            inItem = false
            current = ""
            if strings.count >= 80_000 {
                parser.abortParsing()
            }
        }
    }
}

private final class SheetXMLParser: NSObject, XMLParserDelegate {
    private var rows: [[String]] = []
    private var row: [String] = []
    private var cellType = ""
    private var cellRef = ""
    private var cellValue = ""
    private var captureValue = false
    private var sharedStrings: [String] = []
    private var maxRows = 40
    private var maxColumns = 12

    static func parse(_ data: Data, sharedStrings: [String], maxRows: Int, maxColumns: Int) -> [[String]] {
        let parser = SheetXMLParser()
        parser.sharedStrings = sharedStrings
        parser.maxRows = maxRows
        parser.maxColumns = maxColumns
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.delegate = parser
        xml.parse()
        return parser.rows
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "row":
            row = []
        case "c":
            cellType = attributeDict["t"] ?? ""
            cellRef = attributeDict["r"] ?? ""
            cellValue = ""
        case "v":
            captureValue = true
        case "t" where cellType == "inlineStr":
            captureValue = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard captureValue else { return }
        cellValue += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "v", "t":
            captureValue = false
        case "c":
            place(resolvedCellValue())
        case "row":
            rows.append(row)
            if rows.count >= maxRows {
                parser.abortParsing()
            }
        default:
            break
        }
    }

    private func place(_ value: String) {
        if cellRef.isEmpty {
            if row.count < maxColumns {
                row.append(value)
            }
            return
        }
        let column = columnIndex(from: cellRef)
        guard column < maxColumns else { return }
        if row.count < column {
            row.append(contentsOf: Array(repeating: "", count: column - row.count))
        }
        if column == row.count {
            row.append(value)
        } else if column < row.count {
            row[column] = value
        }
    }

    private func resolvedCellValue() -> String {
        let trimmed = cellValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch cellType {
        case "s":
            guard let index = Int(trimmed), sharedStrings.indices.contains(index) else { return "" }
            return sharedStrings[index]
        case "b":
            return trimmed == "1" ? "TRUE" : "FALSE"
        case "inlineStr", "str":
            return trimmed
        default:
            return trimmed
        }
    }

    private func columnIndex(from reference: String) -> Int {
        var index = 0
        for scalar in reference.unicodeScalars {
            let value = scalar.value
            if value >= 65 && value <= 90 {
                index = index * 26 + Int(value - 64)
            } else if value >= 97 && value <= 122 {
                index = index * 26 + Int(value - 96)
            } else {
                break
            }
        }
        return max(0, index - 1)
    }
}

private final class WorkbookXMLParser: NSObject, XMLParserDelegate {
    struct SheetRef {
        let name: String
        let relationshipID: String
    }

    private var sheets: [SheetRef] = []

    static func parse(_ data: Data) -> [SheetRef] {
        let parser = WorkbookXMLParser()
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.delegate = parser
        xml.parse()
        return parser.sheets
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "sheet" else { return }
        let name = attributeDict["name"] ?? "Sheet"
        let relationship = attributeDict["id"]
            ?? attributeDict["r:id"]
            ?? attributeDict.first { $0.key.hasSuffix("id") && $0.key != "sheetId" }?.value
            ?? ""
        guard !relationship.isEmpty else { return }
        sheets.append(SheetRef(name: name, relationshipID: relationship))
    }
}

private final class RelationshipXMLParser: NSObject, XMLParserDelegate {
    private var relationships: [String: String] = [:]

    static func parse(_ data: Data) -> [String: String] {
        let parser = RelationshipXMLParser()
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.delegate = parser
        xml.parse()
        return parser.relationships
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "Relationship" else { return }
        guard let id = attributeDict["Id"], let target = attributeDict["Target"] else { return }
        relationships[id] = target
    }
}

private final class OpenDocumentSheetParser: NSObject, XMLParserDelegate {
    private var tables: [(name: String, rows: [[String]])] = []
    private var tableName = ""
    private var rows: [[String]] = []
    private var row: [String] = []
    private var cell = ""
    private var capture = false
    private var inCell = false
    private var maxRows = 40
    private var maxColumns = 12
    private var maxSheets = 4
    private var repeatedColumns = 1
    private var officeValue: String?

    static func parse(_ data: Data, maxRows: Int, maxColumns: Int, maxSheets: Int) -> [(name: String, rows: [[String]])] {
        let parser = OpenDocumentSheetParser()
        parser.maxRows = maxRows
        parser.maxColumns = maxColumns
        parser.maxSheets = maxSheets
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.delegate = parser
        xml.parse()
        return parser.tables
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "table" where tables.count < maxSheets:
            tableName = attributeDict["name"] ?? ""
            rows = []
        case "table-row" where rows.count < maxRows:
            row = []
        case "table-cell", "covered-table-cell":
            inCell = true
            cell = ""
            officeValue = attributeDict["value"]
            repeatedColumns = min(Int(attributeDict["number-columns-repeated"] ?? "1") ?? 1, maxColumns)
        case "p" where inCell:
            capture = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capture else { return }
        cell += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "p":
            capture = false
        case "table-cell", "covered-table-cell":
            let value = officeValue ?? cell.trimmingCharacters(in: .whitespacesAndNewlines)
            let repeats = value.isEmpty ? min(repeatedColumns, 1) : min(repeatedColumns, max(1, maxColumns - row.count))
            if row.count < maxColumns {
                for _ in 0..<repeats where row.count < maxColumns {
                    row.append(value)
                }
            }
            inCell = false
            cell = ""
            officeValue = nil
        case "table-row":
            if rows.count < maxRows {
                rows.append(row)
            }
        case "table":
            tables.append((tableName, rows))
            if tables.count >= maxSheets {
                parser.abortParsing()
            }
        default:
            break
        }
    }
}

private final class OpenDocumentSlideParser: NSObject, XMLParserDelegate {
    struct Page {
        let name: String
        let paragraphs: [(text: String, heading: Bool)]
    }

    private var pages: [Page] = []
    private var pageName = ""
    private var paragraphs: [(text: String, heading: Bool)] = []
    private var current = ""
    private var capture = false
    private var inPage = false
    private var maxSlides = 24

    static func parse(_ data: Data, maxSlides: Int) -> [Page] {
        let parser = OpenDocumentSlideParser()
        parser.maxSlides = maxSlides
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.delegate = parser
        xml.parse()
        return parser.pages
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "page" {
            inPage = true
            pageName = attributeDict["name"] ?? ""
            paragraphs = []
        } else if elementName == "p", inPage {
            current = ""
            capture = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capture else { return }
        current += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "p", inPage {
            let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                paragraphs.append((text, false))
            }
            capture = false
            current = ""
        } else if elementName == "page" {
            if !paragraphs.isEmpty {
                pages.append(Page(name: pageName, paragraphs: paragraphs))
            }
            inPage = false
            if pages.count >= maxSlides {
                parser.abortParsing()
            }
        }
    }
}
