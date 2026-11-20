import XCTest
import UIKit
import WebKit
import SwiftUI
import SwiftProtobuf
import QuizGateKit

private final class FixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url!.lastPathComponent
        var data = Data()
        if path == "next-question" {
            var reply = Quizgate_NextQuestionReply()
            reply.question.questionID = UUID().uuidString
            reply.question.stem = "6 × 7 等于多少？"
            reply.question.options = ["42", "36", "48"]
            reply.rule.quizQuestionCount = 3
            reply.rule.thresholdMinutes = 30
            data = try! reply.serializedData()
        } else if path == "answer" {
            var reply = Quizgate_AnswerReply()
            reply.correct = true
            reply.pointsEarned = 3
            data = try! reply.serializedData()
        } else if path == "pet-shop" {
            var reply = Quizgate_PetStateReply()
            var pet = Quizgate_PetPrice()
            pet.petID = Quizgate_PetId(rawValue: 2)!
            pet.label = "猫咪"
            reply.priceList = [pet]; reply.ownedPetIds = [pet.petID]; reply.activePetID = pet.petID
            reply.pointsLeft = 35
            var item = Quizgate_AccessoryPrice()
            item.accessoryID = 9; item.slot = "hand"; item.label = "气球"; item.cost = 20
            reply.accessoryPrices = [item]; reply.ownedAccessoryIds = [9]; reply.outfit.hand = 9
            data = try! reply.serializedData()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": QuizGateAPI.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor final class ChildParityTests: XCTestCase {
    private func model() -> AppModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let model = AppModel(api: QuizGateAPI(base: "https://quizgate.invalid", configuration: config))
        model.state.deviceBound = true; model.state.deviceToken = "test-device"
        return model
    }

    func testThreeCorrectAnswersBeforeRelease() async {
        let model = model()
        await model.loadQuestion()
        XCTAssertEqual(model.roundTotal, 3)
        for count in 1...2 {
            await model.submitAnswer(index: 0)
            XCTAssertFalse(model.answeredCorrect)
            XCTAssertEqual(model.completedQuestions, count)
            XCTAssertNil(model.state.ledger.unlockUntilMs)
        }
        await model.submitAnswer(index: 0)
        XCTAssertTrue(model.answeredCorrect)
    }

    private func screenshot<V: View>(_ view: V, name: String) async throws {
        let host = UIHostingController(rootView: NavigationStack { view })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 900_000_000)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: 48 * 88 * 4)
        let colorCount = try pixels.withUnsafeMutableBytes { bytes -> Int in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 48, height: 88,
                bitsPerComponent: 8, bytesPerRow: 48 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 48, height: 88))
            var colors = Set<UInt32>()
            for i in stride(from: 0, to: bytes.count, by: 4) {
                colors.insert(UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]))
            }
            return colors.count
        }
        XCTAssertGreaterThan(colorCount, 12, "\(name) rendered without visible interface content")
        let item = XCTAttachment(data: try XCTUnwrap(image.pngData()), uniformTypeIdentifier: "public.png")
        item.name = name + ".png"; item.lifetime = .keepAlways; add(item)
        window.isHidden = true
    }

    func testChildScreens() async throws {
        let model = model()
        try await screenshot(HomeView().environmentObject(model), name: "home")
        try await screenshot(PetRoom().environmentObject(model), name: "shop")
        try await screenshot(PetRoom(wardrobe: true).environmentObject(model), name: "wardrobe")
        await model.loadQuestion()
        try await screenshot(QuizView().environmentObject(model), name: "quiz")
    }
}
