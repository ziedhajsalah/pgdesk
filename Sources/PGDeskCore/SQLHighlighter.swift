import Foundation

public struct SQLToken: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case keyword, string, number, comment
    }

    public let kind: Kind
    /// Offset and length in UTF-16 code units, the same units as `NSRange`.
    public let location: Int
    public let length: Int

    public init(_ kind: Kind, location: Int, length: Int) {
        self.kind = kind
        self.location = location
        self.length = length
    }

    public var range: NSRange { NSRange(location: location, length: length) }
    public var end: Int { location + length }
}

/// A one-pass SQL lexer for syntax colouring. It knows comments (including nested block comments),
/// standard, `E''` and dollar-quoted strings, quoted identifiers, numbers and keywords.
/// It works on UTF-16 so token ranges can be used directly with `NSTextStorage`.
public enum SQLHighlighter {
    public static func tokens(in text: String) -> [SQLToken] {
        let units = Array(text.utf16)
        return units.withUnsafeBufferPointer { tokens(in: $0) }
    }

    public static func tokens(in s: UnsafeBufferPointer<UInt16>) -> [SQLToken] {
        var tokens: [SQLToken] = []
        let n = s.count
        var i = 0

        func at(_ k: Int) -> UInt16 { k < n ? s[k] : 0 }

        while i < n {
            let c = s[i]
            switch c {
            case 0x2D where at(i + 1) == 0x2D: // --
                let start = i
                i += 2
                while i < n && s[i] != 0x0A { i += 1 }
                tokens.append(SQLToken(.comment, location: start, length: i - start))

            case 0x2F where at(i + 1) == 0x2A: // /*
                let start = i
                var depth = 1
                i += 2
                while i < n && depth > 0 {
                    if s[i] == 0x2F && at(i + 1) == 0x2A {
                        depth += 1
                        i += 2
                    } else if s[i] == 0x2A && at(i + 1) == 0x2F {
                        depth -= 1
                        i += 2
                    } else {
                        i += 1
                    }
                }
                tokens.append(SQLToken(.comment, location: start, length: i - start))

            case 0x27: // '
                let start = i
                i = endOfQuoted(s, from: i + 1, quote: 0x27, backslashEscapes: false)
                tokens.append(SQLToken(.string, location: start, length: i - start))

            case 0x22: // "quoted identifier": skipped so its contents aren't coloured
                i = endOfQuoted(s, from: i + 1, quote: 0x22, backslashEscapes: false)

            case 0x24: // $tag$ … $tag$, or $1 parameter
                if let close = dollarQuoteEnd(s, from: i) {
                    tokens.append(SQLToken(.string, location: i, length: close - i))
                    i = close
                } else {
                    i += 1
                    while i < n && isDigit(s[i]) { i += 1 }
                }

            case _ where isDigit(c) || (c == 0x2E && isDigit(at(i + 1))):
                let start = i
                while i < n && isDigit(s[i]) { i += 1 }
                if at(i) == 0x2E && at(i + 1) != 0x2E { // not the `..` of a range
                    i += 1
                    while i < n && isDigit(s[i]) { i += 1 }
                }
                if at(i) == 0x65 || at(i) == 0x45 { // e / E
                    var k = i + 1
                    if at(k) == 0x2B || at(k) == 0x2D { k += 1 }
                    if isDigit(at(k)) {
                        i = k
                        while i < n && isDigit(s[i]) { i += 1 }
                    }
                }
                // `123abc` is not a number followed by a word; leave the whole thing uncoloured.
                if i < n && isIdentifierPart(s[i]) {
                    while i < n && isIdentifierPart(s[i]) { i += 1 }
                } else {
                    tokens.append(SQLToken(.number, location: start, length: i - start))
                }

            case _ where isIdentifierStart(c):
                let start = i
                var ascii = true
                while i < n && isIdentifierPart(s[i]) {
                    if s[i] > 0x7F { ascii = false }
                    i += 1
                }
                let length = i - start
                if (c == 0x45 || c == 0x65) && length == 1 && at(i) == 0x27 { // E'escaped string'
                    i = endOfQuoted(s, from: i + 1, quote: 0x27, backslashEscapes: true)
                    tokens.append(SQLToken(.string, location: start, length: i - start))
                } else if ascii && length <= maxKeywordLength && isKeyword(s, start: start, length: length) {
                    tokens.append(SQLToken(.keyword, location: start, length: length))
                }

            default:
                i += 1
            }
        }
        return tokens
    }

