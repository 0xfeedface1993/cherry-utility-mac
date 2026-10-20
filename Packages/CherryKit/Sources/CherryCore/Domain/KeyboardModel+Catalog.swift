import Foundation

// Every keyboard and keyboard receiver in CHERRY Utility 2.3.28.7's device table (initialiser at 0x404000…0x40a000:
// DeviceIndex, VID/PID, type 1 = keyboard / 8 = receiver), with:
// - the profile bytes the driver writes for the product ID (light/basic-settings writer at 0x500790): it decides
//   `lighting` and `hasSleepSettings`,
// - the visible rows of `DefaultData/default_light.json` for the DeviceIndex,
// - the catalog `Desc` prefix and the format of the official updater.
// Entries with product ID 0 in the driver (DeviceIndex 27…33) cannot be matched and are left out; mice and mouse pads
// are not keyboards. Evidence and the per-PID write ranges are in Docs/dev/multi-model.md.
extension KeyboardModel {
    public static let pixiu75 = KeyboardModel(
        name: "MX PIXIU 75", productID: 0x01E2, deviceIndex: 51, isWireless: true, catalogName: "MX_PIXIU75_WIRELESS",
        ota: .telink, firmwareFamily: .telinkUSBOTA, layout: .pixiu75, lighting: .rgb, lightingEffects: LightingEffect.pixiu75,
        hasSleepSettings: true, verification: .hardware
    )

    public static let pixiu75Pokemon = KeyboardModel(
        name: "MX PIXIU 75 Pokémon", productID: 0x01F7, deviceIndex: 53, isWireless: true, catalogName: "MX_PIXIU75_POKEMON_WIRELESS",
        ota: .telink, firmwareFamily: .telinkUSBOTA, layout: .pixiu75Pokemon, lighting: .rgb,
        lightingEffects: LightingEffect.standard + [.battle], hasSleepSettings: true
    )

    public static let all: [KeyboardModel] = wired + wireless

