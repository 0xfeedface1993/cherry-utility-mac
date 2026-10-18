import CherryCore
import CherryPresentation
import ComposableArchitecture
import Foundation
import Testing
@testable import CherryFeatures

enum CustomFixture {
    /// 320 bytes of 0x11 with a valid header and CRC (same image as the FirmwareFeature tests).
    static let stock: FirmwarePackage = {
        var param = [UInt8](repeating: 0xFF, count: 256)
        param.replaceSubrange(64..<74, with: Array("046A01E205".utf8))
        param.replaceSubrange(80..<84, with: Array("FFEF".utf8))
        var fw = [UInt8](repeating: 0x11, count: 320)
        fw.replaceSubrange(0x18..<0x1C, with: [0x40, 0x01, 0, 0])
        let crc = Checksums.telinkCRC32(fw.dropLast(4))
        fw.replaceSubrange(316..<320, with: withUnsafeBytes(of: crc.littleEndian, Array.init))
        var code = [UInt8](repeating: 0, count: 256)
        code.replaceSubrange(48..<52, with: [0, 0, 0x01, 0x40])
        let image = try! UpdaterImage(param: param, code: code + fw)
        return FirmwarePackage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, source: .localFile(URL(fileURLWithPath: "/tmp/stock.exe")), fileMD5: "AA", image: image)
    }()
    static let date = Date(timeIntervalSince1970: 3_000_000)

    static let definition = try! FirmwareDefinition.decode(Data("""
    {"schema":1,"id":"fixture","name":"PIXIU 75 · 0117","firmware":{"vendorID":"046A","productID":"01E2","versionCode":"0117",
     "catalogName":"FIXTURE_0117","size":320,"crc32":"\(String(format: "%08X", stock.image.embeddedCRC))"},
     "palettes":[{"id":"p","items":[{"id":"stock","name":"原值","bytes":"11 11 11"},{"id":"play","name":"播放","bytes":"30 CD 00"}]}],
     "groups":[{"id":"g","name":"F 区","detail":"说明"},{"id":"h","name":"Mac"}],
     "options":[
      {"id":"fix","group":"g","name":"F 区固定","stability":"verified","values":[{"id":"on","name":"启用","edits":[{"offset":"0x40","original":"11 11 11 11","replacement":"22 22 22 22"}]}]},
      {"id":"mac.f8","group":"h","name":"F8","slot":{"offset":"0x60","original":"11 11 11","palette":"p"}}]}
    """.utf8), source: "fixture")

    static let catalog = DefinitionCatalog(definitions: [definition], rejected: [])

    static let a = FirmwareVariant(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, name: "A", definitionID: "fixture",
                                   selections: ["fix": "on"], createdAt: date, builtCRC: 0xAAAA_AAAA)
    static let b = FirmwareVariant(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!, name: "B", definitionID: "fixture",
                                   createdAt: date.addingTimeInterval(1))
    static let foreign = FirmwareVariant(name: "其他", definitionID: "other", createdAt: date)

    static var fix: CustomizationOption { definition.option("fix")! }
    static var f8: CustomizationOption { definition.option("mac.f8")! }

    static func install(_ variant: FirmwareVariant?) -> CustomFirmwareInstall {
        let package = FirmwarePackage(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C0")!,
            source: variant.map { .customBuild(variantID: $0.id, name: $0.name) } ?? stock.source, fileMD5: "BB", image: stock.image
        )
        return CustomFirmwareInstall(definitionID: "fixture", package: package, variant: variant)
    }

    /// Catalog, library (A, B and a foreign variant), stock image and device status loaded; A selected.
    static func loadedState(device crc: UInt32 = 0x1234_5678) -> CustomFirmwareFeature.State {
        var state = CustomFirmwareFeature.State(keyboard: .preview)
        state.catalog = .loaded(catalog)
        state.definitionID = "fixture"
        state.library = .loaded(.init(variants: [a, b, foreign], records: []))
        state.stock = .loaded(stock)
        state.device = .loaded(DeviceFirmwareStatus(version: 0, crc: crc))
        state.selectedVariantID = a.id
        state.editor = VariantEditor(base: a)
        return state
    }
}

@Suite("自定义固件：方案编辑器")
struct VariantEditorTests {
    typealias F = CustomFixture

