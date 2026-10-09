extension Layout {
    /// 某显示器上的 Space 序列：全屏窗口为记录下标，普通桌面为 nil。
    /// 布局里只记了窗口所在序号，桌面位置取其上普通窗口的序号；没有普通窗口时取全屏未占用的最小序号。
    public func spaceSequence(on displayUUID: String) -> [Int?] {
        let onDisplay = windows.indices.filter { windows[$0].displayUUID == displayUUID }
        let fullScreen = onDisplay.filter { windows[$0].isFullScreen }.sorted { windows[$0].spaceIndex < windows[$1].spaceIndex }
        let used = Set(fullScreen.map { windows[$0].spaceIndex })
        let desktopIndex = onDisplay.filter { !windows[$0].isFullScreen }.map { windows[$0].spaceIndex }.min()
            ?? (1...).first { !used.contains($0) }!

        var sequence: [Int?] = []
        for index in fullScreen {
            if !sequence.contains(nil), windows[index].spaceIndex > desktopIndex { sequence.append(nil) }
            sequence.append(index)
        }
        if !sequence.contains(nil) { sequence.append(nil) }
        return sequence
    }
}

/// 首次进入某环境、没有钉住或自动记录的布局时，从上一个环境推导默认布局（纯函数）：
/// - 内建屏对内建屏，保持不变
/// - 外接屏按分辨率从高到低一一对应；目标外接屏较少时，多出来的并入最后一块（3 屏 → 2 屏）
/// - 并入同一块屏的普通桌面合而为一，全屏 Space 按来源屏的分辨率顺序依次排列
public enum LayoutMapper {
    public static func displayMapping(from source: [DisplayInfo], to target: [DisplayInfo]) -> [(source: DisplayInfo, target: DisplayInfo)] {
        let sourceBuiltin = source.first(where: \.isBuiltin)
        let targetBuiltin = target.first(where: \.isBuiltin)
        let sourceExternals = rankedExternals(source)
        let targetExternals = rankedExternals(target)

        var mapping: [(DisplayInfo, DisplayInfo)] = []
        // 合盖时没有内建屏，内建屏的内容放到最大的外接屏
        if let sourceBuiltin, let destination = targetBuiltin ?? targetExternals.first {
            mapping.append((sourceBuiltin, destination))
        }
        for (rank, display) in sourceExternals.enumerated() {
            guard let destination = targetExternals.isEmpty ? targetBuiltin : targetExternals[min(rank, targetExternals.count - 1)] else { continue }
            mapping.append((display, destination))
        }
        return mapping
    }

    public static func derive(from source: Layout, to environment: DisplayEnvironment) -> Layout {
        let mapping = displayMapping(from: source.displays, to: environment.displays)
        var records: [WindowRecord] = []
        var desktopForeground: [String] = []

        for target in environment.displays {
            let sources = mapping.filter { $0.target.uuid == target.uuid }.map(\.source)
            // 多块屏并入一块时只能有一个前台页，取排在最前（分辨率最高）的来源屏的前台
            let primary = sources.first
            if let primary, source.desktopForeground?.contains(primary.uuid) == true {
                desktopForeground.append(target.uuid)
            }
            // 合并后的序列：来源按映射顺序（内建屏、再按分辨率），普通桌面只保留第一次出现的位置
            var merged: [(record: WindowRecord, from: DisplayInfo)?] = []
            for display in sources {
                for item in source.spaceSequence(on: display.uuid) {
                    if let index = item {
                        merged.append((source.windows[index], display))
                    } else if !merged.contains(where: { $0 == nil }) {
                        merged.append(nil)
                    }
                }
            }
            // 没有来源的屏（2 屏 → 3 屏时新增的那块）也至少有一个普通桌面
            if !merged.contains(where: { $0 == nil }) { merged.append(nil) }
            let desktopIndex = merged.firstIndex { $0 == nil }! + 1

            for (offset, item) in merged.enumerated() {
                guard let (record, from) = item else { continue }
                var mapped = record
                if from.uuid != primary?.uuid { mapped.isForeground = nil }
                mapped.displayUUID = target.uuid
                mapped.spaceIndex = offset + 1
                mapped.frame = Rect(x: 0, y: 0, width: target.frame.width, height: target.frame.height)
                records.append(mapped)
            }
            for display in sources {
                for record in source.windows where record.displayUUID == display.uuid && !record.isFullScreen {
                    var mapped = record
                    mapped.displayUUID = target.uuid
                    mapped.spaceIndex = desktopIndex
                    mapped.frame = scale(record.frame, from: display.frame, to: target.frame)
                    records.append(mapped)
                }
            }
        }
        return Layout(environmentKey: environment.key, name: "\(environment.suggestedName)（由「\(source.name)」推导）",
                      savedAt: source.savedAt, displays: environment.displays, windows: records, desktopForeground: desktopForeground)
    }

    /// 外接屏按分辨率（面积）从高到低
    private static func rankedExternals(_ displays: [DisplayInfo]) -> [DisplayInfo] {
        displays.filter { !$0.isBuiltin }.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
    }

    /// 位置按比例缩放、尺寸不放大只在超出时收缩，避免小窗口在大屏上被拉伸
    private static func scale(_ frame: Rect, from source: Rect, to target: Rect) -> Rect {
        Rect(x: frame.x * target.width / source.width, y: frame.y * target.height / source.height,
             width: min(frame.width, target.width), height: min(frame.height, target.height))
    }
}
