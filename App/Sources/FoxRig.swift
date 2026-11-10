import SwiftUI
import UIKit
import QuizGateKit

/// `fox_rig.json` + 逐层位图，全 app 解一次。
///
/// 那张表是素材导出脚本从矢量母版现读的：叠放顺序、支点、围巾和表情这两组"按档位换图"的
/// 槽位都在里面。iOS 看不懂 SVG，所以只认这份表；表里没有的图层，视图就整块不画——
/// 半只狐狸比没有狐狸更容易被当成显示故障报上来。
///
/// 位图统一降到 256：入口那格是 44pt，按 512 解要多占四倍内存却一个像素都用不上。
/// 与 Android `FoxRig.kt` 同一套判据（那边是 inSampleSize，这边是 preparingThumbnail）。
@MainActor
final class FoxRig {

    /// 母版 viewBox 的边长：支点坐标是按它给的，绘制时再折算到显示方框。
    static let canvas: CGFloat = 512
    static let raster: CGFloat = 256

    struct Layer {
        let name: String
        let file: String
        let slot: String?
        let pivotX: CGFloat
        let pivotY: CGFloat

        /// 这一层这一刻该画哪张图；围巾跟家长挑的那一档走，表情跟动作档位走。
        func image(rig: FoxRig, scarf: String, expression: String) -> Image? {
            let key: String?
            switch slot {
            case "scarf": key = scarf
            case "face": key = rig.faces[expression] ?? rig.faces[AvatarPose.exprIdle]
            default: key = file
            }
            return key.flatMap { rig.images[$0] }
        }
    }

    let layers: [Layer]
    /// 按**表里的顺序**排，编号 N 对应第 N 条：这一条顺序就是 proto `AvatarId` 的编号顺序，
    /// 由素材导出脚本交叉断言看着，所以这里不再另写一张编号→名字的映射。
    let scarves: [String]
    let faces: [String: String]
    let images: [String: Image]

    private static var cached: FoxRig?
    private static var failed = false

    static func load() -> FoxRig? {
        if let cached { return cached }
        // 失败只试一次：素材缺一张不会自己长回来，每帧重试只是把启动路径拖慢。
        if failed { return nil }
        let rig = parse()
        if rig == nil { failed = true }
        cached = rig
        return rig
    }

    /// 编号 → 围巾图名。0（没选过）和认不出来的编号都返回 nil，调用方据此整块不画。
    func scarf(for avatarNumber: Int) -> String? {
        guard avatarNumber > 0 else { return nil }
        return scarves.indices.contains(avatarNumber - 1) ? scarves[avatarNumber - 1] : nil
    }

    private struct Table: Decodable {
        struct LayerRow: Decodable {
            let name: String
            let file: String
            let slot: String?
            let pivot: [CGFloat]?
        }
        struct ScarfRow: Decodable { let id: String; let file: String }
        struct FaceRow: Decodable { let name: String; let file: String }
        // 刻意不收 size：画布边长两端都写死 512（AvatarPose.canvas 也是它），
        // 多读一份只会多出一个"表和常量不一致时听谁的"的问题。
        let layers: [LayerRow]
        let scarves: [ScarfRow]
        let faces: [FaceRow]
    }

    private init(layers: [Layer], scarves: [String], faces: [String: String], images: [String: Image]) {
        self.layers = layers
        self.scarves = scarves
        self.faces = faces
        self.images = images
    }

    private static func parse() -> FoxRig? {
        guard let url = Bundle.main.url(forResource: "fox_rig", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode(Table.self, from: data) else {
            DiagLog.record("avatar", "几何表 fox_rig.json 读不出来，这一版不画狐狸", level: .error)
            return nil
        }
        guard !table.layers.isEmpty, !table.scarves.isEmpty, !table.faces.isEmpty else {
            DiagLog.record("avatar", "几何表是空的，这一版不画狐狸", level: .error)
            return nil
        }
        let layers = table.layers.map { row in
            Layer(name: row.name, file: row.file, slot: row.slot,
                  pivotX: row.pivot?.indices.contains(0) == true ? row.pivot![0] : 0,
                  pivotY: row.pivot?.indices.contains(1) == true ? row.pivot![1] : 0)
        }
        let scarves = table.scarves.map { $0.file }
        let faces = Dictionary(uniqueKeysWithValues: table.faces.map { ($0.name, $0.file) })

        // 表里点到的图名一个都不能缺：缺一张就说明素材和几何表不是同一次导出的。
        let wanted = Array(Set(layers.map { $0.file } + scarves + faces.values)).sorted()
        var images: [String: Image] = [:]
        var missing: [String] = []
        for name in wanted {
            if let image = decode(name) { images[name] = image } else { missing.append(name) }
        }
        guard missing.isEmpty else {
            DiagLog.record("avatar", "图层素材缺失：\(missing.joined(separator: ","))，这一版不画狐狸",
                           level: .error)
            return nil
        }
        return FoxRig(layers: layers, scarves: scarves, faces: faces, images: images)
    }

    /// 素材是平铺拷进包根的（XcodeGen 把 App/Resources 下的文件当资源逐个拷），
    /// 所以按文件名直接找，不走 Assets.xcassets —— 那边一个 imageset 就得一份 Contents.json，
    /// 18 张图多 18 个能被漏掉的地方，而漏掉的长相是"少一层"，不是编译错误。
    private static func decode(_ name: String) -> Image? {
        guard let path = Bundle.main.path(forResource: name, ofType: "png"),
              let full = UIImage(contentsOfFile: path) else { return nil }
        let target = CGSize(width: raster, height: raster)
        // preparingThumbnail 会按目标尺寸解码，不会先把 512×512 整张摊进内存。
        // 拿不到就退回原图：宁可多占四倍内存，也不要因为一次降采样失败就少画一层。
        let scaled = full.preparingThumbnail(of: target) ?? full
        return Image(uiImage: scaled)
    }
}
