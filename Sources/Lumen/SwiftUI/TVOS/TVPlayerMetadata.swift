//
//  TVPlayerMetadata.swift
//  Lumen
//
import Foundation

#if os(tvOS)
public struct TVPlayerCredit: Equatable, Sendable {
    public var name: String
    public var role: String?
    public var imageURL: URL?

    public init(name: String, role: String? = nil, imageURL: URL? = nil) {
        self.name = name
        self.role = role
        self.imageURL = imageURL
    }
}

public struct TVPlayerMetadata: Equatable, Sendable {
    public var subtitle: String?
    public var seasonNumber: Int?
    public var episodeNumber: Int?
    public var synopsis: String?
    public var artworkURL: URL?
    public var year: Int?
    public var genres: [String]
    public var runtimeMinutes: Int?
    public var ageRatingLabel: String?
    public var ratingLabel: String?
    public var cast: [TVPlayerCredit]
    public var directors: [TVPlayerCredit]

    public init(subtitle: String? = nil,
                seasonNumber: Int? = nil,
                episodeNumber: Int? = nil,
                synopsis: String? = nil,
                artworkURL: URL? = nil,
                year: Int? = nil,
                genres: [String] = [],
                runtimeMinutes: Int? = nil,
                ageRatingLabel: String? = nil,
                ratingLabel: String? = nil,
                cast: [TVPlayerCredit] = [],
                directors: [TVPlayerCredit] = []) {
        self.subtitle = subtitle
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.synopsis = synopsis
        self.artworkURL = artworkURL
        self.year = year
        self.genres = genres
        self.runtimeMinutes = runtimeMinutes
        self.ageRatingLabel = ageRatingLabel
        self.ratingLabel = ratingLabel
        self.cast = cast
        self.directors = directors
    }

    public var contextLabel: String? {
        let episodeTitle = subtitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let seasonNumber, let episodeNumber {
            let episodeCode = "T\(seasonNumber), E\(episodeNumber)"
            if let episodeTitle, !episodeTitle.isEmpty {
                return "\(episodeCode) · \(episodeTitle)"
            }
            return episodeCode
        }
        if let year {
            return String(year)
        }
        if let episodeTitle, !episodeTitle.isEmpty {
            return episodeTitle
        }
        return nil
    }
}
#endif
