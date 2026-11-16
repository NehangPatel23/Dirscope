import AppKit
import Foundation

enum RichTextPreviewFormat: String {
    case markdown
    case html
    case svg

    static func format(for url: URL) -> RichTextPreviewFormat? {
        format(forFileName: url.lastPathComponent)
    }

    static func format(forFileName fileName: String) -> RichTextPreviewFormat? {
        let lower = fileName.lowercased()
        let ext = URL(fileURLWithPath: lower).pathExtension

        if !ext.isEmpty {
            switch ext {
            case "md", "markdown":
                return .markdown
            case "html", "htm":
                return .html
            case "svg":
                return .svg
            default:
                break
            }
        }

        return nil
    }

    var sourceLabel: String {
        switch self {
        case .markdown: return "Source"
        case .html, .svg: return "Source"
        }
    }

    var renderedLabel: String { "Formatted" }
}

enum FilePreviewDisplayMode: Int {
    case source = 0
    case rendered = 1
}

enum RichTextPreviewRenderer {
    static func renderedMarkdown(_ source: String, baseURL: URL) -> NSAttributedString? {
        if let roundTrip = markdownViaHTMLRoundTrip(source, baseURL: baseURL),
           hasDistinctBlocks(roundTrip) {
            return roundTrip
        }
        return markdownFromBlocks(source, baseURL: baseURL)
    }

    static func renderedHTML(_ source: String, baseURL: URL) -> NSAttributedString? {
        renderedHTMLDocument(source, baseURL: baseURL)
    }

    static func hasVisibleText(_ attributed: NSAttributedString) -> Bool {
        let plain = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return !plain.isEmpty
    }

    private static func markdownViaHTMLRoundTrip(_ source: String, baseURL: URL) -> NSAttributedString? {
        guard let markdown = try? NSAttributedString(
            markdown: Data(source.utf8),
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full),
            baseURL: baseURL
        ) else {
            return nil
        }

        let range = NSRange(location: 0, length: markdown.length)
        guard let htmlData = try? markdown.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
        ), let html = String(data: htmlData, encoding: .utf8) else {
            return normalizeForTextView(markdown)
        }
        return renderedHTMLDocument(html, baseURL: baseURL)
    }

    private static func markdownFromBlocks(_ source: String, baseURL: URL) -> NSAttributedString {
        let blocks = splitMarkdownBlocks(source)
        let result = NSMutableAttributedString()
        let separatorStyle = NSMutableParagraphStyle()
        separatorStyle.paragraphSpacing = 10

        for (index, block) in blocks.enumerated() {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if index > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: separatorStyle]))
            }

            if let blockAttr = try? NSAttributedString(
                markdown: Data(trimmed.utf8),
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full),
                baseURL: baseURL
            ) {
                result.append(normalizeForTextView(blockAttr))
            } else {
                result.append(plainTextPreview(trimmed))
            }
        }

        return result.length > 0 ? result : plainTextPreview(source)
    }

    private static func splitMarkdownBlocks(_ source: String) -> [String] {
        var blocks: [String] = []
        var current = ""
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)

        for line in lines {
            let text = String(line)
            let isBlank = text.trimmingCharacters(in: .whitespaces).isEmpty
            let isBlockStart = text.hasPrefix("#")
                || text.hasPrefix("```")
                || text.hasPrefix(">")
                || text.hasPrefix("- ")
                || text.hasPrefix("* ")
                || text.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil

            if isBlank {
                if !current.isEmpty {
                    blocks.append(current)
                    current = ""
                }
                continue
            }

            if isBlockStart && !current.isEmpty {
                blocks.append(current)
                current = text
            } else if current.isEmpty {
                current = text
            } else {
                current += "\n" + text
            }
        }

        if !current.isEmpty {
            blocks.append(current)
        }

        return blocks.isEmpty ? [source] : blocks
    }

    private static func hasDistinctBlocks(_ attributed: NSAttributedString) -> Bool {
        var paragraphCount = 0
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            let text = (attributed.string as NSString).substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                paragraphCount += 1
            }
        }
        return paragraphCount > 1
    }

    private static func renderedHTMLDocument(_ html: String, baseURL: URL) -> NSAttributedString? {
        let wrapped = html.lowercased().contains("<html")
            ? html
            : """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8"></head><body>\(html)</body></html>
            """

        guard let data = wrapped.data(using: .utf8) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let attributed = try? NSAttributedString(
            data: data,
            options: options,
            documentAttributes: nil
        ) else {
            return nil
        }
        return normalizeForTextView(attributed)
    }

    private static func plainTextPreview(_ source: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 8
        return NSAttributedString(
            string: source,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style
            ]
        )
    }

    private static func normalizeForTextView(_ attributed: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let fullRange = NSRange(location: 0, length: mutable.length)
        guard fullRange.length > 0 else { return attributed }

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let defaultStyle = NSMutableParagraphStyle()
        defaultStyle.lineSpacing = 2
        defaultStyle.paragraphSpacing = 8
        defaultStyle.paragraphSpacingBefore = 4
        defaultStyle.lineBreakMode = .byWordWrapping

        mutable.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? defaultStyle.mutableCopy() as! NSMutableParagraphStyle
            style.lineSpacing = max(style.lineSpacing, 2)
            style.paragraphSpacing = max(style.paragraphSpacing, 8)
            style.paragraphSpacingBefore = max(style.paragraphSpacingBefore, 4)
            style.lineBreakMode = .byWordWrapping
            mutable.addAttribute(.paragraphStyle, value: style, range: range)
        }

        mutable.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            if mutable.attribute(.link, at: range.location, effectiveRange: nil) != nil {
                return
            }

            guard let color = value as? NSColor, let rgb = color.usingColorSpace(.deviceRGB) else {
                mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
                return
            }

            let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
            if isDark && luminance < 0.55 {
                mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            } else if !isDark && luminance > 0.75 {
                mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }

        var missingStyle = IndexSet()
        mutable.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
            if value == nil { missingStyle.insert(integersIn: range.location..<range.upperBound) }
        }
        if !missingStyle.isEmpty {
            mutable.addAttribute(.paragraphStyle, value: defaultStyle, range: fullRange)
        }

        return mutable
    }
}

