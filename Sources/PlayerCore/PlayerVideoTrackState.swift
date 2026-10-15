import Foundation

/// 视频轨的**跨层状态**：可选清单 + 当前选中项。
///
/// 它对应「清晰度」这个界面概念：清单 = 可选档位，选中项 = 当前档位。
public struct PlayerVideoTrackState: Sendable, Equatable {
    /// 当前可用的视频轨（普通 mp4 只有 1 条；HLS 多码率每个档位一条）。
    public var tracks: [VideoTrack]
    /// 选中的轨 id。**没有"不选"这个状态** —— mpv 的 `vid=no` 等于没画面。
    public var selectedTrackID: Int64?

    public init(tracks: [VideoTrack] = [], selectedTrackID: Int64? = nil) {
        self.tracks = tracks
        self.selectedTrackID = selectedTrackID
    }

    /// **有没有"可选项"** —— UI 用它决定这个入口该不该出现。
    ///
    /// 单码率（普通 mp4 / 单档 HLS）只有 1 条视频轨：菜单里只有一项，
    /// 显示出来纯粹是噪音（点它也不会有任何变化）。
    /// ⇒ **不显示**，而不是显示一个只有一项的菜单（`docs/14` §三 记过这个取舍）。
    public var hasAlternatives: Bool { tracks.count > 1 }

    /// ⚠️ 与 `PlayerSubtitleState.isDisplaying` **同源**的教训：
    /// **内核报告的引用型状态（id）不是"对象存在"的证据，必须用清单去解析。**
    ///
    /// 换文件之后 mpv 的 `vid` 仍可能指向上一个文件的轨道 id ——
    /// 于是 `selectedTrackID` 非 nil、而 `tracks` 里根本没有这一条。
    /// 只判 `!= nil` 的界面会显示"当前 1280×720"，而实际在解的是别的东西。
    public var selectedTrack: VideoTrack? {
        guard let selectedTrackID else { return nil }
        return tracks.first { $0.id == selectedTrackID }
    }

    /// 界面上该显示的一行字。
    ///
    /// 解析不到选中项时显示 `—`（而不是"当前 xxx"）—— 让"选了个不存在的轨"看得见，
    /// 而不是静默显示一个可能是错的档位。
    public var label: String {
        guard let track = selectedTrack else { return "清晰度：—" }
        return "清晰度：\(track.label)"
    }
}