    @Test func dirtyFieldsFollowTheDraftAndClearWhenBackToBase() {
        var editor = VariantEditor(base: F.a)
        editor.select("play", for: F.f8)
        editor.setName("A2")
        #expect(editor.dirty == [.option("mac.f8"), .name])
        #expect(editor.current.selections == ["fix": "on", "mac.f8": "play"])
        editor.select("stock", for: F.f8)
        editor.setName("A")
        #expect(editor == .viewing(base: F.a))
        editor.select("nope", for: F.f8)
        #expect(!editor.hasUnsavedChanges)
    }

    @Test func remoteUpdatesKeepLocalEdits() {
        var editor = VariantEditor(base: F.a)
        editor.select("stock", for: F.fix)
        var remote = F.a
        remote.name = "远端改名"
        remote.builtCRC = 0x1
        editor.rebase(onto: remote)
        #expect(editor.base == remote)
        #expect(editor.draft.name == "远端改名" && editor.draft.selections.isEmpty)
        #expect(editor.dirty == [.option("fix")])
    }

    @Test func saveRunsOnceAndFailureKeepsTheDraft() {
        var editor = VariantEditor(base: F.a)
        #expect(editor.beginSave() == nil)
        editor.setName("新名")
        let submitted = editor.beginSave()
        #expect(submitted?.name == "新名" && editor.isSaving)
        #expect(editor.beginSave() == nil)
        editor.setName("保存中不能改")
        #expect(editor.draft.name == "新名")
        editor.saveFailed()
        #expect(!editor.isSaving && editor.dirty == [.name])
        editor.discard()
        #expect(editor == .viewing(base: F.a))

        var stale = VariantEditor(base: FirmwareVariant(name: "S", definitionID: "fixture", selections: ["gone": "x", "fix": "on"], createdAt: F.date))
        stale.removeUnknownSelections(in: F.definition)
        #expect(stale.draft.selections == ["fix": "on"])
    }
}

@Suite("自定义固件：文案与展示")
struct CustomFirmwarePresentationTests {
    typealias F = CustomFixture

    @Test func namesAvoidCollisions() {
        #expect(CustomFirmwarePresentation.newVariantName(existing: []) == "方案 1")
        var taken = F.b
        taken.name = "方案 3"
        #expect(CustomFirmwarePresentation.newVariantName(existing: [F.a, taken]) == "方案 4")
        var copy = F.b
        copy.name = "A 副本"
        #expect(CustomFirmwarePresentation.copyName(of: "A", existing: [F.a]) == "A 副本")
        #expect(CustomFirmwarePresentation.copyName(of: "A", existing: [F.a, copy]) == "A 副本 2")
    }

    @Test func installedFirmwareIsDescribed() {
        var state = F.loadedState(device: F.stock.image.embeddedCRC)
        #expect(CustomFirmwarePresentation.installed(state).tone == .stock)
        #expect(CustomFirmwarePresentation.installed(state).headline == "原厂固件 0.1.1.7")

        state.device = .loaded(DeviceFirmwareStatus(version: 0, crc: 0xAAAA_AAAA))
        #expect(CustomFirmwarePresentation.installed(state).headline == "自定义方案「A」")
        #expect(CustomFirmwarePresentation.variantRows(state).map(\.isInstalled) == [true, false])

        let record = FirmwareFlashRecord(date: F.date, keyboard: KeyboardSummary.preview.id, definitionID: "fixture", crc: 0xBBBB,
                                         variantID: F.b.id, variantName: "B", selections: [:])
        state.library = .loaded(.init(variants: [F.a, F.b], records: [record]))
        state.device = .loaded(DeviceFirmwareStatus(version: 0, crc: 0xBBBB))
        let earlier = CustomFirmwarePresentation.installed(state)
        #expect(earlier.headline == "方案「B」的早期版本" && earlier.detail.hasSuffix("方案此后已修改"))

        state.device = .loaded(DeviceFirmwareStatus(version: 0, crc: 0xCCCC))
        #expect(CustomFirmwarePresentation.installed(state).tone == .warning)
        state.device = .failed("断开")
        #expect(CustomFirmwarePresentation.installed(state).detail == "断开")
    }

