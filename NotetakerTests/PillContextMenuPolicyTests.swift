import XCTest
@testable import nox

/// Tests for the pure decision layer of the right-click context menu
/// on the resting now-playing pill. The controller (`PillContextMenu`)
/// is a thin AppKit shell on top of these entries — by isolating the
/// rules here we can exercise every branch (play vs. paused, known vs.
/// unknown source app, URL-buildable vs. not) without touching NSMenu,
/// NSWorkspace, or any of the cross-app side-effects.
final class PillContextMenuPolicyTests: XCTestCase {

    // MARK: - Fixtures

    /// Canonical "Spotify is playing a track" snapshot. Most tests
    /// vary one field off this baseline so the difference under test
    /// is the only thing changing.
    private func spotifyPlaying() -> NowPlayingInfo {
        NowPlayingInfo(
            title: "Espresso",
            artist: "Sabrina Carpenter",
            album: "Short n' Sweet",
            artworkData: nil,
            isPlaying: true,
            sourceBundleID: "com.spotify.client",
            duration: 175,
            elapsedTime: 42,
            infoTimestamp: Date()
        )
    }

    private func appleMusicPlaying() -> NowPlayingInfo {
        NowPlayingInfo(
            title: "The Less I Know The Better",
            artist: "Tame Impala",
            album: "Currents",
            artworkData: nil,
            isPlaying: true,
            sourceBundleID: "com.apple.Music",
            duration: 216,
            elapsedTime: 80,
            infoTimestamp: Date()
        )
    }

    private func chromeTabPlaying() -> NowPlayingInfo {
        NowPlayingInfo(
            title: "YouTube Mix",
            artist: "Various",
            album: nil,
            artworkData: nil,
            isPlaying: true,
            sourceBundleID: "com.google.Chrome",
            duration: nil,
            elapsedTime: nil,
            infoTimestamp: Date()
        )
    }

    // MARK: - Full-menu construction

    func testMenuBuildsAllExpectedItemsWhenPlaying() {
        let entries = PillContextMenuPolicy.entries(.init(info: spotifyPlaying()))

        // Expected order, top to bottom, exact titles. If this ever
        // drifts the user-facing menu has silently rearranged — we
        // want a hard test failure, not "looks fine."
        let expected: [(title: String, isSeparator: Bool, isEnabled: Bool)] = [
            ("Pause", false, true),
            ("Next Track", false, true),
            ("Previous Track", false, true),
            ("Copy Track Link", false, true),
            ("Show in Spotify", false, true),
            ("", true, false),
            ("Open Music Settings…", false, true)
        ]
        XCTAssertEqual(entries.count, expected.count, "menu item count drifted")
        for (i, e) in entries.enumerated() {
            XCTAssertEqual(e.isSeparator, expected[i].isSeparator, "row \(i) separator mismatch")
            if !e.isSeparator {
                XCTAssertEqual(e.title, expected[i].title, "row \(i) title mismatch")
                XCTAssertEqual(e.isEnabled, expected[i].isEnabled, "row \(i) enabled mismatch")
            }
        }
    }

    func testPlayLabelFlipsWhenPaused() {
        var info = spotifyPlaying()
        info = NowPlayingInfo(
            title: info.title, artist: info.artist, album: info.album,
            artworkData: nil,
            isPlaying: false,
            sourceBundleID: info.sourceBundleID,
            duration: info.duration, elapsedTime: info.elapsedTime,
            infoTimestamp: info.infoTimestamp
        )
        let entries = PillContextMenuPolicy.entries(.init(info: info))
        XCTAssertEqual(entries.first?.title, "Play")
        // And the action is .play (not .pause / .togglePlayPause) so
        // a paused track gets the unambiguous resume signal.
        if case .command(let cmd) = entries.first?.action {
            XCTAssertEqual(cmd, .play)
        } else {
            XCTFail("first entry should be a command")
        }
    }

    func testEmptyMenuWhenNoInfo() {
        let entries = PillContextMenuPolicy.entries(.init(info: nil))
        XCTAssertEqual(entries, [], "no info → menu should be empty (controller suppresses pop-up)")
    }

    // MARK: - Copy Track Link

    func testCopyLinkEnabledForSpotify() {
        let entries = PillContextMenuPolicy.entries(.init(info: spotifyPlaying()))
        let copy = entries.first(where: { $0.title == "Copy Track Link" })
        XCTAssertNotNil(copy)
        XCTAssertTrue(copy?.isEnabled == true)
        if case .copyTrackLink(let url) = copy?.action {
            XCTAssertTrue(url.contains("open.spotify.com"), "Spotify URL should target open.spotify.com — got \(url)")
        } else {
            XCTFail("expected copyTrackLink action")
        }
    }

    func testCopyLinkEnabledForAppleMusic() {
        let entries = PillContextMenuPolicy.entries(.init(info: appleMusicPlaying()))
        let copy = entries.first(where: { $0.title == "Copy Track Link" })
        XCTAssertNotNil(copy)
        XCTAssertTrue(copy?.isEnabled == true)
        if case .copyTrackLink(let url) = copy?.action {
            XCTAssertTrue(url.contains("music.apple.com"), "Apple Music URL should target music.apple.com — got \(url)")
        } else {
            XCTFail("expected copyTrackLink action")
        }
    }

