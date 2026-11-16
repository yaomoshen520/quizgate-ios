import XCTest
@testable import QuizGateKit

/// VpnPlan 是「掐网之后还得给答题留一条活路」那一格唯一的判据来源，
/// 两个进程都读它，所以它必须能在没有真机、没有隧道的情况下被钉死。
///
/// 每档正反例都要有：这一枚函数一旦在某个地址形态上静默返回 nil，
/// 表现不是崩溃也不是报错，而是「VPN 永远不起」——那正好是最难发现的形状。
final class VpnPlanTests: XCTestCase {

    func test公网IP字面量会被放行() {
        let host = VpnPlan.allowedIPv4(fromBase: "http://101.35.194.117:53600")
        XCTAssertEqual(host, "101.35.194.117")
    }

    func test没有端口和路径的IP也一样() {
        let host = VpnPlan.allowedIPv4(fromBase: "http://192.168.1.76")
        XCTAssertEqual(host, "192.168.1.76")
    }

    /// 域名一律不当作可放行地址：隧道一起来之后连 DNS 都被掐了，
    /// 那时再去解析必然失败。这一档返回 nil 的下游是「拒绝起隧道」，不是「裸掐」。
    func test域名不算可放行地址() {
        let host = VpnPlan.allowedIPv4(fromBase: "https://gate.example.com")
        XCTAssertNil(host, "域名解析不出 IP 就必须拒绝起隧道，不能当没这回事")
    }

    func test读不到地址时返回nil而不是空串() {
        XCTAssertNil(VpnPlan.allowedIPv4(fromBase: nil))
        XCTAssertNil(VpnPlan.allowedIPv4(fromBase: ""))
        XCTAssertNil(VpnPlan.allowedIPv4(fromBase: "不是个URL"))
    }

    /// 八位组越界的假 IP 必须被认出来。这类串本身不会出现在我们的配置里，
    /// 但如果 isIPv4Literal 放水，一条错误的 build setting 就会变成"配了个不生效的放行路由"。
    func test越界与畸形八位组都不是合法IP() {
        XCTAssertFalse(VpnPlan.isIPv4Literal("256.1.1.1"))
        XCTAssertFalse(VpnPlan.isIPv4Literal("10.1.1"))
        XCTAssertFalse(VpnPlan.isIPv4Literal("10.1.1."))
        XCTAssertFalse(VpnPlan.isIPv4Literal("10.1.1.1.1"))
        XCTAssertFalse(VpnPlan.isIPv4Literal("10.1.1.x"))
        XCTAssertFalse(VpnPlan.isIPv4Literal("10086.1.1.1"))
        XCTAssertTrue(VpnPlan.isIPv4Literal("10.0.0.1"))
        XCTAssertTrue(VpnPlan.isIPv4Literal("255.255.255.255"))
    }

    /// 放行那句日志必须把"成立"和"不成立"写成两种长相：
    /// 远程翻日志时这是唯一能分清「路由没生效」和「压根没配」的线索。
    func test日志措辞分得开成立与不成立() {
        XCTAssertTrue(VpnPlan.allowedNote(fromBase: "http://101.35.194.117:53600").contains("101.35.194.117"))
        let domain = VpnPlan.allowedNote(fromBase: "https://gate.example.com")
        XCTAssertTrue(domain.contains("不是 IPv4 字面量"), domain)
        let missing = VpnPlan.allowedNote(fromBase: nil)
        XCTAssertTrue(missing.contains("读不到"), missing)
    }

    /// 隧道网卡地址和放行地址不能落在同一个 /24：撞上了 excludedRoutes 会被自己的网卡吃掉，
    /// 表现是「配置全对但答题请求出不去」。这条断言是给将来换后端地址的人挡道的。
    func test网卡地址不与后端同段() {
        let tunnelFirst = VpnPlan.tunnelIPv4.split(separator: ".").first.map(String.init) ?? ""
        let allowed = VpnPlan.allowedIPv4(fromBase: "http://101.35.194.117:53600") ?? ""
        let backendFirst = allowed.split(separator: ".").first.map(String.init) ?? ""
        XCTAssertNotEqual(tunnelFirst, backendFirst, "两段撞车了，放行路由会被隧道自己的网卡吃掉")
    }

    // MARK: - 单独配的那枚放行 IP

