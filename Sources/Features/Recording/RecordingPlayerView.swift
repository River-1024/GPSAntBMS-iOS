import AVKit
import SwiftUI

struct RecordingPlayerView: View {
    let url: URL

    var body: some View {
        VideoPlayer(player: AVPlayer(url: url))
            .background(Color.black)
            .navigationTitle("播放录像")
            .navigationBarTitleDisplayMode(.inline)
    }
}