    func testCopyLinkDisabledWhenNoURL() {
        // Chrome/Safari/etc — no canonical "track" URL exists in the
        // metadata we receive, so we surface the item disabled rather
        // than silently dropping it (keeps the menu shape stable, so
        // muscle memory doesn't reach for an item that vanished).
        let entries = PillContextMenuPolicy.entries(.init(info: chromeTabPlaying()))
        let copy = entries.first(where: { $0.title == "Copy Track Link" })
        XCTAssertNotNil(copy)
        XCTAssertFalse(copy?.isEnabled == true)
    }

    func testCopyLinkDisabledWhenTitleOrArtistEmpty() {
        // Spotify source but no title — happens momentarily on track
        // change. We can't build a useful search URL without metadata.
        let info = NowPlayingInfo(
            title: "", artist: "", album: nil, artworkData: nil,
            isPlaying: true, sourceBundleID: "com.spotify.client",
            duration: nil, elapsedTime: nil, infoTimestamp: nil
        )
        let entries = PillContextMenuPolicy.entries(.init(info: info))
        let copy = entries.first(where: { $0.title == "Copy Track Link" })
        XCTAssertNotNil(copy)
        XCTAssertFalse(copy?.isEnabled == true)
    }

    // MARK: - Show in Source App

    func testShowInSourceUsesCurrentBundleID() {
        let entries = PillContextMenuPolicy.entries(.init(info: spotifyPlaying()))
        let show = entries.first(where: { $0.title.hasPrefix("Show in") })
        XCTAssertNotNil(show)
        if case .showInSource(let bundle) = show?.action {
            XCTAssertEqual(bundle, "com.spotify.client")
        } else {
            XCTFail("expected showInSource action with bundleID")
        }
        // Title should localize the bundle so the user sees the app
        // they'd be switching to, not "Source App."
        XCTAssertEqual(show?.title, "Show in Spotify")
    }

    func testShowInSourceFallbackTitleForUnknownBundle() {
        let info = NowPlayingInfo(
            title: "Unknown", artist: "Track", album: nil, artworkData: nil,
            isPlaying: true, sourceBundleID: "io.example.weirdplayer",
            duration: nil, elapsedTime: nil, infoTimestamp: nil
        )
        let entries = PillContextMenuPolicy.entries(.init(info: info))
        let show = entries.first(where: { $0.title.hasPrefix("Show in") })
        XCTAssertNotNil(show)
        XCTAssertEqual(show?.title, "Show in Source App")
        XCTAssertTrue(show?.isEnabled == true)
    }

    func testShowInSourceDisabledWhenNoBundle() {
        let info = NowPlayingInfo(
            title: "Mystery", artist: "Track", album: nil, artworkData: nil,
            isPlaying: true, sourceBundleID: nil,
            duration: nil, elapsedTime: nil, infoTimestamp: nil
        )
        let entries = PillContextMenuPolicy.entries(.init(info: info))
        let show = entries.first(where: { $0.title.hasPrefix("Show in") })
        XCTAssertNotNil(show)
        XCTAssertFalse(show?.isEnabled == true)
    }

    // MARK: - Helpers (pure-function spot checks)

    func testTrackURLEscapesSpacesAndSpecials() {
        let info = NowPlayingInfo(
            title: "Sun & Moon",
            artist: "Above & Beyond",
            album: nil, artworkData: nil, isPlaying: true,
            sourceBundleID: "com.spotify.client",
            duration: nil, elapsedTime: nil, infoTimestamp: nil
        )
        let url = PillContextMenuPolicy.trackURL(for: info)
        XCTAssertNotNil(url)
        // Spaces percent-encoded — raw spaces in a URL break copy-paste
        // into the browser's address bar on every major browser.
        XCTAssertFalse(url?.contains(" ") == true, "URL must not contain raw spaces: \(url ?? "nil")")
        // Ampersand is URL-significant and must be encoded; otherwise
        // Spotify's search engine reads it as a query-param delimiter.
        XCTAssertFalse(url?.contains("&Beyond") == true || url?.contains("Sun &") == true,
                       "ampersand must be percent-encoded: \(url ?? "nil")")
    }

    func testSourceDisplayNameKnownBundles() {
        XCTAssertEqual(PillContextMenuPolicy.sourceDisplayName(for: "com.spotify.client"), "Spotify")
        XCTAssertEqual(PillContextMenuPolicy.sourceDisplayName(for: "com.apple.Music"), "Apple Music")
        XCTAssertEqual(PillContextMenuPolicy.sourceDisplayName(for: "com.apple.podcasts"), "Apple Podcasts")
        XCTAssertEqual(PillContextMenuPolicy.sourceDisplayName(for: "com.google.Chrome"), "Chrome")
        XCTAssertEqual(PillContextMenuPolicy.sourceDisplayName(for: "com.apple.Safari"), "Safari")
        XCTAssertEqual(PillContextMenuPolicy.sourceDisplayName(for: "company.thebrowser.Browser"), "Arc")
    }

    func testSourceDisplayNameUnknownReturnsNil() {
        XCTAssertNil(PillContextMenuPolicy.sourceDisplayName(for: "io.example.weirdplayer"))
    }
}