    /// 生产就是这个形状：后端地址是域名，放行那一格靠单独配的 IP。
    /// 这一档打不绿，真机上看到的表现是「VPN 永远不起」——不崩、不报错、日志也只有一句拒绝。
    func test单独配的IP让域名后端也能放行() {
        let allowed = VpnPlan.allowedIPv4(fromBase: "https://agreement.example.com:53605",
                                          override: "101.35.194.117")
        XCTAssertEqual(allowed, "101.35.194.117")
    }

    /// 配了就用配的，不静默改用 base 里那枚：两边各读各的 Info.plist，
    /// 一旦允许回落，「主 App 用的是 A、扩展用的是 B」这种两边自洽的分裂就再也查不出来。
    func test单独配的IP优先于后端地址里的IP() {
        let allowed = VpnPlan.allowedIPv4(fromBase: "http://192.168.1.76:8080",
                                          override: "101.35.194.117")
        XCTAssertEqual(allowed, "101.35.194.117")
    }

    /// 单独配的那枚写坏了（域名）时**不许**回落到 base：
    /// 那是配置错误，而这一格猜错的方向是「把孩子的网掐了却没留活路」。
    func test单独配的域名不回落而是拒绝起隧道() {
        let allowed = VpnPlan.allowedIPv4(fromBase: "http://101.35.194.117",
                                          override: "gate.example.com")
        XCTAssertNil(allowed, "override 写了域名就必须当场判负，不能偷偷用 base 那枚")
    }

    func test单独配的越界IP也算写坏() {
        XCTAssertNil(VpnPlan.allowedIPv4(fromBase: "http://101.35.194.117", override: "256.1.1.1"))
    }

    /// 没配 = 空串 = 只有空白，三种都当成「没配」，好让老形状（base 直接写 IP）继续生效。
    /// 这一档很实在：Info.plist 少注入一项时读到的就是 nil，而不是报错。
    func test没配或空白当成没配并回落到后端地址() {
        XCTAssertEqual(VpnPlan.allowedIPv4(fromBase: "http://101.35.194.117", override: nil),
                       "101.35.194.117")
        XCTAssertEqual(VpnPlan.allowedIPv4(fromBase: "http://101.35.194.117", override: ""),
                       "101.35.194.117")
        XCTAssertEqual(VpnPlan.allowedIPv4(fromBase: "http://101.35.194.117", override: "   \n"),
                       "101.35.194.117")
    }

    /// 放行日志要留下「成的是哪一路」的痕迹：远程翻日志时，
    /// 「放行的是单独配的那枚」和「放行的是从后端地址顺手取的」得能分清。
    func test放行日志分得开两种来源() {
        let fromOverride = VpnPlan.allowedNote(fromBase: "https://gate.example.com",
                                               override: "101.35.194.117")
        XCTAssertTrue(fromOverride.contains("101.35.194.117"), fromOverride)
        XCTAssertTrue(fromOverride.contains("单独配"), fromOverride)

        let badOverride = VpnPlan.allowedNote(fromBase: "http://101.35.194.117",
                                              override: "gate.example.com")
        XCTAssertTrue(badOverride.contains("不是 IPv4 字面量"), badOverride)

        let fromBase = VpnPlan.allowedNote(fromBase: "http://101.35.194.117:53600", override: nil)
        XCTAssertTrue(fromBase.contains("101.35.194.117"), fromBase)
        XCTAssertFalse(fromBase.contains("单独配"), fromBase)
    }

    // MARK: - 能不能开掐网：egress

    /// 上面那些只钉住了「放行 IP 那一格」，而生产形状还差一格：后端是域名，
    /// 隧道一起来系统 DNS 就被我们自己黑洞掉，不往外留一枚 DNS，域名根本解析不出来，
    /// 放行那枚 IP 也就永远用不上。egress 是把这两格一起算清的唯一判据。
    func test生产形状是域名后端加两枚放行出口() {
        let plan = VpnPlan.egress(fromBase: "https://agreement.example.com:53605",
                                  allowIP: "101.35.194.117",
                                  allowDNS: "223.5.5.5,119.29.29.29")
        let want = VpnPlan.Egress(apiIPv4: "101.35.194.117", dnsIPv4s: ["223.5.5.5", "119.29.29.29"])
        XCTAssertEqual(plan, want)
    }