    @Test func optionsAndSummaryReflectTheDraft() {
        var state = F.loadedState()
        let groups = CustomFirmwarePresentation.groups(F.definition, editor: state.editor!)
        #expect(groups.map(\.id) == ["g", "h"])
        let fix = groups[0].options[0], f8 = groups[1].options[0]
        #expect(fix.isToggle && fix.isOn && fix.onValueID == "on" && !fix.isExperimental)
        #expect(!f8.isToggle && f8.choices.map(\.label) == ["原值（原厂）", "播放"] && f8.isExperimental)
        #expect(!groups[0].isExperimental && groups[1].isExperimental)
        #expect(CustomFirmwarePresentation.buildSummary(state) == "改动 1 项 · 4 字节 · 镜像 CRC 0xAAAAAAAA")

        state.editor?.select("play", for: F.f8)
        #expect(CustomFirmwarePresentation.buildSummary(state) == "改动 2 项 · 7 字节 · 保存后计算 CRC")
        state.stock = .idle
        #expect(CustomFirmwarePresentation.buildSummary(state).hasSuffix("获取原厂镜像后计算 CRC"))
    }

    @Test func errorsHaveMessages() {
        let errors: [CustomFirmwareError] = [
            .invalidDefinition(source: "x.cherryfw", issues: [.duplicateID("a"), .overlap(option: "a", other: "b", offset: 16), .malformed("?"), .noValues(option: "c")]),
            .definitionNotFound("d"), .invalidVariant("name"), .invalidVariant("json"), .stockNotInCatalog("N"),
            .stockMismatch(expectedCRC: 1, actualCRC: 2), .unknownSelections(["x"]), .variantDefinitionMismatch(variant: "v", definition: "d"),
            .verificationMismatch(expectedCRC: 1, actualCRC: 2),
        ]
        for error in errors { #expect(!(error as any Error).userMessage.isEmpty) }
        #expect((CustomFirmwareError.invalidVariant("name") as any Error).userMessage == "方案名称不能为空")
        #expect((errors[0] as any Error).userMessage.hasSuffix("等 4 项"))
    }
}

@MainActor
@Suite("CustomFirmwareFeature")
struct CustomFirmwareFeatureTests {
    typealias F = CustomFixture

    @Test func firstAppearanceLoadsEverythingAndIdentifiesTheStockImage() async {
        let store = TestStore(initialState: CustomFirmwareFeature.State(keyboard: .preview)) {
            CustomFirmwareFeature()
        } withDependencies: {
            $0.customFirmwareClient.loadDefinitions = { F.catalog }
            $0.customFirmwareClient.variants = { [F.a, F.b] }
            $0.customFirmwareClient.flashRecords = { [] }
            $0.customFirmwareClient.deviceFirmware = { _ in DeviceFirmwareStatus(version: 0, crc: F.stock.image.embeddedCRC) }
        }
        store.exhaustivity = .off
        await store.send(.task)
        await store.skipReceivedActions()
        #expect(store.state.definitionID == "fixture")
        #expect(store.state.variants == [F.a, F.b] && store.state.editor == VariantEditor(base: F.a))
        #expect(store.state.installed == .stock(definitionID: "fixture"))
        // Appearing again only re-reads the keyboard.
        await store.send(.task)
        await store.receive(\.readDevice)
        await store.receive(\.deviceLoaded)
        #expect(store.state.catalog == .loaded(F.catalog))
    }

    @Test func failedLoadsAreRetriedOnTheNextAppearance() async {
        let attempts = LockIsolated(0)
        let store = TestStore(initialState: CustomFirmwareFeature.State(keyboard: .preview)) {
            CustomFirmwareFeature()
        } withDependencies: {
            $0.customFirmwareClient.loadDefinitions = {
                attempts.withValue { $0 += 1 }
                if attempts.value == 1 { throw CherryError.storage("磁盘错误") }
                return F.catalog
            }
            $0.customFirmwareClient.variants = { [] }
            $0.customFirmwareClient.flashRecords = { [] }
            $0.customFirmwareClient.deviceFirmware = { _ in DeviceFirmwareStatus(version: 0, crc: 1) }
        }
        store.exhaustivity = .off
        await store.send(.task)
        await store.skipReceivedActions()
        #expect(store.state.catalog.errorMessage != nil)
        await store.send(.task)
        await store.skipReceivedActions()
        #expect(store.state.catalog == .loaded(F.catalog) && attempts.value == 2)
    }

