import SwiftUI

struct ContentView: View {
    @StateObject private var status = PlayerStatusModel()
    @State private var urlText = "https://vjs.zencdn.net/v/oceans.mp4"
    @State private var url: URL?
    @State private var reloadToken = UUID()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let url = url {
                    MPVPlayerView(url: url, status: status)
                        .id(reloadToken)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            panel
        }
        .onAppear {
            if let bundled = Bundle.main.url(forResource: "pgs_subtitle", withExtension: "mkv") {
                urlText = bundled.lastPathComponent
                url = bundled
            } else {
                url = URL(string: urlText)
            }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                TextField("url", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Load") {
                    url = URL(string: urlText)
                    reloadToken = UUID()
                }
                .buttonStyle(.borderedProminent)
            }
            Text("size   : \(status.width)x\(status.height)")
            Text("pixfmt : \(status.pixelFormat)")
            Text("time   : \(String(format: "%.2f", status.timePos))s   cache: \(status.pausedForCache ? "waiting" : "ok")")
            Text("events : \(status.eventCount)   last: \(status.lastEvent)")
            Text("error  : \(status.lastError)")
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Color.green)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black)
    }
}