// MARK: - Source highlighting

enum SourceSyntaxHighlighter {
    static func foregroundColor(for appearance: NSAppearance) -> NSColor {
        SyntaxPalette.resolved(for: appearance).text
    }

    static func highlight(_ source: String, fileName: String, appearance: NSAppearance) -> NSAttributedString {
        let language = SourceLanguage.detect(fileName: fileName)
        let colors = SyntaxPalette.resolved(for: appearance)
        let base: [NSAttributedString.Key: Any] = [
            .font: PreviewTheme.sourceEditorFont,
            .foregroundColor: colors.text
        ]
        let text = source as NSString
        let result = NSMutableAttributedString(string: source, attributes: base)
        guard text.length > 0 else { return result }

        var index = 0
        var inBlockComment = false
        var inHTMLComment = false
        var colorNextIdentifierAsKeyword = false

        while index < text.length {
            if language == .html || language == .xml {
                index = paintMarkup(
                    text,
                    into: result,
                    from: index,
                    colors: colors,
                    inHTMLComment: &inHTMLComment
                )
                continue
            }

            if inBlockComment {
                let end = find(text, startingAt: index, needle: "*/")
                let upper = end.map { $0 + 2 } ?? text.length
                paint(result, index..<upper, colors.comment)
                inBlockComment = end == nil
                index = upper
                continue
            }

            let scalar = text.character(at: index)

            if scalar == 47, index + 1 < text.length, text.character(at: index + 1) == 47 { // //
                let upper = lineEnd(text, from: index)
                paint(result, index..<upper, colors.comment)
                index = upper
                continue
            }

            if language.usesHashComments, scalar == 35 { // #
                let upper = lineEnd(text, from: index)
                paint(result, index..<upper, colors.comment)
                colorNextIdentifierAsKeyword = false
                index = upper
                continue
            }

            if language == .swift, scalar == 35, index + 1 < text.length, isIdentStart(text.character(at: index + 1)) {
                var upper = index + 2
                while upper < text.length, isIdentPart(text.character(at: upper)) {
                    upper += 1
                }
                paint(result, index..<upper, colors.keyword)
                index = upper
                continue
            }

            if scalar == 64, index + 1 < text.length, isIdentStart(text.character(at: index + 1)) { // @attribute
                var upper = index + 2
                while upper < text.length, isIdentPart(text.character(at: upper)) {
                    upper += 1
                }
                paint(result, index..<upper, colors.attribute)
                index = upper
                continue
            }

            if scalar == 47, index + 1 < text.length, text.character(at: index + 1) == 42 { // /*
                let end = find(text, startingAt: index + 2, needle: "*/")
                let upper = end.map { $0 + 2 } ?? text.length
                paint(result, index..<upper, colors.comment)
                inBlockComment = end == nil
                index = upper
                continue
            }

            if scalar == 34 || scalar == 39 || scalar == 96 { // " ' `
                let upper = endOfString(text, from: index, delimiter: scalar)
                let followedByColon = language == .json && nextNonSpace(text, from: upper) == 58
                paint(result, index..<upper, followedByColon ? colors.attribute : colors.string)
                colorNextIdentifierAsKeyword = false
                index = upper
                continue
            }

            if isDigit(scalar) || (scalar == 46 && index + 1 < text.length && isDigit(text.character(at: index + 1))) {
                var upper = index + 1
                while upper < text.length, isNumberPart(text.character(at: upper)) {
                    upper += 1
                }
                paint(result, index..<upper, colors.number)
                index = upper
                continue
            }

            if scalar == 46, index + 1 < text.length, isIdentStart(text.character(at: index + 1)) {
                var upper = index + 2
                while upper < text.length, isIdentPart(text.character(at: upper)) {
                    upper += 1
                }
                // Calls such as .font( stay cyan. Enum cases such as .white stay green.
                let followedByCall = nextNonSpace(text, from: upper) == 40
                paint(result, index..<upper, followedByCall ? colors.member : colors.type)
                colorNextIdentifierAsKeyword = false
                index = upper
                continue
            }

            if isIdentStart(scalar) {
                var upper = index + 1
                while upper < text.length, isIdentPart(text.character(at: upper)) {
                    upper += 1
                }
                let word = text.substring(with: NSRange(location: index, length: upper - index))
                if colorNextIdentifierAsKeyword {
                    paint(result, index..<upper, colors.keyword)
                    colorNextIdentifierAsKeyword = false
                } else if nextNonSpace(text, from: upper) == 58, language == .css || language == .yaml {
                    paint(result, index..<upper, language == .css ? colors.member : colors.attribute)
                } else if let color = colorForIdentifier(word, language: language, colors: colors, followedByCall: nextNonSpace(text, from: upper) == 40) {
                    paint(result, index..<upper, color)
                }
                if word == "import" || word == "from" || word == "package" {
                    colorNextIdentifierAsKeyword = true
                }
                index = upper
                continue
            }

            if scalar == 10 || scalar == 13 {
                colorNextIdentifierAsKeyword = false
            }
            index += 1
        }

        return result
    }

