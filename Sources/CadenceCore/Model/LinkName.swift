import Foundation

extension Link {
    /// How a link reads in a chip or a button: "PR #88" for a pull request, the key for a ticket (`ACME-12`), the host
    /// for anything else. Read from the address, so it holds for a link of any kind.
    public var displayName: String { LinkName(url).display }

    /// What a line that is only this link is titled: "PR #88 in acme/api" when the address names the repository, else
    /// the display name.
    public var titleName: String { LinkName(url).title }
}

/// A link's name, read from its address.
private struct LinkName {
    let display: String
    let title: String

    init(_ url: String) {
        let parts = URLComponents(string: url)
        let host = parts?.host.flatMap { $0.isEmpty ? nil : $0 }
        let path = (parts?.path ?? "").split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let pull = path.firstIndex(of: "pull"), pull + 1 < path.count, !path[pull + 1].isEmpty,
            path[pull + 1].allSatisfy({ $0.isASCII && $0.isNumber })
        {
            let name = "PR #\(path[pull + 1])"
            display = name
            title = pull >= 2 ? "\(name) in \(path[pull - 2])/\(path[pull - 1])" : name
        } else if let browse = path.firstIndex(of: "browse"), browse + 1 < path.count {
            display = path[browse + 1]
            title = display
        } else {
            display = host ?? url
            title = display
        }
    }
}
