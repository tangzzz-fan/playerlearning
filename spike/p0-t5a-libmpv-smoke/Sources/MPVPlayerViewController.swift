import Libmpv
import UIKit

final class MPVPlayerViewController: UIViewController {
    var playUrl: URL?
    var status = PlayerStatusModel()

    private var metalLayer = MetalLayer()
    private var mpv: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "mpv.events", qos: .userInitiated)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        metalLayer.frame = view.bounds
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(metalLayer)
        setupMpv()
        if let url = playUrl {
            loadFile(url)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        metalLayer.frame = view.bounds
    }

    deinit {
        if let mpv = mpv {
            mpv_terminate_destroy(mpv)
        }
    }

    private func setupMpv() {
        guard let handle = mpv_create() else {
            onMain { self.status.lastError = "mpv_create returned nil" }
            return
        }
        mpv = handle
        checkError(mpv_request_log_messages(handle, "info"))
        var layerPointer = Unmanaged.passUnretained(metalLayer).toOpaque()
        checkError(mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &layerPointer))
        checkError(mpv_set_option_string(handle, "vo", "gpu-next"))
        checkError(mpv_set_option_string(handle, "gpu-api", "vulkan"))
        checkError(mpv_set_option_string(handle, "gpu-context", "moltenvk"))
        checkError(mpv_set_option_string(handle, "hwdec", "videotoolbox"))
        checkError(mpv_set_option_string(handle, "video-rotate", "no"))
        checkError(mpv_set_option_string(handle, "keep-open", "yes"))
        checkError(mpv_set_option_string(handle, "terminal", "no"))
        checkError(mpv_set_option_string(handle, "osc", "no"))
        _ = mpv_observe_property(handle, 0, "video-params/w", MPV_FORMAT_INT64)
        _ = mpv_observe_property(handle, 0, "video-params/h", MPV_FORMAT_INT64)
        _ = mpv_observe_property(handle, 0, "video-params/pixelformat", MPV_FORMAT_STRING)
        _ = mpv_observe_property(handle, 0, "time-pos", MPV_FORMAT_DOUBLE)
        _ = mpv_observe_property(handle, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        checkError(mpv_initialize(handle))
        mpv_set_wakeup_callback(handle, { context in
            guard let context = context else { return }
            let controller = Unmanaged<MPVPlayerViewController>.fromOpaque(context).takeUnretainedValue()
            controller.readEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
        onMain { self.status.lastError = "mpv_initialize ok" }
    }

    private func loadFile(_ url: URL) {
        command("loadfile", args: [url.absoluteString, "replace"])
    }

    func command(_ name: String, args: [String] = []) {
        guard let mpv = mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = ([name] + args).map { argument in
            strdup(argument).map { UnsafePointer<CChar>($0) }
        }
        cargs.append(nil)
        defer {
            for pointer in cargs {
                if let pointer = pointer {
                    free(UnsafeMutablePointer(mutating: pointer))
                }
            }
        }
        let result = mpv_command(mpv, &cargs)
        if result < 0 {
            onMain { self.status.lastError = "command \(name) failed: \(String(cString: mpv_error_string(result)))" }
        }
    }

    private func readEvents() {
        eventQueue.async { [weak self] in
            guard let self, let mpv = self.mpv else { return }
            while true {
                guard let event = mpv_wait_event(mpv, 0) else { break }
                let identifier = event.pointee.event_id
                if identifier == MPV_EVENT_NONE { break }
                self.handle(event: event.pointee)
                if identifier == MPV_EVENT_SHUTDOWN { break }
            }
        }
    }

    private func handle(event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return }
            let property = UnsafePointer<mpv_event_property>(OpaquePointer(data)).pointee
            handleProperty(property)
        case MPV_EVENT_SHUTDOWN:
            if let mpv = mpv {
                mpv_terminate_destroy(mpv)
            }
            mpv = nil
            onMain { self.status.lastEvent = "shutdown" }
        default:
            let name = mpv_event_name(event.event_id).map { String(cString: $0) } ?? "unknown"
            onMain {
                self.status.eventCount += 1
                self.status.lastEvent = name
            }
        }
    }

    private func handleProperty(_ property: mpv_event_property) {
        guard let data = property.data else { return }
        let name = String(cString: property.name)
        switch name {
        case "video-params/w":
            let value = UnsafePointer<Int64>(OpaquePointer(data)).pointee
            onMain { self.status.width = Int(value) }
        case "video-params/h":
            let value = UnsafePointer<Int64>(OpaquePointer(data)).pointee
            onMain { self.status.height = Int(value) }
        case "video-params/pixelformat":
            let value = UnsafePointer<UnsafePointer<CChar>>(OpaquePointer(data)).pointee
            let text = String(cString: value)
            onMain { self.status.pixelFormat = text }
        case "time-pos":
            let value = UnsafePointer<Double>(OpaquePointer(data)).pointee
            onMain { self.status.timePos = value }
        case "paused-for-cache":
            let value = UnsafePointer<Int32>(OpaquePointer(data)).pointee
            onMain { self.status.pausedForCache = value != 0 }
        default:
            break
        }
    }

    private func checkError(_ status: Int32) {
        if status < 0 {
            let text = String(cString: mpv_error_string(status))
            onMain { self.status.lastError = text }
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }
}
