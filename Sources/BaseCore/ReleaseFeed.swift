import Foundation

/// Reading the GitHub "latest release" answer. Kept here, without networking, so it is tested.
public enum ReleaseFeed {
    public static let repository = "maxbenschop/maben-base"
    public static let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    /// The file in each release that installed copies update from.
    public static let assetName = "Maben-Base.zip"

    public struct Release: Equatable, Sendable {
        public let version: String
        public let notes: String
        public let zip: URL
        public let page: URL
    }

    /// Nil for anything that isn't a published release with the update file attached.
    public static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String) == assetName }),
              let zip = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
              zip.scheme == "https",
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: (json["body"] as? String) ?? "", zip: zip, page: page)
    }

    /// Numeric comparison of dotted versions: 1.10 > 1.9, 1.0.1 > 1.0.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
