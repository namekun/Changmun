/// What a tab asks of whatever shows its page (the view layer implements it).
@MainActor
protocol PageHost: AnyObject {
    /// The page of `tab` is back from a full screen window: the host that shows it makes sure it is in front again and as
    /// big as the host is, or lets go of it if the host shows another tab by now.
    func restore(for tab: Tab)
}

/// Who shows a tab's page, and where: the newest host to start showing it (in front, when the tab is shown, or behind, when
/// the AI is using the tab). When a view is replaced (a split that ends or begins, a peek kept as a tab) the host on its
/// way out is still updated after the new one took the page, and must not take it back.
struct PageOwner {
    enum Place {
        /// The page the host is there to show.
        case front
        /// A page kept in the window, not shown (held in the window behind the page in front).
        case behind
    }

    private(set) weak var host: (any PageHost)?
    private(set) var place = Place.front

    mutating func claim(_ new: any PageHost, as place: Place = .front) {
        host = new
        self.place = place
    }

    func owns(_ candidate: any PageHost) -> Bool { host === candidate }

    /// The host stops showing the page (it was passed on to another tab).
    mutating func release(_ old: any PageHost) {
        if host === old { host = nil }
    }
}
