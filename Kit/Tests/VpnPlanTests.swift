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
}
