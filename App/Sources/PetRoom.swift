import SwiftUI
import QuizGateKit
import SwiftProtobuf

struct PetRoom: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var shop: Quizgate_PetStateReply?
    @State private var pet: Quizgate_PetId?
    @State private var draft = Quizgate_PetOutfit()
    @State private var working = false
    @State private var note = ""
    private let slots = ["head", "face", "neck", "hand"]
    private let titles = ["head": "头饰", "face": "脸饰", "neck": "颈饰", "hand": "手持物"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s4) {
                    if let shop {
                        Text("可用积分 \(shop.pointsLeft)").font(.title2.bold())
                        if let pet {
                            PetStage(pet: pet.rawValue, outfit: draft).frame(height: 240)
                        }
                        Text("萌宠商城").font(.headline)
                        ForEach(shop.priceList, id: \.petID) { item in
                            HStack {
                                Button(item.label) { preview(item.petID, shop) }
                                Spacer()
                                if shop.ownedPetIds.contains(item.petID) {
                                    Button(item.petID == shop.activePetID ? "使用中" : "换上") {
                                        var req = Quizgate_SelectPetRequest()
                                        req.petID = item.petID
                                        Task { await send("pet-wear", req, reset: true) }
                                    }.disabled(item.petID == shop.activePetID)
                                } else {
                                    Button("兑换 · \(item.cost) 积分") {
                                        var req = Quizgate_RedeemPetRequest()
                                        req.petID = item.petID
                                        req.expectedCost = item.cost
                                        Task { await send("pet-redeem", req, reset: false) }
                                    }.disabled(shop.pointsLeft < item.cost)
                                }
                            }
                        }
                        if let pet {
                            Text("试衣间").font(.title2.bold())
                            ForEach(slots, id: \.self) { slot in
                                VStack(alignment: .leading) {
                                    Text(titles[slot] ?? slot).font(.headline)
                                    Button("卸下") { select(0, slot) }
                                    ForEach(shop.accessoryPrices.filter { $0.slot == slot }, id: \.accessoryID) { item in
                                        HStack {
                                            Button(item.label) { select(item.accessoryID, slot) }
                                            if current(slot) == item.accessoryID { Image(systemName: "checkmark") }
                                            Spacer()
                                            if !shop.ownedAccessoryIds.contains(item.accessoryID) {
                                                Button("兑换 · \(item.cost) 积分") {
                                                    var req = Quizgate_RedeemAccessoryRequest()
                                                    req.accessoryID = item.accessoryID
                                                    req.expectedCost = item.cost
                                                    Task { await send("pet-accessory-redeem", req, reset: false) }
                                                }.disabled(shop.pointsLeft < item.cost)
                                            }
                                        }
                                    }
                                }.card()
                            }
                            Button("保存装扮") {
                                var request = Quizgate_SavePetOutfitRequest()
                                request.petID = pet
                                var wearing = draft
                                wearing.hand = draft.hand
                                request.outfit = wearing
                                Task { await send("pet-outfit", request, reset: true) }
                            }.disabled(!shop.ownedPetIds.contains(pet) ||
                                slots.contains { current($0) != 0 && !shop.ownedAccessoryIds.contains(current($0)) })
                        }
                    }
                    if !note.isEmpty { Text(note).accessibilityLabel(note) }
                    if working { ProgressView() }
                    Button("刷新商城") { Task { await refresh() } }
                }.disabled(working).padding().readableColumn()
            }
            .navigationTitle("我的萌宠")
            .toolbar { Button("完成") { dismiss() } }
        }
        .task { await refresh() }
        .onChange(of: model.state.deviceBound) { if !$0 { dismiss() } }
    }

    private func preview(_ id: Quizgate_PetId, _ state: Quizgate_PetStateReply) {
        pet = id
        draft = id == state.activePetID ? state.outfit : Quizgate_PetOutfit()
    }
    private func select(_ id: Int32, _ slot: String) {
        switch slot { case "head": draft.head = id; case "face": draft.face = id
        case "neck": draft.neck = id; default: draft.hand = id }
    }
    private func current(_ slot: String) -> Int32 {
        switch slot { case "head": return draft.head; case "face": return draft.face
        case "neck": return draft.neck; default: return draft.hand }
    }
    private func refresh() async { await send("pet-shop", Quizgate_SelectPetRequest(), reset: true) }
    @MainActor private func send<T: Message>(_ path: String, _ request: T, reset: Bool) async {
        guard !working, model.state.deviceBound, let token = model.state.deviceToken, let api = model.api else { return }
        working = true
        defer { working = false }
        do {
            let result = try await api.post(path, token: token, request: request, reply: Quizgate_PetStateReply.self)
            guard model.state.deviceBound, token == model.state.deviceToken else { return }
            shop = result
            note = result.reason.isEmpty && path != "pet-shop" ? "已保存" : result.reason
            if reset || pet == nil {
                let chosen = result.ownedPetIds.contains(result.activePetID) ? result.activePetID : result.priceList.first?.petID
                if let chosen { preview(chosen, result) }
            }
        } catch { note = "未能确认服务器结果，请刷新商城查看余额和装扮。" }
    }
}
