import CherryCore
import ComposableArchitecture
import Foundation
import Testing
@testable import CherryFeatures

@MainActor
@Suite("配置预设导入、导出与删除")
struct ConfigurationIOBranchTests {
    @Test func importsPresetAndExportsSelectedPreset() async {
        var imported = ProfilePreset.preview
        imported.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        imported.name = "导入的预设"
        let preset = imported
        let url = URL(fileURLWithPath: "/tmp/test.cherryprofile")
        let store = TestStore(initialState: ConfigurationFeatureTests.loadedState()) { ConfigurationFeature() } withDependencies: {
            $0.presetClient.importFile = { received in #expect(received == url); return preset }
        }
        await store.send(.importTapped) { $0.isImporting = true }
        await store.send(.importFileSelected(.success(url)))
        await store.receive(\.presetImported) {
            $0.presets = .loaded([preset, .preview])
            $0.banner = .init(message: "已导入预设「导入的预设」", isError: false)
        }
        await store.send(.exportTapped(preset.id)) { $0.exportingPreset = preset }
        await store.send(.exportFinished(.success(url))) {
            $0.exportingPreset = nil
            $0.banner = .init(message: "已导出到 test.cherryprofile", isError: false)
        }
        await store.send(.dismissBanner) { $0.banner = nil }
    }

    @Test func deletingPresetRequiresConfirmationThenRemovesOnlyThatPreset() async {
        let preset = ProfilePreset.preview
        let store = TestStore(initialState: ConfigurationFeatureTests.loadedState()) { ConfigurationFeature() } withDependencies: {
            $0.presetClient.delete = { #expect($0 == preset.id) }
        }
        await store.send(.deletePresetTapped(preset.id)) { $0.alert = ConfigurationFeature.deleteAlert(preset) }
        #expect(store.state.presets.value == [preset])
        await store.send(.alert(.presented(.confirmDelete(preset.id)))) { $0.alert = nil }
        await store.receive(\.presetDeleted) { $0.presets = .loaded([]) }
    }

    @Test func fileAndStorageFailuresKeepExistingPresets() async {
        let store = TestStore(initialState: ConfigurationFeatureTests.loadedState()) { ConfigurationFeature() }
        let error = CherryError.presetFormat("坏文件")
        await store.send(.importFileSelected(.failure(error))) { $0.banner = .init(message: "导入失败：\(error.userMessage)", isError: true) }
        await store.send(.presetImported(.failure(error))) { $0.banner = .init(message: error.userMessage, isError: true) }
        await store.send(.presetSaved(.failure(CherryError.storage("磁盘失败")))) { $0.banner = .init(message: CherryError.storage("磁盘失败").userMessage, isError: true) }
        await store.send(.presetDeleted(.failure(error))) { $0.banner = .init(message: "删除失败：\(error.userMessage)", isError: true) }
        await store.send(.exportFinished(.failure(error))) { $0.banner = .init(message: "导出失败：\(error.userMessage)", isError: true) }
        #expect(store.state.presets.value == [.preview])
    }

    @Test func disconnectedConfigurationBlocksWritesAndKeepsDraft() async {
        var state = ConfigurationFeatureTests.loadedState()
        state.editor?.edit { $0.brightness = 1 }
        state.isConnected = false
        let store = TestStore(initialState: state) { ConfigurationFeature() }
        await store.send(.refresh)
        await store.send(.edit(.speed(0)))
        await store.send(.saveTapped)
        await store.send(.activateProfile(2))
        #expect(store.state.editor?.dirty == [.brightness])
    }
}
