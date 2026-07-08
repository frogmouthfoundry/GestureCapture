//
//  SoundPlayer.swift
//  GestureCapture
//

import AVFoundation

@MainActor
final class SoundPlayer {
    enum Sound: String, CaseIterable {
        case shutter
        case registerNotification = "notif-register"
        case successNotification = "notif-success"
    }

    private var players: [Sound: AVAudioPlayer] = [:]

    init() {
        for sound in Sound.allCases {
            guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "mp3") else { continue }
            players[sound] = try? AVAudioPlayer(contentsOf: url)
            players[sound]?.prepareToPlay()
        }
    }

    func play(_ sound: Sound) {
        guard let player = players[sound] else { return }
        player.currentTime = 0
        player.play()
    }
}
