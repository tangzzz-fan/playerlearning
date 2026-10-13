import SwiftUI

struct MPVPlayerView: UIViewControllerRepresentable {
    let url: URL
    let status: PlayerStatusModel

    func makeUIViewController(context: Context) -> MPVPlayerViewController {
        let controller = MPVPlayerViewController()
        controller.status = status
        controller.playUrl = url
        return controller
    }

    func updateUIViewController(_ controller: MPVPlayerViewController, context: Context) {}
}