    @Test func libraryArrivingAfterTheCatalogSelectsTheFirstVariant() async {
        let store = TestStore(initialState: CustomFirmwareFeature.State(keyboard: .preview)) { CustomFirmwareFeature() }
        await store.send(.catalogLoaded(.success(F.catalog))) {
            $0.catalog = .loaded(F.catalog)
            $0.definitionID = "fixture"
        }
        await store.send(.libraryLoaded(.success(.init(variants: [F.foreign, F.b, F.a], records: [])))) {
            $0.library = .loaded(.init(variants: [F.foreign, F.b, F.a], records: []))
            $0.selectedVariantID = F.b.id
            $0.editor = VariantEditor(base: F.b)
        }
        await store.send(.libraryLoaded(.failure(CustomFirmwareError.invalidVariant("json")))) {
            $0.library = .failed("方案文件无法解析")
        }
    }

    @Test func editsAreSavedOrKeptOnFailure() async {
        let saved: FirmwareVariant = {
            var v = F.a
            v.selections = ["fix": "on", "mac.f8": "play"]
            v.builtCRC = 0xABCD
            return v
        }()
        let attempts = LockIsolated(0)
        let store = TestStore(initialState: F.loadedState()) {
            CustomFirmwareFeature()
        } withDependencies: {
            $0.customFirmwareClient.saveVariant = { variant, definition, stock in
                attempts.withValue { $0 += 1 }
                #expect(variant.selections == ["fix": "on", "mac.f8": "play"] && definition.id == "fixture" && stock == F.stock)
                if attempts.value == 1 { throw CustomFirmwareError.invalidVariant("name") }
                return saved
            }
        }
        await store.send(.optionChanged(optionID: "mac.f8", valueID: "play")) { $0.editor?.select("play", for: F.f8) }
        await store.send(.saveTapped) { _ = $0.editor?.beginSave() }
        await store.receive(\.variantSaved) {
            $0.editor?.saveFailed()
            $0.notice = "方案名称不能为空"
        }
        await store.send(.saveTapped) {
            _ = $0.editor?.beginSave()
            $0.notice = nil
        }
        await store.receive(\.variantSaved) {
            $0.replaceVariant(saved)
            $0.editor = .viewing(base: saved)
        }
        await store.send(.saveTapped)
    }

    @Test func switchingVariantsWithUnsavedChangesAsksFirst() async {
        let store = TestStore(initialState: F.loadedState()) { CustomFirmwareFeature() }
        await store.send(.nameChanged("A*")) { $0.editor?.setName("A*") }
        await store.send(.selectVariant(F.b.id)) { $0.alert = CustomFirmwarePresentation.discardAlert(selecting: F.b.id) }
        await store.send(.alert(.presented(.discardAndSelect(F.b.id)))) {
            $0.alert = nil
            $0.selectedVariantID = F.b.id
            $0.editor = VariantEditor(base: F.b)
        }
        await store.send(.discardTapped)
        await store.send(.selectVariant(F.a.id)) {
            $0.selectedVariantID = F.a.id
            $0.editor = VariantEditor(base: F.a)
        }
    }

