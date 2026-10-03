//
//  TrackLanguagePreference.swift
//  Lumen
//
import Foundation

public enum TrackLanguagePreference: Sendable {
    public struct Candidate: Equatable, Sendable {
        public var languageCode: String?
        public var isImageBased: Bool

        public init(languageCode: String?, isImageBased: Bool = false) {
            self.languageCode = languageCode
            self.isImageBased = isImageBased
        }
    }

    public static func normalize(_ code: String?) -> String? {
        guard let code else { return nil }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let base = trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) else {
            return nil
        }
        if let mapped = aliases[base] {
            return mapped
        }
        guard (2 ... 3).contains(base.count),
              base.allSatisfy({ $0.isASCII && $0.isLetter }),
              !undetermined.contains(base)
        else {
            return nil
        }
        return base
    }

    public static func pickIndex(preferred: [String], candidates: [Candidate]) -> Int? {
        let candidateLanguages = candidates.map { normalize($0.languageCode) }
        for language in preferred.compactMap({ normalize($0) }) {
            let matches = candidateLanguages.indices.filter { candidateLanguages[$0] == language }
            if let textMatch = matches.first(where: { !candidates[$0].isImageBased }) {
                return textMatch
            }
            if let imageMatch = matches.first {
                return imageMatch
            }
        }
        return nil
    }

    private static let undetermined: Set<String> = ["und", "mul", "mis", "zxx"]

    private static let aliases: [String: String] = {
        let groups: [(String, [String])] = [
            ("pt", ["por"]),
            ("en", ["eng"]),
            ("es", ["spa"]),
            ("fr", ["fre", "fra"]),
            ("de", ["ger", "deu"]),
            ("it", ["ita"]),
            ("ja", ["jpn"]),
            ("ko", ["kor"]),
            ("zh", ["chi", "zho"]),
            ("ru", ["rus"]),
            ("ar", ["ara"]),
            ("hi", ["hin"]),
            ("pl", ["pol"]),
            ("tr", ["tur"]),
            ("nl", ["dut", "nld"]),
            ("sv", ["swe"]),
            ("no", ["nor", "nb", "nob", "nn", "nno"]),
            ("da", ["dan"]),
            ("fi", ["fin"]),
            ("cs", ["cze", "ces"]),
            ("el", ["gre", "ell"]),
            ("he", ["heb", "iw"]),
            ("hu", ["hun"]),
            ("ro", ["rum", "ron"]),
            ("uk", ["ukr"]),
            ("th", ["tha"]),
            ("vi", ["vie"]),
            ("id", ["ind", "in"]),
        ]
        var table = [String: String]()
        for (base, codes) in groups {
            table[base] = base
            for code in codes {
                table[code] = base
            }
        }
        return table
    }()
}