    private static func paintMarkup(
        _ text: NSString,
        into result: NSMutableAttributedString,
        from index: Int,
        colors: SyntaxColors,
        inHTMLComment: inout Bool
    ) -> Int {
        if inHTMLComment {
            let end = find(text, startingAt: index, needle: "-->")
            let upper = end.map { $0 + 3 } ?? text.length
            paint(result, index..<upper, colors.comment)
            inHTMLComment = end == nil
            return upper
        }

        if text.length >= index + 4,
           text.substring(with: NSRange(location: index, length: 4)) == "<!--" {
            let end = find(text, startingAt: index + 4, needle: "-->")
            let upper = end.map { $0 + 3 } ?? text.length
            paint(result, index..<upper, colors.comment)
            inHTMLComment = end == nil
            return upper
        }

        let scalar = text.character(at: index)
        guard scalar == 60 else { return index + 1 } // <

        if index + 1 < text.length, text.character(at: index + 1) == 33 { // <!DOCTYPE and other declarations
            let end = find(text, startingAt: index, needle: ">")
            let upper = end.map { $0 + 1 } ?? text.length
            paint(result, index..<upper, colors.keyword)
            return upper
        }

        var cursor = index + 1
        if cursor < text.length, text.character(at: cursor) == 47 { cursor += 1 } // /
        let nameStart = cursor
        while cursor < text.length, isTagName(text.character(at: cursor)) {
            cursor += 1
        }
        if cursor > nameStart {
            paint(result, (index)..<(cursor), colors.keyword)
        }

        while cursor < text.length {
            let ch = text.character(at: cursor)
            if ch == 62 { // >
                paint(result, cursor..<(cursor + 1), colors.keyword)
                return cursor + 1
            }
            if ch == 34 || ch == 39 {
                let upper = endOfString(text, from: cursor, delimiter: ch)
                paint(result, cursor..<upper, colors.string)
                cursor = upper
                continue
            }
            if isIdentStart(ch) {
                let attrStart = cursor
                cursor += 1
                while cursor < text.length, isIdentPart(text.character(at: cursor)) || text.character(at: cursor) == 45 {
                    cursor += 1
                }
                paint(result, attrStart..<cursor, colors.attribute)
                continue
            }
            cursor += 1
        }

        return text.length
    }