    /// The part of the text whose colours may differ after an edit, given the tokens before and after it.
    /// `edited` and `changeInLength` are the values `NSTextStorage` reports in `processEditing`.
    /// Tokens before the edit and tokens after it that only moved by `changeInLength` keep their colours.
    public static func dirtyRange(old: [SQLToken], new: [SQLToken], edited: NSRange, changeInLength delta: Int) -> NSRange {
        let editEnd = NSMaxRange(edited)
        let oldEditEnd = editEnd - delta

        var prefix = 0
        while prefix < old.count && prefix < new.count && old[prefix] == new[prefix] && new[prefix].end <= edited.location {
            prefix += 1
        }

        func shifted(_ t: SQLToken) -> SQLToken { SQLToken(t.kind, location: t.location + delta, length: t.length) }
        var oldSuffix = old.count
        var newSuffix = new.count
        while oldSuffix > prefix && newSuffix > prefix
                && old[oldSuffix - 1].location >= oldEditEnd
                && shifted(old[oldSuffix - 1]) == new[newSuffix - 1] {
            oldSuffix -= 1
            newSuffix -= 1
        }

        // Maps an offset in the old text to the new text.
        func map(_ p: Int) -> Int {
            if p <= edited.location { return p }
            if p >= oldEditEnd { return p + delta }
            return editEnd
        }

        var lower = edited.location
        var upper = editEnd
        for t in old[prefix..<oldSuffix] {
            lower = min(lower, map(t.location))
            upper = max(upper, map(t.end))
        }
        for t in new[prefix..<newSuffix] {
            lower = min(lower, t.location)
            upper = max(upper, t.end)
        }
        return NSRange(location: lower, length: upper - lower)
    }

    // MARK: - Lexing helpers

    private static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

    private static func isIdentifierStart(_ c: UInt16) -> Bool {
        (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || c == 0x5F || c > 0x7F
    }

    private static func isIdentifierPart(_ c: UInt16) -> Bool {
        isIdentifierStart(c) || isDigit(c) || c == 0x24
    }

    /// Index just past the closing quote (or the end of text). A doubled quote is an escaped quote.
    private static func endOfQuoted(_ s: UnsafeBufferPointer<UInt16>, from start: Int, quote: UInt16, backslashEscapes: Bool) -> Int {
        var i = start
        while i < s.count {
            let c = s[i]
            if backslashEscapes && c == 0x5C {
                i += 2
            } else if c == quote {
                if i + 1 < s.count && s[i + 1] == quote {
                    i += 2
                } else {
                    return i + 1
                }
            } else {
                i += 1
            }
        }
        return s.count
    }

    /// For a `$tag$` opener at `start`, the index just past the matching closer (or the end of text).
    /// nil when `start` isn't a dollar-quote opener (e.g. a `$1` parameter).
    private static func dollarQuoteEnd(_ s: UnsafeBufferPointer<UInt16>, from start: Int) -> Int? {
        // A `$` inside an identifier (`a$b`) can't open a quote; the identifier scanner consumes those.
        var i = start + 1
        if i < s.count && isIdentifierStart(s[i]) {
            while i < s.count && (isIdentifierStart(s[i]) || isDigit(s[i])) { i += 1 }
        }
        guard i < s.count && s[i] == 0x24 else { return nil }
        let tagLength = i - start + 1
        i += 1
        while i < s.count {
            if s[i] == 0x24 && i + tagLength <= s.count {
                var matches = true
                for k in 0..<tagLength where s[i + k] != s[start + k] {
                    matches = false
                    break
                }
                if matches { return i + tagLength }
            }
            i += 1
        }
        return s.count
    }

    private static func isKeyword(_ s: UnsafeBufferPointer<UInt16>, start: Int, length: Int) -> Bool {
        var word = [UInt8](repeating: 0, count: length)
        for k in 0..<length {
            let c = s[start + k]
            word[k] = UInt8(c >= 0x41 && c <= 0x5A ? c + 0x20 : c)
        }
        return keywords.contains(word)
    }

    private static let keywords: Set<[UInt8]> = Set(keywordList.split(separator: " ").map { Array($0.utf8) })
    private static let maxKeywordLength = keywordList.split(separator: " ").map(\.count).max() ?? 0

    private static let keywordList = """
        abort add all alter analyze and any array as asc begin between bigint bigserial bit boolean both by \
        call cascade case cast char character check close cluster coalesce collate column comment commit \
        concurrently constraint copy create cross current_date current_time current_timestamp current_user cursor \
        database date deallocate declare default deferrable deferred delete desc discard distinct do domain double drop \
        else end enum except exclude execute exists explain extension false fetch filter first float for foreign from full function \
        grant group having if ilike immediate in index inherits initially inner insert int integer intersect interval into is \
        join json jsonb key language last lateral leading left like limit listen local lock materialized move natural not notify \
        null nullif nulls numeric of off offset on only or order outer over overriding owner partition placing policy precision prepare \
        primary procedure real recursive references refresh reindex release rename repeatable replace reset restrict returning \
        returns revoke right role rollback row rows savepoint schema select sequence serial session_user set setof show similar \
        smallint some table tablespace temp temporary text then time timestamp timestamptz to trailing transaction trigger true \
        truncate type union unique unlisten unlogged update user using uuid vacuum values varchar variadic verbose view \
        when where window with without
        """
}
