import Foundation

final class PlayerStatusModel: ObservableObject {
    @Published var width = 0
    @Published var height = 0
    @Published var pixelFormat = "-"
    @Published var timePos = 0.0
    @Published var pausedForCache = false
    @Published var eventCount = 0
    @Published var lastEvent = "-"
    @Published var lastError = "-"
}