    private static func colorForIdentifier(
        _ word: String,
        language: SourceLanguage,
        colors: SyntaxColors,
        followedByCall: Bool
    ) -> NSColor? {
        if language.keywords.contains(word) { return colors.keyword }
        if followedByCall { return colors.member }
        if let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) {
            return colors.type
        }
        return nil
    }

    private static func paint(_ result: NSMutableAttributedString, _ range: Range<Int>, _ color: NSColor) {
        guard range.lowerBound < range.upperBound, range.upperBound <= result.length else { return }
        result.addAttribute(
            .foregroundColor,
            value: color,
            range: NSRange(location: range.lowerBound, length: range.upperBound - range.lowerBound)
        )
    }

    private static func find(_ text: NSString, startingAt index: Int, needle: String) -> Int? {
        let range = text.range(of: needle, options: [], range: NSRange(location: index, length: text.length - index))
        return range.location == NSNotFound ? nil : range.location
    }

    private static func lineEnd(_ text: NSString, from index: Int) -> Int {
        let range = text.lineRange(for: NSRange(location: index, length: 0))
        var upper = NSMaxRange(range)
        if upper > index, text.character(at: upper - 1) == 10 { upper -= 1 }
        if upper > index, text.character(at: upper - 1) == 13 { upper -= 1 }
        return upper
    }

    private static func endOfString(_ text: NSString, from index: Int, delimiter: unichar) -> Int {
        var cursor = index + 1
        while cursor < text.length {
            let ch = text.character(at: cursor)
            if ch == 92 { // backslash
                cursor += min(2, text.length - cursor)
                continue
            }
            if ch == delimiter { return cursor + 1 }
            if ch == 10 || ch == 13 { return cursor }
            cursor += 1
        }
        return text.length
    }

    private static func nextNonSpace(_ text: NSString, from index: Int) -> unichar? {
        var cursor = index
        while cursor < text.length {
            let ch = text.character(at: cursor)
            if ch != 32 && ch != 9 { return ch }
            cursor += 1
        }
        return nil
    }

    private static func isDigit(_ value: unichar) -> Bool { value >= 48 && value <= 57 }
    private static func isNumberPart(_ value: unichar) -> Bool {
        isDigit(value) || value == 46 || value == 95 || (value >= 65 && value <= 70) || (value >= 97 && value <= 102) || value == 120 || value == 88
    }
    private static func isIdentStart(_ value: unichar) -> Bool {
        (value >= 65 && value <= 90) || (value >= 97 && value <= 122) || value == 95 || value == 36
    }
    private static func isIdentPart(_ value: unichar) -> Bool { isIdentStart(value) || isDigit(value) }
    private static func isTagName(_ value: unichar) -> Bool { isIdentPart(value) || value == 58 || value == 45 }
}

private enum SourceLanguage {
    case swift
    case javascript
    case python
    case go
    case rust
    case cFamily
    case ruby
    case php
    case json
    case css
    case shell
    case yaml
    case html
    case xml
    case generic

    var usesHashComments: Bool {
        switch self {
        case .shell, .python, .ruby, .yaml: return true
        default: return false
        }
    }