    /// Wired-only boards (Sonix SN32F2xx). The driver's default branch writes profile bytes [0…8], 0x15 and 0x18.
    static let wired: [KeyboardModel] = [
        wiredBoard("MX BOARD 8.0 TKL RGB", 0x00B7, 0, "MX_BOARD_8.0_TKL_RGB", .mx80TKLRGB, .rgb, LightingEffect.standard),
        wiredBoard("MX BOARD 3.0S FL NBL", 0x0077, 3, "MX_BOARD_3.0S_FL_NBL", .mx30SFLNBL, .none),
        wiredBoard("MX BOARD 1.0 TKL BL", 0x00B4, 4, nil, .mx10TKLBL, .singleColor, LightingEffect.singleColor),
        wiredBoard("MX BOARD 3.0S FL RGB", 0x0079, 6, "MX_BOARD_3.0S_FL_RGB", .mx30SFLRGB, .rgb, LightingEffect.standard),
        wiredBoard("MX BOARD 10.0 FL RGB", 0x00BB, 7, "MX_BOARD_10.0_FL_RGB", .mx100FLRGB, .rgb, LightingEffect.standard),
        wiredBoard("G80-3000S TKL NBL", 0x00C3, 8, "G80_3000_TKL_NBL", .g80TKLNBL, .none),
        wiredBoard("MX BOARD 3.0S FL RGB KR", 0x0083, 10, nil, .mx30SFLRGBKorean, .rgb, LightingEffect.standard),
        wiredBoard("G80-3000S TKL NBL KR", 0x00CD, 11, "G80_3000S_TKL_NBL_KR", .g80TKLNBLKorean, .none),
        wiredBoard("G80-3000S TKL RGB", 0x00C5, 12, "G80_3000_TKL_RGB", .g80TKLRGB, .rgb, LightingEffect.standard),
        wiredBoard("MX BOARD 1.0 TKL BL (CCF)", 0x00CA, 13, "CCF_MX_1.0_TKL_BL", .ccfMX10TKLBL, .singleColor, LightingEffect.singleColor),
        wiredBoard("MX BOARD 8.0 TKL BL (CCF)", 0x00C9, 14, "CCF_MX_8.0_TKL_BL", .ccfMX80TKLBL, .singleColor, LightingEffect.singleColor),
        wiredBoard("MX BOARD 2.0S FL RGB", 0x00C4, 15, "MX_BOARD_2.0S_FL_RGB", .mx20SFLRGB, .rgb, LightingEffect.standard),
        wiredBoard("MX BOARD 1.0 TKL NBL (CCF)", 0x00CB, 16, nil, .ccfMX10TKLNBL, .none),
        wiredBoard("MX BOARD 1.0 FL RGB", 0x00D3, 17, "MX_1.0_FL_RGB", .mx10FLRGB, .rgb, LightingEffect.standard),
        wiredBoard("MX BOARD 1.0 FL NBL", 0x00D2, 18, nil, .mx10FLNBL, .none),
        wiredBoard("MX BOARD 1.0 FL BL", 0x00AB, 19, nil, .mx10FLBL, .singleColor, LightingEffect.singleColor),
        wiredBoard("MX BOARD 1.0 TKL RGB", 0x00AC, 20, "MX_BOARD_1.0_TKL_RGB", .mx10TKLRGB, .rgb, LightingEffect.standard),
        wiredBoard("MV BOARD 3.0 FL RGB", 0x00C7, 21, "MV_3.0_FL_RGB", .mv30FLRGB, .rgb, LightingEffect.standard),
        wiredBoard("MX BOARD 2.0S FL NBL", 0x00CE, 22, "MX_BOARD_2.0S_FL_NBL", .mx20SFLNBL, .none),
        wiredBoard("G80-3000S FS RGB", 0x00E9, 26, "G80_3000N_FL_RGB", .g80FSRGB, .rgb, LightingEffect.standard),
        wiredBoard("MX BOARD 3.0S TKL RGB", 0x01B0, 36, "MX_BOARD_3.0S_TKL_RGB", .mx30STKLRGB, .rgb, LightingEffect.standard),
        wiredBoard("MX BOARD 3.0S TKL NBL", 0x01AF, 37, "MX_BOARD_3.0S_TKL_NBL", .mx30STKLNBL, .none),
        wiredBoard("MX BOARD 2.0S FL RGB2", 0x01BA, 38, "MX_BOARD_2.0S_FL_RGB2", .mx20SFLRGB2, .rgb, LightingEffect.standard),
        wiredBoard("MX BOARD 1.1 TKL NBL", 0x01BB, 43, nil, .mx11TKLNBL, .none),
        wiredBoard("MX BOARD 1.1 TKL RGB", 0x01BC, 45, nil, .mx11TKLRGB, .rgb, LightingEffect.standard),
        wiredBoard("MX BOARD 3.1 FL RGB", 0x01D7, 48, "MX_BOARD_3.1_FL_RGB", .mx31FLRGB, .rgb, LightingEffect.standard),
        wiredBoard("MX BOARD 2.0S FL NBL (new)", 0xC0CE, 57, nil, .mx20SFLNBLNew, .none),
    ]

