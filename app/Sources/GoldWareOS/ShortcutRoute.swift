import Foundation

/// The dashboard's one-click buttons are `goldwareos://` links. This is the whole whitelist: three
/// fixed routes, each running the same handler as its voice phrase. Anything else is ignored, so
/// a link can never make the app run arbitrary input.
enum ShortcutRoute: String, CaseIterable {
    case letsWork = "lets-work"
    case lockUp = "lock-up"
    case clearOut = "clear-out"

    static let scheme = "goldwareos"

    /// nil unless the URL is exactly goldwareos://<route> (a trailing slash and a query or fragment
    /// are tolerated and ignored; extra path, credentials or a port are not).
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let host = url.host?.lowercased(),
              url.path.isEmpty || url.path == "/",
              url.user == nil, url.password == nil, url.port == nil,
              let route = ShortcutRoute(rawValue: host) else { return nil }
        self = route
    }
}
