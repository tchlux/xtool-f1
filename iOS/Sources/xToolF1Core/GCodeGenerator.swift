import Foundation

public enum GCodeGenerator {
    public static func makeGCode(for project: LaserProject) -> String {
        var lines = ["$L", "G90", "G0 F240000"]

        for op in project.operations {
            lines.append(op.laser == .infrared ? "M114S2" : "M114S1")
            lines.append("M3 S\(power(op.powerPercent, preview: project.preview))")

            let center = Point(x: RasterGenerator.workAreaMM / 2, y: RasterGenerator.workAreaMM / 2)
            for path in op.paths.centerOutCutOrder(relativeTo: center) {
                let first = path.points[0]
                lines.append("G0 X\(fmt(first.x)) Y\(fmt(first.y))")
                lines.append("G1 F\(fmt(op.speedMMPerSecond * 60))")

                for point in path.points.dropFirst() {
                    lines.append("G1 X\(fmt(point.x)) Y\(fmt(point.y))")
                }

                if path.closed {
                    lines.append("G1 X\(fmt(first.x)) Y\(fmt(first.y))")
                }
            }

            lines.append("M5")
        }

        lines += ["M116A127B127", "G90", "M6", "$P"]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func power(_ percent: Double, preview: Bool) -> Int {
        let limited = preview ? min(percent, 1) : percent
        return max(0, min(1000, Int((limited * 10).rounded())))
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.3f", value).replacingOccurrences(of: ".000", with: "")
    }
}