    public static let mx30SFLRGBWireless = wirelessBoard(
        "MX BOARD 3.0S FL RGB Wireless", 0x00E3, 23, "MX_BOARD_3.0S_FL_RGB_WIRELESS", .downloadResource,
        .mx30SFLRGBWireless, .rgb, LightingEffect.standard, sleep: true)
    public static let mx82TKLRGBWireless = wirelessBoard(
        "MX BOARD 8.2 TKL RGB Wireless", 0x00E5, 34, "MX_BOARD_8.2_TKL_RGB_WIRELESS", .downloadResource,
        .mx82TKLRGBWireless, .rgb, LightingEffect.standard, sleep: true)
    public static let mx20FLNBLWireless = wirelessBoard(
        "MX BOARD 2.0 FL NBL Wireless", 0x01AB, 35, "MX_BOARD_2.0_FL_NBL_WIRELESS", .downloadResource,
        .mx20FLNBLWireless, .none, sleep: false)
    public static let mxlp21 = wirelessBoard(
        "MX-LP 2.1 Compact Wireless", 0x01B2, 41, "MX_LP_2.1_COMPACT_WIRELESS", .downloadResource,
        .mxlp21, .rgb, LightingEffect.standard, sleep: true)
    public static let mxlp61 = wirelessBoard(
        "MX-LP 6.1 Compact Wireless", 0x01B1, 42, "MX_LP_6.1_COMPACT_WIRELESS", .downloadResource,
        .mxlp61, .rgb, LightingEffect.standard, sleep: true)
    public static let mx82Xaga = wirelessBoard(
        "MX BOARD 8.2 Xaga TKL RGB Wireless", 0x01C2, 44, "MX_BOARD_8.2_Xaga_TKL_RGB_WIRELESS", .downloadResource,
        .mx82Xaga, .rgb, LightingEffect.standard + [.rgbStatic], sleep: true)
    /// Not in any extended write list: the driver writes only [0…8], 0x15 and 0x18, so no sleep timers.
    public static let mx30SWirelessPokemon = wirelessBoard(
        "MX BOARD 3.0S Wireless Pokémon", 0x01CE, 47, "MX_BOARD_3.0S_FL_RGB_WIRELESS_POKEMON", .downloadResource,
        .mx30SFLRGBWirelessPokemon, .rgb, LightingEffect.standard + [.lightning], sleep: false)
    /// No backlight, but its product ID is in the 0x38-byte block-write list, which carries the sleep timers.
    public static let mx20FLNBLWirelessTLK = wirelessBoard(
        "MX BOARD 2.0 FL NBL Wireless (TLK)", 0x01DE, 49, "MX_BOARD_2.0_FL_NBL_WIRELESS_TLK", .evisionTelink,
        .mx20FLNBLWirelessTLK, .none, sleep: true)
    public static let mx30SWirelessFireloong = wirelessBoard(
        "MX BOARD 3.0S Wireless Fireloong", 0x01F3, 50, nil, .unpublished,
        .mx30SFLRGBWirelessFireloong, .rgb, LightingEffect.standard + [.flame], sleep: true)
    public static let mx83TKLWireless = wirelessBoard(
        "CHERRY XTRFY MX 8.3 TKL Wireless", 0x01DA, 52, "MX_BOARD_8.3_TKL_RGB_Wireless", .fireWare2,
        .mx83TKLWireless, .rgb, LightingEffect.typeB, sleep: true)
    public static let pixiu98 = wirelessBoard(
        "MX PIXIU 98", 0x01E6, 54, "MX_PIXIU98_WIRELESS", .fireWare2,
        .pixiu98, .rgb, LightingEffect.typeB, sleep: true)
    public static let mx101FLWireless = wirelessBoard(
        "CHERRY XTRFY MX 10.1 Wireless", 0x01EF, 55, "MX_BOARD_10.1_FL_RGB_Wireless", .fireWare2,
        .mx101FLWireless, .rgb, LightingEffect.typeBWithoutRainbowRain, sleep: true)
    /// Effect byte bits 6–7 carry another setting on this model (driver 0x500864); see `ProfileConfig.effectMask`.
    public static let pixiu99 = wirelessBoard(
        "MX PIXIU 99", 0x01FB, 56, "MX_PIXIU99_WIRELESS", .nordicDFU,
        .pixiu99, .rgb, LightingEffect.standard, sleep: true)
    public static let k63WPro = wirelessBoard(
        "CHERRY XTRFY K63W Pro", 0x0142, 59, "MX_K6_WIRELESS", .downloadResource,
        .k63WPro, .rgb, LightingEffect.standard, sleep: true)
    public static let mx83ProWireless = wirelessBoard(
        "CHERRY XTRFY MX 8.3 Pro TKL Wireless", 0x014C, 60, nil, .unpublished,
        .mx83ProWireless, .rgb, LightingEffect.typeB, sleep: true)

