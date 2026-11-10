// [device-access] Music for Device Access (docs/device-access.md): MPMediaLibrary's authorization, what's playing,
// and play/pause/next/previous. MediaPlayer isn't on the Mac (DeviceAccess.Kind.available agrees), so the real work
// is `#if`'d out there. The Simulator has no Music library: `music.now` just says nothing's playing, and a `play`
// query always comes back as no match — both are exercised by the tests.

import Foundation

#if !targetEnvironment(macCatalyst)
import MediaPlayer

enum MusicAccess: DeviceAccessHandler {
    static let kind = DeviceAccess.Kind.music

    static var permission: DeviceAccessPermission {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .denied // .denied, .restricted
        }
    }

    static func requestPermission(turningOn key: String) async -> Bool {
        let status = MPMediaLibrary.authorizationStatus()
        guard status != .denied, status != .restricted else { return false }
        guard status == .notDetermined else { return true }
        return await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    static func answer(_ request: DeviceAccess.Request, scopes: Set<String>) async -> DeviceAccess.Answer {
        guard MPMediaLibrary.authorizationStatus() == .authorized else { return .unavailable(DeviceAccess.notAllowedWords(.music)) }
        let player = MPMusicPlayerController.systemMusicPlayer
        switch request.op {
        case "music.now": return answer(for: player)
        case "music.control":
            guard let action = DeviceAccess.musicAction(request) else {
                return .failed("“action” must be play, pause, next or previous.")
            }
            switch action {
            case .pause: player.pause()
            case .next: player.skipToNextItem()
            case .previous: player.skipToPreviousItem()
            case .play:
                if let query = request.string("query", max: 120), !query.isEmpty {
                    guard let target = await MusicLibrary.find(query) else { return .failed("Nothing in your library matches “\(query)”.") }
                    player.setQueue(with: target.query)
                }
                player.play()
            }
            return answer(for: player)
        default: return .unavailable(DeviceAccess.unknownWords)
        }
    }

    /// The player is driven on the main thread (MPMusicPlayerController isn't safe off it).
    private static func answer(for player: MPMusicPlayerController) -> DeviceAccess.Answer {
        let item = player.nowPlayingItem
        return DeviceAccess.musicAnswer(state: stateWord(player.playbackState), title: item?.title, artist: item?.artist, album: item?.albumTitle,
                                        durationSeconds: item.map(\.playbackDuration), positionSeconds: item == nil ? nil : player.currentPlaybackTime)
    }

    private static func stateWord(_ state: MPMusicPlaybackState) -> String {
        switch state {
        case .playing, .seekingForward, .seekingBackward: "playing"
        case .paused, .interrupted: "paused"
        default: "stopped"
        }
    }
}

/// Searching the library, off the main thread (MPMediaQuery's `items`/`collections` read it synchronously). What it
/// finds goes back as a persistent ID, and the main thread queues it with a query for that ID.
nonisolated enum MusicLibrary {
    enum Target: Sendable {
        case song(MPMediaEntityPersistentID), album(MPMediaEntityPersistentID)
        case artist(MPMediaEntityPersistentID), playlist(MPMediaEntityPersistentID)

        var query: MPMediaQuery {
            let (query, id, property): (MPMediaQuery, MPMediaEntityPersistentID, String) = switch self {
            case .song(let id): (.songs(), id, MPMediaItemPropertyPersistentID)
            case .album(let id): (.songs(), id, MPMediaItemPropertyAlbumPersistentID)
            case .artist(let id): (.songs(), id, MPMediaItemPropertyArtistPersistentID)
            case .playlist(let id): (.playlists(), id, MPMediaPlaylistPropertyPersistentID)
            }
            query.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: id), forProperty: property))
            return query
        }
    }

    /// A song, then an album, an artist, or a playlist — the first whose title (or artist) contains the query.
    @concurrent static func find(_ query: String) async -> Target? {
        if let song = MPMediaQuery.songs().items?.first(where: { DeviceAccess.musicMatches([$0.title, $0.artist], query: query) }) {
            return .song(song.persistentID)
        }
        if let album = MPMediaQuery.albums().collections?.first(where: {
            DeviceAccess.musicMatches([$0.representativeItem?.albumTitle, $0.representativeItem?.artist], query: query)
        }), let item = album.representativeItem {
            return .album(item.albumPersistentID)
        }
        if let artist = MPMediaQuery.artists().collections?.first(where: { DeviceAccess.musicMatches([$0.representativeItem?.artist], query: query) }),
           let item = artist.representativeItem {
            return .artist(item.artistPersistentID)
        }
        if let playlist = MPMediaQuery.playlists().collections?.lazy.compactMap({ $0 as? MPMediaPlaylist })
            .first(where: { DeviceAccess.musicMatches([$0.name], query: query) }) {
            return .playlist(playlist.persistentID)
        }
        return nil
    }
}
#else
enum MusicAccess: DeviceAccessHandler {
    static let kind = DeviceAccess.Kind.music
    static var permission: DeviceAccessPermission { .notAsked }
    static func requestPermission(turningOn key: String) async -> Bool { false }
    static func answer(_ request: DeviceAccess.Request, scopes: Set<String>) async -> DeviceAccess.Answer {
        .unavailable(DeviceAccess.notHereWords(.music))
    }
}
#endif
