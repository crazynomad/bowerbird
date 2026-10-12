// 显示器信息探针：只读，用于找出 AirPlay、随航、投影仪等临时屏的识别特征。
// 运行：swift Probe/displays_probe.swift
import AppKit
import CoreGraphics

var count: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetOnlineDisplayList(count, &ids, &count)

let screens = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
    guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
    return (id, screen)
})

for id in ids {
    let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "?"
    let mode = CGDisplayCopyDisplayMode(id)
    print("""
    ── 显示器 \(id)
      名称          \(screens[id]?.localizedName ?? "（不在 NSScreen 中）")
      UUID          \(uuid)
      内建/活跃     builtin=\(CGDisplayIsBuiltin(id) != 0) active=\(CGDisplayIsActive(id) != 0) online=\(CGDisplayIsOnline(id) != 0) asleep=\(CGDisplayIsAsleep(id) != 0)
      镜像          inMirrorSet=\(CGDisplayIsInMirrorSet(id) != 0) mirrors=\(CGDisplayMirrorsDisplay(id)) primary=\(CGDisplayPrimaryDisplay(id))
      厂商/型号     vendor=0x\(String(CGDisplayVendorNumber(id), radix: 16)) model=0x\(String(CGDisplayModelNumber(id), radix: 16)) serial=\(CGDisplaySerialNumber(id)) unit=\(CGDisplayUnitNumber(id))
      尺寸          bounds=\(CGDisplayBounds(id)) mm=\(CGDisplayScreenSize(id))
      模式          \(mode.map { "\($0.width)×\($0.height) @\($0.refreshRate)Hz pixels=\($0.pixelWidth)×\($0.pixelHeight)" } ?? "?")
      NSScreen      \(screens[id].map { "scale=\($0.backingScaleFactor) maxFPS=\($0.maximumFramesPerSecond) description=\($0.deviceDescription.keys.map(\.rawValue).sorted())" } ?? "-")
    """)
}