    var keywords: Set<String> {
        switch self {
        case .swift:
            return [
                "associatedtype", "async", "await", "break", "case", "catch", "class", "continue",
                "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
                "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "init",
                "inout", "internal", "is", "let", "nil", "open", "operator", "private", "protocol",
                "public", "repeat", "rethrows", "return", "self", "Self", "static", "struct",
                "subscript", "super", "switch", "throw", "throws", "try", "true", "typealias",
                "var", "where", "while", "some", "any", "as"
            ]
        case .javascript:
            return [
                "break", "case", "catch", "class", "const", "continue", "debugger", "default",
                "delete", "do", "else", "export", "extends", "false", "finally", "for", "function",
                "if", "import", "in", "instanceof", "let", "new", "null", "return", "static",
                "super", "switch", "this", "throw", "true", "try", "typeof", "undefined", "var",
                "void", "while", "yield", "async", "await", "of", "from"
            ]
        case .python:
            return [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
                "del", "elif", "else", "except", "False", "finally", "for", "from", "global",
                "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass",
                "raise", "return", "True", "try", "while", "with", "yield"
            ]
        case .go:
            return [
                "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
                "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
                "return", "select", "struct", "switch", "type", "var", "true", "false", "nil"
            ]
        case .rust:
            return [
                "as", "async", "await", "break", "const", "continue", "crate", "else", "enum",
                "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
                "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super",
                "trait", "true", "type", "unsafe", "use", "where", "while"
            ]
        case .cFamily:
            return [
                "auto", "break", "case", "catch", "class", "const", "continue", "default", "delete",
                "do", "else", "enum", "export", "extern", "false", "for", "goto", "if", "inline",
                "namespace", "new", "private", "protected", "public", "return", "static", "struct",
                "switch", "template", "this", "throw", "true", "try", "typedef", "typename", "using",
                "virtual", "void", "volatile", "while", "bool", "int", "float", "double", "char",
                "long", "short", "unsigned", "signed", "sizeof", "nullptr", "nil"
            ]
        case .ruby:
            return [
                "alias", "and", "begin", "break", "case", "class", "def", "defined", "do", "else",
                "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not",
                "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef",
                "unless", "until", "when", "while", "yield", "require", "include"
            ]
        case .php:
            return [
                "abstract", "and", "array", "as", "break", "case", "catch", "class", "clone", "const",
                "continue", "declare", "default", "do", "echo", "else", "elseif", "empty", "enddeclare",
                "endfor", "endforeach", "endif", "endswitch", "endwhile", "extends", "false", "final",
                "finally", "for", "foreach", "function", "global", "if", "implements", "include",
                "instanceof", "interface", "isset", "namespace", "new", "null", "or", "print",
                "private", "protected", "public", "require", "return", "static", "switch", "throw",
                "trait", "true", "try", "use", "var", "while", "yield"
            ]
        case .json:
            return ["true", "false", "null"]
        case .css:
            return ["important"]
        case .shell:
            return ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function", "return", "in", "echo", "export", "local"]
        case .html, .xml, .yaml, .generic:
            return []
        }
    }

    static func detect(fileName: String) -> SourceLanguage {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "swift":
            return .swift
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "vue", "svelte":
            return .javascript
        case "py":
            return .python
        case "go":
            return .go
        case "rs":
            return .rust
        case "c", "h", "cpp", "cc", "cxx", "hpp", "hh", "m", "mm", "java", "kt", "kts", "cs", "scala":
            return .cFamily
        case "rb":
            return .ruby
        case "php":
            return .php
        case "json", "jsonc", "json5":
            return .json
        case "css", "scss", "sass", "less":
            return .css
        case "sh", "bash", "zsh", "fish":
            return .shell
        case "yml", "yaml":
            return .yaml
        case "html", "htm", "svg":
            return .html
        case "xml", "plist", "xib", "storyboard":
            return .xml
        default:
            return .generic
        }
    }
}

struct SyntaxColors {
    let text: NSColor
    let comment: NSColor
    let keyword: NSColor
    let type: NSColor
    let member: NSColor
    let string: NSColor
    let number: NSColor
    let attribute: NSColor
}

private enum SyntaxPalette {
    static func resolved(for appearance: NSAppearance) -> SyntaxColors {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if dark {
            return SyntaxColors(
                text: NSColor(srgbRed: 0.91, green: 0.91, blue: 0.93, alpha: 1),
                comment: NSColor(srgbRed: 0.49, green: 0.52, blue: 0.56, alpha: 1),
                keyword: NSColor(srgbRed: 0.82, green: 0.45, blue: 0.93, alpha: 1),
                type: NSColor(srgbRed: 0.45, green: 0.84, blue: 0.48, alpha: 1),
                member: NSColor(srgbRed: 0.40, green: 0.78, blue: 0.96, alpha: 1),
                string: NSColor(srgbRed: 0.70, green: 0.84, blue: 0.46, alpha: 1),
                number: NSColor(srgbRed: 0.86, green: 0.86, blue: 0.42, alpha: 1),
                attribute: NSColor(srgbRed: 0.95, green: 0.62, blue: 0.36, alpha: 1)
            )
        }
        return SyntaxColors(
            text: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1),
            comment: NSColor(srgbRed: 0.45, green: 0.47, blue: 0.50, alpha: 1),
            keyword: NSColor(srgbRed: 0.62, green: 0.16, blue: 0.55, alpha: 1),
            type: NSColor(srgbRed: 0.07, green: 0.42, blue: 0.55, alpha: 1),
            member: NSColor(srgbRed: 0.10, green: 0.36, blue: 0.72, alpha: 1),
            string: NSColor(srgbRed: 0.55, green: 0.28, blue: 0.07, alpha: 1),
            number: NSColor(srgbRed: 0.12, green: 0.38, blue: 0.62, alpha: 1),
            attribute: NSColor(srgbRed: 0.62, green: 0.32, blue: 0.05, alpha: 1)
        )
    }
}
