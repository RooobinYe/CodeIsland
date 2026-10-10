import Foundation

/// Links into the project's GitHub releases.
public enum ReleaseNotesLink {
    public static let repositoryURL = "https://github.com/wxtsky/CodeIsland"

    /// The release page for `version`. Releases are tagged `v<version>`
    /// (`releases/tag/v1.0.34`). Anything that cannot be a
    /// tag — empty, whitespace inside, a stray URL — opens the release list
    /// instead of a 404.
    public static func url(forVersion version: String) -> URL {
        var tag = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if tag.hasPrefix("v") || tag.hasPrefix("V") { tag.removeFirst() }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-+")
        guard let first = tag.unicodeScalars.first,
              CharacterSet.decimalDigits.contains(first),
              tag.unicodeScalars.allSatisfy(allowed.contains) else {
            return URL(string: repositoryURL + "/releases")!
        }
        return URL(string: repositoryURL + "/releases/tag/v" + tag)!
    }
}
