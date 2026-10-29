import AppKit
import WebKit

extension Browser {
    // MARK: Memory

    /// Background tabs not shown for this long give up their web process; nil when that is turned off.
    var sleepAfter: TimeInterval? {
        let minutes = Preferences.shared.sleepMinutes
        return minutes > 0 ? Double(minutes) * 60 : nil
    }

    func startSleepingIdleTabs() {
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let age = self.archiveAfter { self.archiveIdleTabs(olderThan: age) }
                if let age = self.sleepAfter { self.sleepIdleTabs(olderThan: age) }
            }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.sleepIdleTabs(olderThan: 0) }
        }
        source.resume()
        memoryPressure = source
    }

    func sleepIdleTabs(olderThan age: TimeInterval) {
        let now = Date()
        let neverSleep = Preferences.shared.neverSleepHosts
        for tab in tabs where !isShown(tab) && !tab.isStart && now.timeIntervalSince(tab.lastShown) >= age && !tab.isInPictureInPicture
            && Preferences.canSleep(host: tab.url?.host(), neverSleep: neverSleep) && !AgentActivity.shared.holds(tab) {
            guard let webView = tab.webView, webView.fullscreenState == .notInFullscreen,
                  webView.cameraCaptureState == .none, webView.microphoneCaptureState == .none else { continue }
            webView.requestMediaPlaybackState { [weak self, weak tab] state in
                Task { @MainActor in
                    guard let self, let tab, !self.isShown(tab), state != .playing, !tab.isInPictureInPicture, !AgentActivity.shared.holds(tab),
                          tab.webView?.fullscreenState == .notInFullscreen else { return }
                    tab.sleep()
                }
            }
        }
    }

    /// Tabs not shown for this long are archived; nil when that is turned off.
    var archiveAfter: TimeInterval? {
        let hours = Preferences.shared.archiveHours
        return hours > 0 ? Double(hours) * 3600 : nil
    }

    /// Closes the tabs not looked at for `age` into the archive, but not those on screen, favorites and bookmarks, or
    /// ones playing, floating, in use by the AI, or using the camera or microphone. A private window keeps nothing.
    func archiveIdleTabs(olderThan age: TimeInterval, to archive: TabArchive? = nil) {
        guard !isPrivate else { return }
        let archive = archive ?? .shared
        let now = Date()
        let idle = tabs.filter { tab in
            !isShown(tab) && tab.bookmarkKey == nil && tab.url != nil && now.timeIntervalSince(tab.lastShown) >= age
                && !tab.isLoading && !tab.isPlayingAudio && !tab.isInPictureInPicture && !AgentActivity.shared.holds(tab)
                && tab.webView.map { $0.cameraCaptureState == .none && $0.microphoneCaptureState == .none } != false
        }
        guard !idle.isEmpty else { return }
        // A tab closes only once its entry is saved: an archive that can't be written keeps the tabs open.
        guard archive.add(idle.map { tab in
            TabArchive.Entry(url: tab.url?.absoluteString ?? "", title: tab.displayTitle, archived: now, group: groups.first { $0.id == tab.groupID }?.name, space: tab.spaceID,
                              customTitle: tab.customTitle)
        }) else { return }
        for tab in idle { close(tab.id, remember: false) }
    }

    /// Opens an archived tab again, back in its group if this window has one by that name.
    func reopen(_ entry: TabArchive.Entry, from archive: TabArchive? = nil) {
        guard let url = URL(string: entry.url) else { return }
        let archive = archive ?? .shared
        let tab = openTab(url: url, space: entry.space)
        tab.customTitle = entry.customTitle
        if let name = entry.group, let group = spaceGroups.first(where: { $0.name == name }) { addTab(tab.id, to: group.id) }
        archive.remove(entry.id)
    }
}