    /// 反例：域名后端却漏配 DNS 出口 ⇒ 必须判负。
    /// 判绿的下游是「起隧道并黑洞 DNS」，那正好是孩子答对也提交不上去的形状。
    func test域名后端漏配DNS出口时拒绝起隧道() {
        XCTAssertNil(VpnPlan.egress(fromBase: "https://gate.example.com",
                                    allowIP: "101.35.194.117",
                                    allowDNS: nil))
        XCTAssertNil(VpnPlan.egress(fromBase: "https://gate.example.com",
                                    allowIP: "101.35.194.117",
                                    allowDNS: "   "))
    }

    /// 后端本来就是 IP 字面量时不需要 DNS 出口，没配也照样成立 —— 老形状不能被新判据误伤。
    func testIP后端不需要DNS出口() {
        let plan = VpnPlan.egress(fromBase: "http://101.35.194.117:53600",
                                  allowIP: nil,
                                  allowDNS: nil)
        let want = VpnPlan.Egress(apiIPv4: "101.35.194.117", dnsIPv4s: [])
        XCTAssertEqual(plan, want)
    }

    /// 出口列表里有一枚写坏 ⇒ 整条判负，而不是「只用好的那枚」：
    /// 配错一项还照样起隧道，等于把「到底放行了几枚」变成只有系统知道的事。
    func testDNS出口里有一项写坏就整条判负() {
        XCTAssertNil(VpnPlan.egress(fromBase: "https://gate.example.com",
                                    allowIP: "101.35.194.117",
                                    allowDNS: "223.5.5.5,ns.example.com"))
        XCTAssertNil(VpnPlan.egress(fromBase: "https://gate.example.com",
                                    allowIP: "101.35.194.117",
                                    allowDNS: "256.1.1.1"))
    }

    func test后端地址读不到时一律判负() {
        XCTAssertNil(VpnPlan.egress(fromBase: nil, allowIP: "101.35.194.117",
                                    allowDNS: "223.5.5.5"))
        XCTAssertNil(VpnPlan.egress(fromBase: "不是个URL", allowIP: "101.35.194.117",
                                    allowDNS: "223.5.5.5"))
    }

    /// 尾随逗号与空格是这行配置最容易碰到的写法，不能被它们判负或塞进一枚空地址：
    /// NEIPv4Route 收到空串时系统那边会不会连整份设置一起拒，我不想拿一轮 CI 去问。
    func testDNS出口的空白项被丢掉而不是留成空地址() {
        let plan = VpnPlan.egress(fromBase: "https://gate.example.com",
                                  allowIP: "101.35.194.117",
                                  allowDNS: " 223.5.5.5 , , 119.29.29.29, ")
        let want = VpnPlan.Egress(apiIPv4: "101.35.194.117", dnsIPv4s: ["223.5.5.5", "119.29.29.29"])
        XCTAssertEqual(plan, want)
    }

    /// 这一档缺 DNS 出口时，日志要直接说出缺的是 DNS：三行「放行地址=…」里
    /// 只有这句能指到真正要改的那一行配置。
    func test缺DNS出口那句日志点名DNS() {
        let missing = VpnPlan.egressNote(fromBase: "https://gate.example.com",
                                         allowIP: "101.35.194.117",
                                         allowDNS: nil)
        XCTAssertTrue(missing.contains("放行 DNS=没配"), missing)

        let ok = VpnPlan.egressNote(fromBase: "https://gate.example.com",
                                    allowIP: "101.35.194.117",
                                    allowDNS: "223.5.5.5,119.29.29.29")
        XCTAssertTrue(ok.contains("223.5.5.5"), ok)
        XCTAssertTrue(ok.contains("119.29.29.29"), ok)

        let ipBackend = VpnPlan.egressNote(fromBase: "http://101.35.194.117:53600",
                                           allowIP: nil, allowDNS: nil)
        XCTAssertTrue(ipBackend.contains("不需要放行 DNS"), ipBackend)

        let badList = VpnPlan.egressNote(fromBase: "https://gate.example.com",
                                         allowIP: "101.35.194.117",
                                         allowDNS: "ns.example.com")
        XCTAssertTrue(badList.contains("里面有不是 IPv4 字面量的项"), badList)
    }
}
