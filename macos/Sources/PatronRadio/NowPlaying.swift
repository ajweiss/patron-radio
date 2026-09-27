import AppKit
import MediaPlayer
import PatronRadioCore

/// Control Center "Now Playing", media keys and AirPods/headset buttons — the
/// macOS counterpart of the widget's MPRIS interface.
@MainActor
final class NowPlayingBridge {
    private let controller: RadioController

    init(controller: RadioController) {
        self.controller = controller
        let center = MPRemoteCommandCenter.shared()
        // For live radio, pause = stop (there's no buffer worth holding).
        center.playCommand.addTarget { [weak self] _ in
            guard let c = self?.controller else { return .commandFailed }
            if !c.isPlaying && !c.isBuffering { c.primaryAction() }
            return .success
        }
        for cmd in [center.pauseCommand, center.stopCommand] {
            cmd.addTarget { [weak self] _ in
                guard let c = self?.controller else { return .commandFailed }
                if c.isPlaying || c.isBuffering { c.stop() }
                return .success
            }
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.controller.primaryAction()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.controller.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.controller.previous()
            return .success
        }
        for cmd in [center.seekForwardCommand, center.seekBackwardCommand, center.changePlaybackPositionCommand,
                    center.skipForwardCommand, center.skipBackwardCommand] {
            cmd.isEnabled = false
        }
        observeContinuously { [weak self] in self?.update() }
    }

    private func update() {
        let c = controller
        let info = MPNowPlayingInfoCenter.default()
        guard c.hasCurrentStation else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            return
        }
        // Title falls back to the station name; station shows as artist/album,
        // which most controllers render as the second line.
        var dict: [String: Any] = [
            MPMediaItemPropertyTitle: c.currentTrack.isEmpty ? c.currentStationName : c.currentTrack,
            MPMediaItemPropertyArtist: c.currentStationName,
            MPMediaItemPropertyAlbumTitle: c.currentStationCity.isEmpty ? c.currentStationName : c.currentStationCity,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: c.isPlaying ? 1.0 : 0.0,
        ]
        if let url = URL(string: c.currentStation?.url ?? "") { dict[MPNowPlayingInfoPropertyAssetURL] = url }
        if let image = NSImage(systemSymbolName: "radio", accessibilityDescription: nil) {
            dict[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: CGSize(width: 256, height: 256)) { _ in image }
        }
        info.nowPlayingInfo = dict
        // Report "paused" (not "stopped") while a station is loaded so controllers
        // keep showing it and the play key can resume — as the widget does for MPRIS.
        info.playbackState = (c.isPlaying || c.isBuffering) ? .playing : .paused
    }
}
