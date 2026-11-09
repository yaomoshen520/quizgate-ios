import Foundation
import ManagedSettings
import ManagedSettingsUI
import UIKit
import QuizGateKit

/// 盾牌长什么样。这是系统固定模板，能改的只有颜色/图标/文案/按钮标题，
/// **塞不进任何交互视图** —— 所以答题不可能发生在盾牌里，只能发生在主 App。
final class ShieldConfigurationExtension: ShieldConfigurationDataSource {

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        makeConfiguration()
    }

    override func configuration(shielding application: Application,
                                in category: ActivityCategory) -> ShieldConfiguration {
        makeConfiguration()
    }

    override func configuration(shieldingWebDomain webDomain: WebDomain) -> ShieldConfiguration {
        makeConfiguration()
    }

    override func configuration(shieldingWebDomain webDomain: WebDomain,
                                in category: ActivityCategory) -> ShieldConfiguration {
        makeConfiguration()
    }

    private func makeConfiguration() -> ShieldConfiguration {
        var config = ShieldConfiguration()
        config.backgroundColor = UIColor(red: 0x2B / 255.0, green: 0x48 / 255.0, blue: 0xA8 / 255.0, alpha: 1)
        config.title = ShieldConfiguration.Label(text: "先答一道题", color: .white)
        // iOS 26.5 以下，点盾牌按钮无法可靠地跳到主 App（社区实测不通）。
        // 所以这句文案必须把「自己去打开哪个 App」说清楚，不能写「点击下方按钮」误导孩子。
        config.subtitle = ShieldConfiguration.Label(
            text: "打开 QuizGate，答对就能继续玩",
            color: UIColor(white: 1, alpha: 0.85)
        )
        config.primaryButtonLabel = ShieldConfiguration.Label(text: "我知道了", color: .white)
        config.primaryButtonBackgroundColor = UIColor(
            red: 0x4C / 255.0, green: 0x6E / 255.0, blue: 0xF5 / 255.0, alpha: 1
        )
        return config
    }
}