    /// Wireless keyboards, each followed by its receiver. A receiver keeps the sleep timers only when its product ID is
    /// in one of the driver's extended write lists; the others fall into the default branch ([0…8], 0x15, 0x18).
    static let wireless: [KeyboardModel] = [
        .pixiu75, receiver(of: .pixiu75, 0x01E4, catalogName: nil, firmware: .unpublished, sleep: true),
        .pixiu75Pokemon, receiver(of: .pixiu75Pokemon, 0x01F9, catalogName: nil, firmware: .unpublished, sleep: true),
        .mx30SFLRGBWireless,
        receiver(of: .mx30SFLRGBWireless, 0x00EA, catalogName: "MX_BOARD_3.0S_FL_RGB_WIRELESS_DONGLE", firmware: .downloadResource, sleep: true),
        .mx82TKLRGBWireless,
        receiver(of: .mx82TKLRGBWireless, 0x00EC, catalogName: "MX_BOARD_8.2_TKL_RGB_WIRELESS_DONGLE", firmware: .downloadResource, sleep: true),
        .mx20FLNBLWireless,
        receiver(of: .mx20FLNBLWireless, 0x01AC, catalogName: "MX_BOARD_2.0_FL_NBL_WIRELESS_DONGLE", firmware: .downloadResource, sleep: false),
        .mxlp21, receiver(of: .mxlp21, 0x01B7, catalogName: "MX_LP_2.1_COMPACT_WIRELESS_DONGLE", firmware: .downloadResource, sleep: true),
        .mxlp61, receiver(of: .mxlp61, 0x01B4, catalogName: nil, firmware: .unpublished, sleep: true),
        .mx82Xaga,
        receiver(of: .mx82Xaga, 0x01C3, catalogName: "MX_BOARD_8.2_Xaga_TKL_RGB_WIRELESS_DONGLE", firmware: .downloadResource, sleep: true),
        .mx30SWirelessPokemon, receiver(of: .mx30SWirelessPokemon, 0x01CF, catalogName: nil, firmware: .unpublished, sleep: false),
        .mx20FLNBLWirelessTLK, receiver(of: .mx20FLNBLWirelessTLK, 0x01E0, catalogName: nil, firmware: .unpublished, sleep: false),
        .mx30SWirelessFireloong, receiver(of: .mx30SWirelessFireloong, 0x01F5, catalogName: nil, firmware: .unpublished, sleep: false),
        .mx83TKLWireless,
        receiver(of: .mx83TKLWireless, 0x01DB, catalogName: "MX_BOARD_8.3_Dongle_Wireless_RGB", firmware: .fireWare2, sleep: true),
        .pixiu98, receiver(of: .pixiu98, 0x01E8, catalogName: nil, firmware: .unpublished, sleep: true),
        .mx101FLWireless,
        receiver(of: .mx101FLWireless, 0x01F1, catalogName: "MX_BOARD_10.1_FL_RGB_Wireless_DONGLE", firmware: .fireWare2, sleep: true),
        .pixiu99, receiver(of: .pixiu99, 0x01FD, catalogName: "MX_PIXIU99_WIRELESS_DONGLE", firmware: .nordicDFU, sleep: false),
        .k63WPro, receiver(of: .k63WPro, 0x0144, catalogName: "MX_K6_WIRELESS_DONGLE", firmware: .downloadResource, sleep: false),
        .mx83ProWireless, receiver(of: .mx83ProWireless, 0x014E, catalogName: nil, firmware: .unpublished, sleep: true),
    ]

    private static func wiredBoard(
        _ name: String, _ productID: UInt16, _ deviceIndex: Int, _ catalogName: String?, _ layout: KeyboardLayout,
        _ lighting: Lighting, _ effects: [LightingEffect] = []
    ) -> KeyboardModel {
        KeyboardModel(
            name: name, productID: productID, deviceIndex: deviceIndex, isWireless: false, catalogName: catalogName,
            firmwareFamily: catalogName == nil ? .unpublished : .sonixISP, layout: layout, lighting: lighting,
            lightingEffects: effects, hasSleepSettings: false
        )
    }

    private static func wirelessBoard(
        _ name: String, _ productID: UInt16, _ deviceIndex: Int, _ catalogName: String?, _ firmware: FirmwareFamily,
        _ layout: KeyboardLayout, _ lighting: Lighting, _ effects: [LightingEffect] = [], sleep: Bool
    ) -> KeyboardModel {
        KeyboardModel(
            name: name, productID: productID, deviceIndex: deviceIndex, isWireless: true, catalogName: catalogName,
            firmwareFamily: firmware, layout: layout, lighting: lighting, lightingEffects: effects, hasSleepSettings: sleep
        )
    }

    private static func receiver(
        of keyboard: KeyboardModel, _ productID: UInt16, catalogName: String?, firmware: FirmwareFamily, sleep: Bool
    ) -> KeyboardModel {
        KeyboardModel(
            name: keyboard.name + " Receiver", productID: productID, deviceIndex: keyboard.deviceIndex, kind: .receiver,
            isWireless: true, catalogName: catalogName, firmwareFamily: firmware, layout: keyboard.layout,
            profileCount: keyboard.profileCount, lighting: keyboard.lighting, lightingEffects: keyboard.lightingEffects,
            hasSleepSettings: sleep
        )
    }
}
