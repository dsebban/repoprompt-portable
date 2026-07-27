import Foundation

struct CodeMapPCRE2Match {
    private let captures: [String?]
    private let wholeRange: NSRange
    private let subjectUTF16Count: Int

    init(subject: String, result: NSTextCheckingResult) {
        wholeRange = result.range
        subjectUTF16Count = subject.utf16.count
        captures = (0..<result.numberOfRanges).map { index in
            guard let range = Range(result.range(at: index), in: subject) else { return nil }
            return String(subject[range])
        }
    }

    func capture(_ index: Int) -> String? {
        guard captures.indices.contains(index) else { return nil }
        return captures[index]
    }

    func trimmedCapture(_ index: Int) -> String? {
        capture(index)?.trimmingCharacters(in: .whitespaces)
    }

    var isWholeMatch: Bool {
        wholeRange.location == 0 && wholeRange.length == subjectUTF16Count
    }
}

struct CodeMapPCRE2Pattern {
    private let regex: NSRegularExpression

    init(
        _ pattern: String,
        caseInsensitive: Bool = false,
        multilineAnchors: Bool = false,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        var options: NSRegularExpression.Options = [.useUnixLineSeparators]
        if caseInsensitive { options.insert(.caseInsensitive) }
        if multilineAnchors { options.insert(.anchorsMatchLines) }
        do {
            regex = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("Invalid codemap regular expression at \(file):\(line): \(error)")
        }
    }

    func firstMatch(in text: String) -> CodeMapPCRE2Match? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, range: range) else { return nil }
        return CodeMapPCRE2Match(subject: text, result: result)
    }

    func firstCapture(_ index: Int = 1, in text: String) -> String? {
        firstMatch(in: text)?.capture(index)
    }

    func trimmedCapture(_ index: Int = 1, in text: String) -> String? {
        firstMatch(in: text)?.trimmedCapture(index)
    }

    func matches(_ text: String) -> Bool {
        firstMatch(in: text) != nil
    }

    func wholeMatch(in text: String) -> Bool {
        firstMatch(in: text)?.isWholeMatch == true
    }

    func replacingMatches(in text: String, with replacement: String = "") -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}