    @Test func variantsAreCreatedDuplicatedAndDeleted() async {
        let created = FirmwareVariant(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D0")!, name: "方案 3", definitionID: "fixture", createdAt: F.date)
        let copied = FirmwareVariant(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!, name: "A 副本", definitionID: "fixture",
                                     selections: F.a.selections, createdAt: F.date)
        let store = TestStore(initialState: F.loadedState()) {
            CustomFirmwareFeature()
        } withDependencies: {
            $0.customFirmwareClient.createVariant = { name, _, source in
                if let source {
                    #expect(name == "A 副本" && source == F.a)
                    return copied
                }
                #expect(name == "方案 3")
                return created
            }
            $0.customFirmwareClient.deleteVariant = { id in #expect(id == copied.id) }
        }
        await store.send(.newVariantTapped)
        await store.receive(\.variantCreated) {
            $0.replaceVariant(created)
            $0.selectedVariantID = created.id
            $0.editor = VariantEditor(base: created)
        }
        await store.send(.selectVariant(F.a.id)) {
            $0.selectedVariantID = F.a.id
            $0.editor = VariantEditor(base: F.a)
        }
        await store.send(.duplicateVariantTapped)
        await store.receive(\.variantCreated) {
            $0.replaceVariant(copied)
            $0.selectedVariantID = copied.id
            $0.editor = VariantEditor(base: copied)
        }
        await store.send(.deleteVariantTapped) { $0.alert = CustomFirmwarePresentation.deleteAlert("A 副本", id: copied.id) }
        await store.send(.alert(.presented(.confirmDelete(copied.id)))) { $0.alert = nil }
        await store.receive(\.variantDeleted) {
            $0.library = .loaded(.init(variants: [F.a, F.b, F.foreign, created], records: []))
            $0.selectedVariantID = F.a.id
            $0.editor = VariantEditor(base: F.a)
        }
    }

    @Test func variantIsFlashedVerifiedAndRecognised() async {
        let install = F.install(F.a)
        let status = DeviceFirmwareStatus(version: 0x0117, crc: 0xAAAA_AAAA)
        let record = FirmwareFlashRecord(date: F.date, keyboard: KeyboardSummary.preview.id, definitionID: "fixture", crc: 0xAAAA_AAAA,
                                         variantID: F.a.id, variantName: "A", selections: F.a.selections)
        let store = TestStore(initialState: F.loadedState()) {
            CustomFirmwareFeature()
        } withDependencies: {
            $0.customFirmwareClient.prepareInstall = { variant, definition, stock in
                #expect(variant == F.a && definition.id == "fixture" && stock == F.stock)
                return install
            }
            $0.customFirmwareClient.flash = { candidate, keyboard, progress in
                #expect(candidate == install && keyboard == .preview)
                await progress(.started(totalReports: 3))
                await progress(.transferred(reports: 2, totalReports: 3, percent: 100))
                await progress(.verifying)
                return .confirmed
            }
            $0.customFirmwareClient.verify = { candidate, id in
                #expect(candidate == install && id == KeyboardSummary.preview.id)
                return status
            }
            $0.customFirmwareClient.variants = { [F.a, F.b, F.foreign] }
            $0.customFirmwareClient.flashRecords = { [record] }
        }
        #expect(store.state.canInstall)
        await store.send(.installTapped) { $0.phase = .preparing }
        await store.receive(\.installPrepared) {
            $0.phase = .idle
            $0.install = install
            $0.alert = CustomFirmwarePresentation.installAlert(install, keyboard: .preview, sameImage: false)
        }
        await store.send(.alert(.presented(.confirmInstall))) {
            $0.alert = nil
            $0.phase = .flashing(sent: 0, total: 0, percent: 0)
        }
        await store.receive(\.flashProgress) { $0.phase = .flashing(sent: 0, total: 3, percent: 0) }
        await store.receive(\.flashProgress) { $0.phase = .flashing(sent: 2, total: 3, percent: 100) }
        await store.receive(\.flashProgress) { $0.phase = .verifyingImage }
        await store.receive(\.flashFinished) { $0.phase = .waitingForReboot }
        await store.receive(\.verifyFinished) {
            $0.device = .loaded(status)
            $0.phase = .finished(target: "方案「A」", status: status)
            $0.install = nil
        }
        await store.receive(\.reloadLibrary)
        await store.receive(\.libraryLoaded) { $0.library = .loaded(.init(variants: [F.a, F.b, F.foreign], records: [record])) }
        #expect(store.state.installed == .variant(id: F.a.id, definitionID: "fixture"))
    }

    @Test func failedFlashAndFailedVerificationAreReported() async {
        let install = F.install(nil)
        let calls = LockIsolated(0)
        let store = TestStore(initialState: F.loadedState()) {
            CustomFirmwareFeature()
        } withDependencies: {
            $0.customFirmwareClient.prepareInstall = { variant, _, _ in
                #expect(variant == nil)
                return install
            }
            $0.customFirmwareClient.flash = { _, _, _ in
                calls.withValue { $0 += 1 }
                if calls.value == 1 { throw CherryError.timeout("测试") }
                return .deviceRebooted
            }
            $0.customFirmwareClient.verify = { _, _ in throw CustomFirmwareError.verificationMismatch(expectedCRC: 1, actualCRC: 2) }
            $0.customFirmwareClient.deviceFirmware = { _ in DeviceFirmwareStatus(version: 0, crc: 2) }
            $0.customFirmwareClient.variants = { [F.a, F.b, F.foreign] }
            $0.customFirmwareClient.flashRecords = { [] }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.restoreStockTapped)
        await store.receive(\.installPrepared) { $0.alert = CustomFirmwarePresentation.installAlert(install, keyboard: .preview, sameImage: false) }
        await store.send(.alert(.presented(.confirmInstall)))
        await store.receive(\.flashFinished) {
            $0.phase = .failed(CherryError.timeout("测试").userMessage)
            $0.install = nil
        }
        await store.receive(\.readDevice)
        await store.receive(\.deviceLoaded) { $0.device = .loaded(DeviceFirmwareStatus(version: 0, crc: 2)) }

        await store.send(.restoreStockTapped)
        await store.receive(\.installPrepared)
        await store.send(.alert(.presented(.confirmInstall)))
        await store.receive(\.flashFinished) { $0.phase = .waitingForReboot }
        await store.receive(\.verifyFinished) {
            $0.phase = .failed(CustomFirmwarePresentation.verificationFailed("键盘读回的固件 CRC 为 0x00000002，与写入的 0x00000001 不一致"))
            $0.install = nil
        }
        await store.skipReceivedActions()

        await store.send(.restoreStockTapped)
        await store.receive(\.installPrepared)
        await store.send(.alert(.dismiss)) { $0.install = nil }
    }

    @Test func guardsAgainstStaleResultsAndMissingWiredConnection() async {
        var keyboard = KeyboardSummary.preview
        keyboard = KeyboardSummary(id: keyboard.id, product: keyboard.product, manufacturer: keyboard.manufacturer, serialNumber: nil,
                                   transport: "Bluetooth", releaseNumber: keyboard.releaseNumber, interfaces: [keyboard.interfaces[1]])
        var state = F.loadedState()
        state.keyboard = keyboard
        let store = TestStore(initialState: state) {
            CustomFirmwareFeature()
        } withDependencies: {
            $0.customFirmwareClient.deviceFirmware = { _ in DeviceFirmwareStatus(version: 0, crc: 9) }
        }
        #expect(!store.state.canInstall && !store.state.canRestore)
        await store.send(.readDevice) { $0.device = .failed(CustomFirmwarePresentation.needsWiredConnection) }
        await store.send(.installTapped)
        await store.send(.stockLoaded(definitionID: "other", .success(F.stock)))
        await store.send(.selectDefinition("other"))

        await store.send(.keyboardUpdated(nil)) { $0.isConnected = false }
        await store.send(.keyboardUpdated(.preview)) {
            $0.isConnected = true
            $0.keyboard = .preview
        }
        await store.receive(\.readDevice) { $0.device = .loading }
        await store.receive(\.deviceLoaded) { $0.device = .loaded(DeviceFirmwareStatus(version: 0, crc: 9)) }
    }

    @Test func stockImageIsFetchedOrImported() async {
        var state = F.loadedState()
        state.stock = .idle
        let store = TestStore(initialState: state) {
            CustomFirmwareFeature()
        } withDependencies: {
            $0.customFirmwareClient.stockPackage = { definition in
                #expect(definition.id == "fixture")
                throw CustomFirmwareError.stockNotInCatalog("FIXTURE_0117")
            }
            $0.customFirmwareClient.importStock = { _, url in
                #expect(url.lastPathComponent == "stock.exe")
                return F.stock
            }
        }
        #expect(!store.state.canInstall)
        await store.send(.fetchStockTapped) { $0.stock = .loading }
        await store.receive(\.stockLoaded) { $0.stock = .failed("Cherry 官方目录中没有 FIXTURE_0117，可以改为选择本地升级包") }
        await store.send(.importStockTapped) { $0.isImporting = true }
        await store.send(.stockFileSelected(.success(URL(fileURLWithPath: "/tmp/stock.exe")))) { $0.stock = .loading }
        await store.receive(\.stockLoaded) { $0.stock = .loaded(F.stock) }
        #expect(store.state.canInstall)
    }
}
