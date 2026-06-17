import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct RasterOutput: Equatable, Sendable {
    public var widthPixels: Int
    public var heightPixels: Int
    public var xMM: Double
    public var yMM: Double
    public var widthMM: Double
    public var heightMM: Double
    public var rotationDegrees: Double = 0
    public var scanDirection: ScanDirection
    public var dropPowerThreshold: Int
    public var lines: [String]

    public var text: String {
        lines.joined(separator: "\n") + "\n"
    }
}

public struct RasterBurnMask: Equatable, Sendable {
    public var values: [Bool]
    public var width: Int
    public var height: Int
    public var placement: PrintPlacement
}

public struct GCodePreviewSegment: Equatable, Sendable {
    public var x0MM: Double
    public var y0MM: Double
    public var x1MM: Double
    public var y1MM: Double
    public var power: Int
    public var startSecond: Double
    public var durationSeconds: Double

    public init(x0MM: Double, y0MM: Double, x1MM: Double, y1MM: Double, power: Int, startSecond: Double = 0, durationSeconds: Double = 0) {
        self.x0MM = x0MM
        self.y0MM = y0MM
        self.x1MM = x1MM
        self.y1MM = y1MM
        self.power = power
        self.startSecond = startSecond
        self.durationSeconds = durationSeconds
    }
}

public struct GCodePreviewSweep: Equatable, Sendable {
    public var startXMM: Double
    public var endXMM: Double
    public var yMM: Double

    public init(startXMM: Double, endXMM: Double, yMM: Double) {
        self.startXMM = startXMM
        self.endXMM = endXMM
        self.yMM = yMM
    }
}

public struct GCodePreviewPoint: Equatable, Sendable {
    public var xMM: Double
    public var yMM: Double
    public var power: Int
}

public struct GCodePreviewRaster: Equatable, Sendable {
    public var xMM: Double
    public var yMM: Double
    public var widthMM: Double
    public var heightMM: Double
    public var rotationDegrees: Double = 0
    public var widthPixels: Int
    public var heightPixels: Int
    public var scanDirection: ScanDirection
    public var powers: [UInt8]
    public var rowBurnOffsets: [Int]
    public var displayWidthPixels: Int
    public var displayHeightPixels: Int
    public var displayPowers: [UInt8]
    public var displayRowBurnOffsets: [Int]
    public var displayBurnCount: Int
    public var startBurnIndex: Int
    public var burnCount: Int
    public var startSecond: Double = 0
    public var durationSeconds: Double = 0
}

public struct GCodePreview: Sendable {
    public var id = UUID()
    public var segments: [GCodePreviewSegment]
    public var points: [GCodePreviewPoint]
    public var allPointsRetained = true
    public var rasterLayers: [GCodePreviewRaster] = []
    public var sweeps: [GCodePreviewSweep]
    public var estimatedDurationSeconds: Double
    public var imageData: Data?
    public var frames: [Data] = []
    public var frameSweeps: [GCodePreviewSweep?] = []
    public var playbackDurationSeconds: Double

    public init(segments: [GCodePreviewSegment], points: [GCodePreviewPoint], allPointsRetained: Bool = true, rasterLayers: [GCodePreviewRaster] = [], sweeps: [GCodePreviewSweep], estimatedDurationSeconds: Double, imageData: Data? = nil, frames: [Data] = [], frameSweeps: [GCodePreviewSweep?] = [], playbackDurationSeconds: Double = 3) {
        self.segments = segments
        self.points = points
        self.allPointsRetained = allPointsRetained
        self.rasterLayers = rasterLayers
        self.sweeps = sweeps
        self.estimatedDurationSeconds = estimatedDurationSeconds
        self.imageData = imageData
        self.frames = frames
        self.frameSweeps = frameSweeps
        self.playbackDurationSeconds = playbackDurationSeconds
    }
}

public struct VectorOutline: Equatable, Sendable {
    public var placement: PrintPlacement
    public var paths: [LaserPath]

    public init(placement: PrintPlacement, paths: [LaserPath]) {
        self.placement = placement
        self.paths = paths
    }
}

public struct PreviewTransform: Equatable, Sendable {
    public var zoom: Double
    public var panX: Double
    public var panY: Double
}

public enum PreviewGesturePhase: Sendable {
    case began
    case changed
    case ended
    case cancelled
    case failed
}

public struct PreviewPinchStateMachine: Sendable {
    public private(set) var transform: PreviewTransform
    private var active = false
    private var startZoom = 1.0
    private var startPanX = 0.0
    private var startPanY = 0.0
    private var contentX = 0.0
    private var contentY = 0.0

    public init(zoom: Double = 1, panX: Double = 0, panY: Double = 0) {
        transform = PreviewTransform(zoom: zoom, panX: panX, panY: panY)
    }

    public mutating func update(phase: PreviewGesturePhase, touches: Int, scale: Double, locationX: Double, locationY: Double, centerX: Double, centerY: Double, minZoom: Double = 1, maxZoom: Double = 16) -> PreviewTransform {
        switch phase {
        case .began:
            guard touches >= 2 else { active = false; return transform }
            active = true
            startZoom = transform.zoom
            startPanX = transform.panX
            startPanY = transform.panY
            contentX = centerX + (locationX - centerX - startPanX) / startZoom
            contentY = centerY + (locationY - centerY - startPanY) / startZoom
        case .changed:
            guard active, touches >= 2 else { return transform }
            let zoom = min(maxZoom, max(minZoom, startZoom * scale))
            transform = zoom <= minZoom + 0.0001
                ? PreviewTransform(zoom: minZoom, panX: 0, panY: 0)
                : PreviewTransform(zoom: zoom, panX: locationX - centerX - (contentX - centerX) * zoom, panY: locationY - centerY - (contentY - centerY) * zoom)
        case .ended, .cancelled, .failed:
            active = false
        }
        return transform
    }
}

public enum RasterGenerator {
    public static let workAreaMM = 115.0
    public static let maximumBitmapDPI = RasterSettings.maximumDPI
    public static let maximumBitmapPitchMM = 25.4 / maximumBitmapDPI
    private static let maximumPreviewPoints = 200_000
    private static let maximumPreviewRasterBytes = 64 * 1024 * 1024
    private static let maximumPreviewDisplayPixels = 512

    public static func makeRaster(from data: Data, settings: RasterSettings) throws -> RasterOutput {
        try makeRaster(from: grayscale(from: data), settings: settings)
    }

    public static func burnMask(from data: Data, settings: RasterSettings) throws -> RasterBurnMask {
        try burnMask(from: grayscale(from: data), settings: settings)
    }

    public static func burnMask(from grayscale: [[UInt8]], settings: RasterSettings) -> RasterBurnMask {
        let placement = sizeConstrained(settings.placement)
        let dpi = RasterSettings.clampedDPI(settings.dpi)
        let rows = max(1, Int((placement.heightMM * dpi / 25.4).rounded()))
        let cols = max(1, Int((placement.widthMM * dpi / 25.4).rounded()))
        let scaled = resize(grayscale, width: cols, height: rows)
        guard let visible = visiblePlacement(placement) else {
            return RasterBurnMask(values: [], width: 0, height: 0, placement: placement)
        }
        let x0 = max(0, min(cols, Int(((visible.xMM - placement.xMM) / placement.widthMM * Double(cols)).rounded(.down))))
        let y0 = max(0, min(rows, Int(((visible.yMM - placement.yMM) / placement.heightMM * Double(rows)).rounded(.down))))
        let x1 = max(x0, min(cols, Int((((visible.xMM + visible.widthMM) - placement.xMM) / placement.widthMM * Double(cols)).rounded(.up))))
        let y1 = max(y0, min(rows, Int((((visible.yMM + visible.heightMM) - placement.yMM) / placement.heightMM * Double(rows)).rounded(.up))))
        var values: [Bool] = []
        for y in y0..<y1 {
            values += scaled[y][x0..<x1].map {
                let power = power(for: $0, settings: settings)
                return power > 0 && power >= settings.dropPowerThreshold
            }
        }
        return RasterBurnMask(values: values, width: x1 - x0, height: y1 - y0, placement: visible)
    }

    public static func makeRaster(from grayscale: [[UInt8]], settings: RasterSettings) -> RasterOutput {
        let placement = sizeConstrained(settings.placement)
        let dpi = RasterSettings.clampedDPI(settings.dpi)
        let rows = max(1, Int((placement.heightMM * dpi / 25.4).rounded()))
        let cols = max(1, Int((placement.widthMM * dpi / 25.4).rounded()))
        let scaled = resize(grayscale, width: cols, height: rows)
        let visible = visiblePlacement(placement)
        guard let visible else {
            return emptyRaster(placement: placement, settings: settings, dpi: dpi)
        }
        let x0 = max(0, min(cols, Int(((visible.xMM - placement.xMM) / placement.widthMM * Double(cols)).rounded(.down))))
        let y0 = max(0, min(rows, Int(((visible.yMM - placement.yMM) / placement.heightMM * Double(rows)).rounded(.down))))
        let x1 = max(x0, min(cols, Int((((visible.xMM + visible.widthMM) - placement.xMM) / placement.widthMM * Double(cols)).rounded(.up))))
        let y1 = max(y0, min(rows, Int((((visible.yMM + visible.heightMM) - placement.yMM) / placement.heightMM * Double(rows)).rounded(.up))))
        let visibleRows = max(0, y1 - y0)
        let visibleCols = max(0, x1 - x0)
        var lines = [
            "; SIMULATED F1 RASTER",
            "; origin \(fmt(visible.xMM)),\(fmt(visible.yMM))mm size \(fmt(visible.widthMM))x\(fmt(visible.heightMM))mm dpi \(fmt(dpi)) lines \(visibleRows) cols \(visibleCols)",
            settings.laser == .infrared ? "M114S2" : "M114S1",
            "G1 F\(fmt(settings.speedMMPerSecond * 60))"
        ]

        for y in 0..<visibleRows {
            let row = scaled[y0 + y][x0..<x1]
            let powers = settings.scanDirection == .bidirectional && y.isMultiple(of: 2) == false
                ? row.reversed().map { power(for: $0, settings: settings) }
                : row.map { power(for: $0, settings: settings) }
            let yMM = visible.yMM + Double(y) * visible.heightMM / Double(max(1, visibleRows - 1))
            lines.append("Y\(fmt(yMM)) " + powers.map(String.init).joined(separator: ","))
        }

        lines.append("; END SIMULATION")
        return RasterOutput(widthPixels: visibleCols, heightPixels: visibleRows, xMM: visible.xMM, yMM: visible.yMM, widthMM: visible.widthMM, heightMM: visible.heightMM, rotationDegrees: visible.rotationDegrees, scanDirection: settings.scanDirection, dropPowerThreshold: settings.dropPowerThreshold, lines: lines)
    }

    public static func grayscale(from data: Data) throws -> [[UInt8]] {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { throw RasterError.badImage }

        let maxPixel = max(properties[kCGImagePropertyPixelWidth] as? Int ?? 1, properties[kCGImagePropertyPixelHeight] as? Int ?? 1)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { throw RasterError.badImage }

        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info) else {
            throw RasterError.badImage
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var rows: [[UInt8]] = []
        for rowStart in stride(from: 0, to: bytes.count, by: width * 4) {
            var row: [UInt8] = []
            for i in stride(from: rowStart, to: rowStart + width * 4, by: 4) {
                let alpha = Int(bytes[i + 3])
                let red = (Int(bytes[i]) + 255 - alpha) * 299
                let green = (Int(bytes[i + 1]) + 255 - alpha) * 587
                let blue = (Int(bytes[i + 2]) + 255 - alpha) * 114
                row.append(UInt8((red + green + blue) / 1000))
            }
            rows.append(row)
        }
        return rows
    }

    public static func pngPreview(from raster: RasterOutput) -> Data? {
        let width = raster.widthPixels
        let height = raster.heightPixels
        guard width > 0, height > 0 else { return nil }
        let powers = rowLines(from: raster).enumerated().flatMap { y, line in
            let row = powerRow(from: line)
            return raster.scanDirection == .bidirectional && y.isMultiple(of: 2) == false ? row.reversed() : row
        }
        let minPower = powers.min() ?? 0
        let span = max(1, (powers.max() ?? 0) - minPower)
        let gray = powers.map { UInt8(255 - (($0 - minPower) * 255 / span)) }
        guard gray.count == width * height else { return nil }
        let provider = CGDataProvider(data: Data(gray) as CFData)
        guard
            let provider,
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    public static func workspacePreview(from rasters: [RasterOutput], pixels: Int = 600) -> Data? {
        let pixels = max(1, pixels)
        var alpha = [UInt8](repeating: 0, count: pixels * pixels)
        for raster in rasters {
            guard raster.widthPixels > 0, raster.heightPixels > 0, raster.widthMM > 0, raster.heightMM > 0 else { continue }
            let x0 = max(0, min(pixels - 1, Int((raster.xMM / workAreaMM * Double(pixels)).rounded())))
            let y0 = max(0, min(pixels - 1, Int((raster.yMM / workAreaMM * Double(pixels)).rounded())))
            let width = max(1, Int((raster.widthMM / workAreaMM * Double(pixels)).rounded()))
            let height = max(1, Int((raster.heightMM / workAreaMM * Double(pixels)).rounded()))
            for y in 0..<min(height, pixels - y0) {
                let sourceY = y * raster.heightPixels / height
                var row = powerRow(at: sourceY, in: raster)
                if raster.scanDirection == .bidirectional && sourceY.isMultiple(of: 2) == false {
                    row.reverse()
                }
                for x in 0..<min(width, pixels - x0) {
                    let power = row[x * raster.widthPixels / width]
                    guard power >= raster.dropPowerThreshold else { continue }
                    let value = UInt8(max(0, min(255, Int((Double(power) / 1000 * 255).rounded()))))
                    let offset = (y0 + y) * pixels + x0 + x
                    alpha[offset] = max(alpha[offset], value)
                }
            }
        }
        return png(fromAlpha: alpha, width: pixels, height: pixels)
    }

    public static func preview(from rasters: [RasterOutput], settings: [RasterSettings], mode: RasterGCodeMode = .asset, pixels: Int = 600, frameCount: Int = 0, includeSegments: Bool = false) -> GCodePreview {
        var points: [GCodePreviewPoint] = []
        var sweeps: [GCodePreviewSweep] = []
        var segments: [GCodePreviewSegment] = []
        var sweep: GCodePreviewSweep?
        var x = 0.0
        var y = 0.0
        var estimatedDuration = 0.0
        var burnMove = 0
        let totalBurnMoves = countBurnMoves(rasters: rasters, settings: settings, mode: mode)
        let pointStride = max(1, (totalBurnMoves + maximumPreviewPoints - 1) / maximumPreviewPoints)
        let rasterLayers = previewRasterLayers(rasters: rasters, settings: settings, mode: mode)

        func finishSweep() {
            if let sweep { sweeps.append(sweep) }
            sweep = nil
        }

        func appendPoint(x nextX: Double, y nextY: Double, power: Int, settings: RasterSettings) {
            if let current = sweep, abs(current.yMM - nextY) > 0.0001 {
                finishSweep()
            }
            if var current = sweep {
                current.endXMM = nextX
                sweep = current
            } else {
                sweep = GCodePreviewSweep(startXMM: nextX, endXMM: nextX, yMM: nextY)
            }

            let point = GCodePreviewPoint(xMM: nextX, yMM: nextY, power: min(1000, power))
            if burnMove.isMultiple(of: pointStride) {
                points.append(point)
            }
            if includeSegments {
                segments.append(GCodePreviewSegment(x0MM: nextX, y0MM: nextY, x1MM: nextX, y1MM: nextY, power: point.power))
            }
            estimatedDuration += hypot(nextX - x, nextY - y) / max(0.001, settings.speedMMPerSecond)
            estimatedDuration += dwellMilliseconds(settings) / 1000
            x = nextX
            y = nextY
            burnMove += 1
        }

        func append(row: [Int], rowIndex: Int, raster: RasterOutput, settings: RasterSettings) {
            let reversed = raster.scanDirection == .bidirectional && rowIndex.isMultiple(of: 2) == false
            let yMM = rowY(rowIndex, raster: raster)
            let step = raster.widthMM / Double(max(1, raster.widthPixels - 1))
            for (column, power) in row.enumerated() where power >= settings.dropPowerThreshold {
                let xMM = reversed ? raster.xMM + raster.widthMM - Double(column) * step : raster.xMM + Double(column) * step
                appendPoint(x: xMM, y: yMM, power: power, settings: settings)
            }
        }

        forEachRasterRow(rasters: rasters, settings: settings, mode: mode) { raster, settings, rowIndex, row in
            append(row: row, rowIndex: rowIndex, raster: raster, settings: settings)
        }
        finishSweep()
        return GCodePreview(segments: segments, points: points, allPointsRetained: pointStride == 1, rasterLayers: rasterLayers, sweeps: sweeps, estimatedDurationSeconds: estimatedDuration)
    }

    public static func previewDuration(raster: RasterOutput, settings: RasterSettings) -> Double {
        var x = raster.xMM
        var y = raster.yMM
        var duration = 0.0
        for rowIndex in 0..<raster.heightPixels {
            let row = powerRow(at: rowIndex, in: raster)
            let reversed = raster.scanDirection == .bidirectional && rowIndex.isMultiple(of: 2) == false
            let yMM = rowY(rowIndex, raster: raster)
            let step = raster.widthMM / Double(max(1, raster.widthPixels - 1))
            for (column, power) in row.enumerated() where power >= settings.dropPowerThreshold {
                let xMM = reversed ? raster.xMM + raster.widthMM - Double(column) * step : raster.xMM + Double(column) * step
                duration += hypot(xMM - x, yMM - y) / max(0.001, settings.speedMMPerSecond)
                duration += dwellMilliseconds(settings) / 1000
                x = xMM
                y = yMM
            }
        }
        return duration
    }

    // Parses emitted G-code as an independent preview oracle for generator regressions.
    public static func gcodePreview(from gcode: String, pixels: Int = 600, frameCount: Int = 0, includeSegments: Bool = false) -> GCodePreview {
        let pixels = max(1, pixels)
        var alpha = [UInt8](repeating: 0, count: pixels * pixels)
        var x = 0.0
        var y = 0.0
        var power = 0
        var feedMMPerMinute = 240000.0
        var estimatedDuration = 0.0
        var segments: [GCodePreviewSegment] = []
        var points: [GCodePreviewPoint] = []
        var sweeps: [GCodePreviewSweep] = []
        var sweep: GCodePreviewSweep?
        var frames: [Data] = []
        var frameSweeps: [GCodePreviewSweep?] = []
        let frameCount = max(0, frameCount)
        let burnMoves = frameCount > 0 ? countBurnMoves(in: gcode) : 0
        var burnMove = 0
        var nextFrame = 0

        func finishSweep() {
            if let sweep { sweeps.append(sweep) }
            sweep = nil
        }

        func appendFramesIfNeeded() {
            guard frameCount > 0 else { return }
            while nextFrame < frameCount {
                let threshold = frameCount == 1 ? burnMoves : Int((Double(nextFrame) / Double(frameCount - 1) * Double(burnMoves)).rounded(.down))
                guard burnMove >= threshold else { break }
                if let frame = png(fromAlpha: alpha, width: pixels, height: pixels) {
                    frames.append(frame)
                    frameSweeps.append(sweep)
                }
                nextFrame += 1
            }
        }

        func appendPoint() {
            let point = GCodePreviewPoint(xMM: x, yMM: y, power: min(1000, power))
            guard point.power > 0 else { return }
            if let current = sweep, abs(current.yMM - y) > 0.0001 {
                finishSweep()
            }
            if var current = sweep {
                current.endXMM = x
                sweep = current
            } else {
                sweep = GCodePreviewSweep(startXMM: x, endXMM: x, yMM: y)
            }
            points.append(point)
            if includeSegments {
                segments.append(GCodePreviewSegment(x0MM: x, y0MM: y, x1MM: x, y1MM: y, power: point.power))
            }
            draw(point, into: &alpha, pixels: pixels)
            burnMove += 1
            appendFramesIfNeeded()
        }

        appendFramesIfNeeded()
        for line in gcode.split(separator: "\n").map(String.init) {
            let parts = line.split(separator: " ")
            guard let command = parts.first else { continue }
            if command == "M3" || command == "M4" {
                power = word("S", in: parts).map { Int($0.rounded()) } ?? power
                continue
            }
            if command == "M5" {
                power = 0
                finishSweep()
                continue
            }
            if command == "G4" {
                estimatedDuration += (word("P", in: parts) ?? 0) / 1000
                appendPoint()
                continue
            }
            guard command == "G0" || command == "G1" else { continue }
            let parsedX = word("X", in: parts)
            let parsedY = word("Y", in: parts)
            if let nextFeed = word("F", in: parts) {
                feedMMPerMinute = nextFeed
            }
            let nextX = parsedX ?? x
            let nextY = parsedY ?? y
            let nextPower = word("S", in: parts).map { Int($0.rounded()) } ?? power
            if parsedX != nil || parsedY != nil {
                estimatedDuration += hypot(nextX - x, nextY - y) / max(0.001, feedMMPerMinute / 60)
            }
            if command == "G1", (parsedX != nil || parsedY != nil), nextPower > 0 {
                let segment = GCodePreviewSegment(x0MM: x, y0MM: y, x1MM: nextX, y1MM: nextY, power: min(1000, nextPower))
                if includeSegments {
                    segments.append(segment)
                }
                if let current = sweep, abs(current.yMM - nextY) > 0.0001 {
                    finishSweep()
                }
                if var current = sweep {
                    current.endXMM = nextX
                    sweep = current
                } else {
                    sweep = GCodePreviewSweep(startXMM: x, endXMM: nextX, yMM: nextY)
                }
                draw(segment, into: &alpha, pixels: pixels)
                burnMove += 1
                appendFramesIfNeeded()
            }
            x = nextX
            y = nextY
            power = command == "G0" ? 0 : nextPower
        }

        finishSweep()
        appendFramesIfNeeded()
        return GCodePreview(segments: segments, points: points, sweeps: sweeps, estimatedDurationSeconds: estimatedDuration, imageData: png(fromAlpha: alpha, width: pixels, height: pixels), frames: frames, frameSweeps: frameSweeps)
    }

    public static func pngPreview(from preview: GCodePreview, pixels: Int = 600) -> Data? {
        if let imageData = preview.imageData {
            return imageData
        }
        let pixels = max(1, pixels)
        var alpha = [UInt8](repeating: 0, count: pixels * pixels)
        for layer in preview.rasterLayers {
            for y in 0..<layer.heightPixels {
                let yy = max(0, min(pixels - 1, Int(((layer.yMM + layer.heightMM * Double(y) / Double(max(1, layer.heightPixels - 1))) / workAreaMM * Double(pixels - 1)).rounded())))
                for x in 0..<layer.widthPixels {
                    let power = layer.powers[y * layer.widthPixels + x]
                    guard power > 0 else { continue }
                    let xx = max(0, min(pixels - 1, Int(((layer.xMM + layer.widthMM * Double(x) / Double(max(1, layer.widthPixels - 1))) / workAreaMM * Double(pixels - 1)).rounded())))
                    alpha[yy * pixels + xx] = max(alpha[yy * pixels + xx], power)
                }
            }
        }
        return png(fromAlpha: alpha, width: pixels, height: pixels)
    }

    public static func makeGCode(from rasters: [RasterOutput], settings: [RasterSettings], mode: RasterGCodeMode = .asset) -> String {
        var text = "$L\nG90\nG0 F240000\n"
        text += makeGCodeBody(from: rasters, settings: settings, mode: mode)
        text += "M116A127B127\nG90\nM6\n$P\n"
        return text
    }

    public static func makeGCodeBody(from rasters: [RasterOutput], settings: [RasterSettings], mode: RasterGCodeMode = .asset) -> String {
        var text = ""
        switch mode {
        case .asset:
            appendAssetGCode(rasters: rasters, settings: settings, to: &text)
        case .scanline:
            appendScanlineGCode(rasters: rasters, settings: settings, to: &text)
        }
        return text
    }

    static func makeProcessingGCodeBody(from rasters: [RasterOutput], settings: [RasterSettings], mode: RasterGCodeMode = .asset) -> String {
        var text = ""
        switch mode {
        case .asset:
            appendProcessingAssetGCode(rasters: rasters, settings: settings, to: &text)
        case .scanline:
            appendProcessingScanlineGCode(rasters: rasters, settings: settings, to: &text)
        }
        return text
    }

    public static func power(for gray: UInt8, settings: RasterSettings) -> Int {
        let darkness = 1 - Double(gray) / 255
        let percent = settings.minPowerPercent + darkness * (settings.maxPowerPercent - settings.minPowerPercent)
        return max(0, min(1000, Int((percent * 10).rounded())))
    }

    public static func fit(width: Double, height: Double) -> (width: Double, height: Double) {
        let scale = min(workAreaMM / max(0.1, width), workAreaMM / max(0.1, height), 1)
        return (max(0.1, width * scale), max(0.1, height * scale))
    }

    public static func clamp(_ placement: PrintPlacement) -> PrintPlacement {
        let width = min(workAreaMM, max(1, placement.widthMM))
        let height = min(workAreaMM, max(1, placement.heightMM))
        let x = min(workAreaMM - width, max(0, placement.xMM))
        let y = min(workAreaMM - height, max(0, placement.yMM))
        return PrintPlacement(xMM: x, yMM: y, widthMM: width, heightMM: height, rotationDegrees: placement.rotationDegrees)
    }

    public static func sizeConstrained(_ placement: PrintPlacement) -> PrintPlacement {
        PrintPlacement(
            xMM: placement.xMM,
            yMM: placement.yMM,
            widthMM: min(workAreaMM, max(1, placement.widthMM)),
            heightMM: min(workAreaMM, max(1, placement.heightMM)),
            rotationDegrees: placement.rotationDegrees
        )
    }

    public static func minimumSizeConstrained(_ placement: PrintPlacement) -> PrintPlacement {
        PrintPlacement(
            xMM: placement.xMM,
            yMM: placement.yMM,
            widthMM: max(1, placement.widthMM),
            heightMM: max(1, placement.heightMM),
            rotationDegrees: placement.rotationDegrees
        )
    }

    public static func visiblePlacement(_ placement: PrintPlacement) -> PrintPlacement? {
        let placement = sizeConstrained(placement)
        if abs(placement.rotationDegrees).truncatingRemainder(dividingBy: 360) > 0.0001 {
            return placement
        }
        let x = max(0, placement.xMM)
        let y = max(0, placement.yMM)
        let maxX = min(workAreaMM, placement.xMM + placement.widthMM)
        let maxY = min(workAreaMM, placement.yMM + placement.heightMM)
        guard maxX > x, maxY > y else { return nil }
        return PrintPlacement(xMM: x, yMM: y, widthMM: maxX - x, heightMM: maxY - y, rotationDegrees: placement.rotationDegrees)
    }

    private static func resize(_ pixels: [[UInt8]], width: Int, height: Int) -> [[UInt8]] {
        (0..<height).map { y in
            (0..<width).map { x in
                pixels[y * pixels.count / height][x * pixels[0].count / width]
            }
        }
    }

    private static func rowLines(from raster: RasterOutput) -> ArraySlice<String> {
        raster.lines.dropFirst(4).prefix(raster.heightPixels)
    }

    private static func powerRow(from line: String) -> [Int] {
        line.split(separator: " ").last?.split(separator: ",").compactMap { Int($0) } ?? []
    }

    private static func powerRow(at y: Int, in raster: RasterOutput) -> [Int] {
        let index = raster.lines.index(raster.lines.startIndex, offsetBy: 4 + y)
        return powerRow(from: raster.lines[index])
    }

    private static func word(_ name: Character, in parts: [String.SubSequence]) -> Double? {
        parts.first { $0.first == name }.flatMap { Double($0.dropFirst()) }
    }

    private static func countBurnMoves(in gcode: String) -> Int {
        var power = 0
        var count = 0
        for line in gcode.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard let command = parts.first else { continue }
            if command == "M3" || command == "M4" {
                power = word("S", in: parts).map { Int($0.rounded()) } ?? power
                continue
            }
            if command == "M5" {
                power = 0
                continue
            }
            if command == "G4", power > 0 {
                count += 1
                continue
            }
            guard command == "G0" || command == "G1" else { continue }
            let moving = word("X", in: parts) != nil || word("Y", in: parts) != nil
            let nextPower = word("S", in: parts).map { Int($0.rounded()) } ?? power
            if command == "G1", moving, nextPower > 0 {
                count += 1
            }
            power = command == "G0" ? 0 : nextPower
        }
        return count
    }

    private static func countBurnMoves(rasters: [RasterOutput], settings: [RasterSettings], mode: RasterGCodeMode) -> Int {
        var count = 0
        forEachRasterRow(rasters: rasters, settings: settings, mode: mode) { _, settings, _, row in
            count += row.lazy.filter { $0 >= settings.dropPowerThreshold }.count
        }
        return count
    }

    private static func previewRasterLayers(rasters: [RasterOutput], settings: [RasterSettings], mode: RasterGCodeMode) -> [GCodePreviewRaster] {
        let jobs = zip(rasters, settings).filter { valid($0.0) }
        let sourceBytes = jobs.reduce(0) { $0 + $1.0.widthPixels * $1.0.heightPixels }
        let storageStep = max(1, Int(ceil(sqrt(Double(max(1, sourceBytes)) / Double(maximumPreviewRasterBytes)))))
        var start = 0

        return jobs.map { raster, settings in
            let layer = previewRasterLayer(raster: raster, settings: settings, storageStep: storageStep, startBurnIndex: mode == .asset ? start : 0)
            if mode == .asset {
                start += layer.burnCount
            }
            return layer
        }
    }

    private static func previewRasterLayer(raster: RasterOutput, settings: RasterSettings, storageStep: Int, startBurnIndex: Int) -> GCodePreviewRaster {
        let width = max(1, (raster.widthPixels + storageStep - 1) / storageStep)
        let height = max(1, (raster.heightPixels + storageStep - 1) / storageStep)
        var powers: [UInt8] = []
        powers.reserveCapacity(width * height)
        var rowBurnOffsets = [0]
        var burnCount = 0

        for y in 0..<height {
            let sourceY = min(raster.heightPixels - 1, y * storageStep + storageStep / 2)
            var row = powerRow(at: sourceY, in: raster)
            if raster.scanDirection == .bidirectional && sourceY.isMultiple(of: 2) == false {
                row.reverse()
            }
            var rowBurnCount = 0
            for x in 0..<width {
                let sourceX = min(raster.widthPixels - 1, x * storageStep + storageStep / 2)
                let power = row[sourceX] >= settings.dropPowerThreshold ? row[sourceX] : 0
                let byte = UInt8(max(0, min(255, power * 255 / 1000)))
                powers.append(byte)
                if byte > 0 {
                    rowBurnCount += 1
                }
            }
            burnCount += rowBurnCount
            rowBurnOffsets.append(burnCount)
        }
        let display = previewDisplayRaster(powers: powers, width: width, height: height)

        return GCodePreviewRaster(
            xMM: raster.xMM,
            yMM: raster.yMM,
            widthMM: raster.widthMM,
            heightMM: raster.heightMM,
            rotationDegrees: raster.rotationDegrees,
            widthPixels: width,
            heightPixels: height,
            scanDirection: raster.scanDirection,
            powers: powers,
            rowBurnOffsets: rowBurnOffsets,
            displayWidthPixels: display.width,
            displayHeightPixels: display.height,
            displayPowers: display.powers,
            displayRowBurnOffsets: display.rowBurnOffsets,
            displayBurnCount: display.burnCount,
            startBurnIndex: startBurnIndex,
            burnCount: burnCount
        )
    }

    private static func previewDisplayRaster(powers: [UInt8], width: Int, height: Int) -> (width: Int, height: Int, powers: [UInt8], rowBurnOffsets: [Int], burnCount: Int) {
        let step = max(1, Int(ceil(Double(max(width, height)) / Double(maximumPreviewDisplayPixels))))
        guard step > 1 else { return (width, height, powers, rowBurnOffsets(from: powers, width: width), powers.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }) }
        let displayWidth = max(1, (width + step - 1) / step)
        let displayHeight = max(1, (height + step - 1) / step)
        var display: [UInt8] = []
        display.reserveCapacity(displayWidth * displayHeight)

        for y in 0..<displayHeight {
            for x in 0..<displayWidth {
                var sum = 0
                var count = 0
                for yy in (y * step)..<min(height, (y + 1) * step) {
                    for xx in (x * step)..<min(width, (x + 1) * step) {
                        sum += Int(powers[yy * width + xx])
                        count += 1
                    }
                }
                display.append(UInt8(sum == 0 || count == 0 ? 0 : max(1, (sum + count / 2) / count)))
            }
        }

        let offsets = rowBurnOffsets(from: display, width: displayWidth)
        return (displayWidth, displayHeight, display, offsets, offsets.last ?? 0)
    }

    private static func rowBurnOffsets(from powers: [UInt8], width: Int) -> [Int] {
        var offsets = [0]
        var count = 0
        for rowStart in stride(from: 0, to: powers.count, by: width) {
            count += powers[rowStart..<min(powers.count, rowStart + width)].lazy.filter { $0 > 0 }.count
            offsets.append(count)
        }
        return offsets
    }

    private static func forEachRasterRow(rasters: [RasterOutput], settings: [RasterSettings], mode: RasterGCodeMode, body: (RasterOutput, RasterSettings, Int, [Int]) -> Void) {
        switch mode {
        case .asset:
            for (raster, settings) in zip(rasters, settings) where valid(raster) {
                for y in 0..<raster.heightPixels {
                    body(raster, settings, y, powerRow(at: y, in: raster))
                }
            }
        case .scanline:
            let jobs = zip(rasters, settings).enumerated().compactMap { index, pair in
                valid(pair.0) ? (index: index, raster: pair.0, settings: pair.1) : nil
            }
            var rows: [(job: Int, y: Int, yMM: Double, xMM: Double)] = []
            for job in jobs.indices {
                for y in 0..<jobs[job].raster.heightPixels {
                    rows.append((job: job, y: y, yMM: rowY(y, raster: jobs[job].raster), xMM: jobs[job].raster.xMM))
                }
            }
            rows.sort {
                abs($0.yMM - $1.yMM) > 0.0001 ? $0.yMM < $1.yMM : $0.xMM < $1.xMM
            }
            for row in rows {
                let job = jobs[row.job]
                body(job.raster, job.settings, row.y, powerRow(at: row.y, in: job.raster))
            }
        }
    }

    private static func pixelX(_ xMM: Double, pixels: Int) -> Int {
        Int((xMM / workAreaMM * Double(pixels - 1)).rounded())
    }

    private static func pixelY(_ yMM: Double, pixels: Int) -> Int {
        Int((yMM / workAreaMM * Double(pixels - 1)).rounded())
    }

    private static func draw(_ segment: GCodePreviewSegment, into alpha: inout [UInt8], pixels: Int, radius: Int = 0) {
        let x0 = Int((segment.x0MM / workAreaMM * Double(pixels - 1)).rounded())
        let y0 = pixelY(segment.y0MM, pixels: pixels)
        let x1 = Int((segment.x1MM / workAreaMM * Double(pixels - 1)).rounded())
        let y1 = pixelY(segment.y1MM, pixels: pixels)
        let steps = max(abs(x1 - x0), abs(y1 - y0), 1)
        let value = UInt8(max(0, min(255, Int((Double(segment.power) / 1000 * 255).rounded()))))
        for step in 0...steps {
            let x = x0 + (x1 - x0) * step / steps
            let y = y0 + (y1 - y0) * step / steps
            guard (0..<pixels).contains(x), (0..<pixels).contains(y) else { continue }
            for yy in max(0, y - radius)...min(pixels - 1, y + radius) {
                alpha[yy * pixels + x] = max(alpha[yy * pixels + x], value)
            }
        }
    }

    private static func draw(_ point: GCodePreviewPoint, into alpha: inout [UInt8], pixels: Int) {
        let x = pixelX(point.xMM, pixels: pixels)
        let y = pixelY(point.yMM, pixels: pixels)
        let value = UInt8(max(0, min(255, Int((Double(point.power) / 1000 * 255).rounded()))))
        let radius = 1
        for yy in max(0, y - radius)...min(pixels - 1, y + radius) {
            for xx in max(0, x - radius)...min(pixels - 1, x + radius) {
                guard (xx - x) * (xx - x) + (yy - y) * (yy - y) <= radius * radius else { continue }
                alpha[yy * pixels + xx] = max(alpha[yy * pixels + xx], value)
            }
        }
    }

    private static func appendAssetGCode(rasters: [RasterOutput], settings: [RasterSettings], to text: inout String) {
        for (raster, settings) in zip(rasters, settings) {
            guard valid(raster) else { continue }
            text += (settings.laser == .infrared ? "M114S2\n" : "M114S1\n")
            text += "M4 S0\n"
            text += "G1 F\(fmt(settings.speedMMPerSecond * 60))\n"
            for y in 0..<raster.heightPixels {
                append(row: powerRow(at: y, in: raster), y: y, raster: raster, settings: settings, to: &text)
            }
            text += "M5\n"
        }
    }

    private static func appendScanlineGCode(rasters: [RasterOutput], settings: [RasterSettings], to text: inout String) {
        let jobs: [(raster: RasterOutput, settings: RasterSettings)] = zip(rasters, settings).compactMap {
            valid($0.0) ? (raster: $0.0, settings: $0.1) : nil
        }
        var rows: [(index: Int, y: Int, yMM: Double, xMM: Double)] = []
        for index in jobs.indices {
            let raster = jobs[index].raster
            for y in 0..<raster.heightPixels {
                rows.append((index: index, y: y, yMM: rowY(y, raster: raster), xMM: raster.xMM))
            }
        }
        rows.sort {
            abs($0.yMM - $1.yMM) > 0.0001 ? $0.yMM < $1.yMM : $0.xMM < $1.xMM
        }

        for row in rows {
            let raster = jobs[row.index].raster
            let settings = jobs[row.index].settings
            text += (settings.laser == .infrared ? "M114S2\n" : "M114S1\n")
            text += "M4 S0\n"
            text += "G1 F\(fmt(settings.speedMMPerSecond * 60))\n"
            append(row: powerRow(at: row.y, in: raster), y: row.y, raster: raster, settings: settings, to: &text)
        }
        if !rows.isEmpty {
            text += "M5\n"
        }
    }

    private static func appendProcessingAssetGCode(rasters: [RasterOutput], settings: [RasterSettings], to text: inout String) {
        for (raster, settings) in zip(rasters, settings) where valid(raster) {
            text += processingRasterHead(settings)
            for y in 0..<raster.heightPixels {
                appendProcessing(row: powerRow(at: y, in: raster), y: y, raster: raster, settings: settings, to: &text)
            }
            text += "# F1 BITMAP TAIL\n# motion_end\n"
        }
    }

    private static func appendProcessingScanlineGCode(rasters: [RasterOutput], settings: [RasterSettings], to text: inout String) {
        forEachRasterRow(rasters: rasters, settings: settings, mode: .scanline) { raster, settings, y, row in
            text += processingRasterHead(settings)
            appendProcessing(row: row, y: y, raster: raster, settings: settings, to: &text)
            text += "# F1 BITMAP TAIL\n# motion_end\n"
        }
    }

    private static func processingRasterHead(_ settings: RasterSettings) -> String {
        """
        # blockConfig={"powerFactor":\(fmt(Double(power(for: 0, settings: settings)) / 1000)),"density":\(fmt(settings.dpi)),"power":\(fmt(settings.maxPowerPercent)),"bitmapMode":"grayscale","isVector":false}
        # F1 BITMAP HEAD
        # motion_start
        \(processingLightCommand(settings.laser))
        G90

        """
    }

    private static func appendProcessing(row: [Int], y: Int, raster: RasterOutput, settings: RasterSettings, to text: inout String) {
        let reversed = raster.scanDirection == .bidirectional && y.isMultiple(of: 2) == false
        let yMM = rowY(y, raster: raster)
        let pixelWidth = raster.widthMM / Double(max(1, raster.widthPixels))
        let feed = fmt(settings.speedMMPerSecond * 60)
        for (x, power) in row.enumerated() where power >= settings.dropPowerThreshold {
            let localStart = reversed ? raster.widthMM - Double(x) * pixelWidth : Double(x) * pixelWidth
            let localEnd = reversed ? localStart - pixelWidth : localStart + pixelWidth
            let start = rasterPoint(xMM: localStart, yMM: yMM - raster.yMM, raster: raster)
            let end = rasterPoint(xMM: localEnd, yMM: yMM - raster.yMM, raster: raster)
            text += "G0 X\(fmt(start.x)) Y\(fmt(start.y))\n"
            text += "G1 X\(fmt(end.x)) Y\(fmt(end.y)) S\(power) F\(feed)\n"
            text += "G0 S0\n"
        }
    }

    private static func append(row: [Int], y: Int, raster: RasterOutput, settings: RasterSettings, to text: inout String) {
        let reversed = raster.scanDirection == .bidirectional && y.isMultiple(of: 2) == false
        let yMM = rowY(y, raster: raster)
        let step = raster.widthMM / Double(max(1, raster.widthPixels - 1))
        for (x, power) in row.enumerated() {
            if power < settings.dropPowerThreshold {
                continue
            }
            let localX = reversed ? raster.widthMM - Double(x) * step : Double(x) * step
            let point = rasterPoint(xMM: localX, yMM: yMM - raster.yMM, raster: raster)
            text += "G0 X\(fmt(point.x)) Y\(fmt(point.y))\n"
            text += "M4 S\(power)\n"
            text += "G4 P\(fmt(dwellMilliseconds(settings)))\n"
            text += "M4 S0\n"
        }
    }

    private static func rasterPoint(xMM: Double, yMM: Double, raster: RasterOutput) -> Point {
        PrintPlacement(xMM: raster.xMM, yMM: raster.yMM, widthMM: raster.widthMM, heightMM: raster.heightMM, rotationDegrees: raster.rotationDegrees)
            .absolute(Point(x: xMM / max(0.001, raster.widthMM), y: yMM / max(0.001, raster.heightMM)))
    }

    private static func rowY(_ y: Int, raster: RasterOutput) -> Double {
        raster.yMM + Double(y) * raster.heightMM / Double(max(1, raster.heightPixels - 1))
    }

    private static func dwellMilliseconds(_ settings: RasterSettings) -> Double {
        max(0.001, settings.dotDurationMicroseconds / 1000)
    }

    private static func valid(_ raster: RasterOutput) -> Bool {
        raster.widthPixels > 0 && raster.heightPixels > 0 && raster.widthMM > 0 && raster.heightMM > 0
    }

    private static func png(from gray: [UInt8], width: Int, height: Int) -> Data? {
        guard gray.count == width * height else { return nil }
        let rgba = gray.flatMap { [$0, $0, $0, UInt8(255)] }
        return png(fromRGBA: rgba, width: width, height: height)
    }

    private static func png(fromAlpha alpha: [UInt8], width: Int, height: Int) -> Data? {
        guard alpha.count == width * height else { return nil }
        let rgba = alpha.flatMap { [UInt8(0), UInt8(0), UInt8(0), $0] }
        return png(fromRGBA: rgba, width: width, height: height)
    }

    private static func png(fromRGBA rgba: [UInt8], width: Int, height: Int) -> Data? {
        guard rgba.count == width * height * 4 else { return nil }
        let provider = CGDataProvider(data: Data(rgba) as CFData)
        guard
            let provider,
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.3f", value).replacingOccurrences(of: ".000", with: "")
    }

    private static func emptyRaster(placement: PrintPlacement, settings: RasterSettings, dpi: Double) -> RasterOutput {
        let lines = [
            "; SIMULATED F1 RASTER",
            "; origin \(fmt(placement.xMM)),\(fmt(placement.yMM))mm size 0x0mm dpi \(fmt(dpi)) lines 0 cols 0",
            settings.laser == .infrared ? "M114S2" : "M114S1",
            "G1 F\(fmt(settings.speedMMPerSecond * 60))",
            "; END SIMULATION"
        ]
        return RasterOutput(widthPixels: 0, heightPixels: 0, xMM: max(0, min(workAreaMM, placement.xMM)), yMM: max(0, min(workAreaMM, placement.yMM)), widthMM: 0, heightMM: 0, rotationDegrees: placement.rotationDegrees, scanDirection: settings.scanDirection, dropPowerThreshold: settings.dropPowerThreshold, lines: lines)
    }
}

public enum RasterError: Error {
    case badImage
}

public enum VectorOutlineGenerator {
    private static let maximumTraceSide = 640

    public static func outline(bitmap: PhotoBitmap, settings: RasterSettings, offsetMM: Double = 2, includeInterior: Bool = false) -> VectorOutline? {
        guard bitmap.width > 0, bitmap.height > 0 else { return nil }
        let placement = RasterGenerator.sizeConstrained(settings.placement)
        let scale = min(1, Double(maximumTraceSide) / Double(max(bitmap.width, bitmap.height)))
        let cols = max(1, Int((Double(bitmap.width) * scale).rounded()))
        let rows = max(1, Int((Double(bitmap.height) * scale).rounded()))
        let mask = transparencyMask(bitmap: bitmap, width: cols, height: rows)
        return outline(mask: mask, width: cols, height: rows, placement: placement, offsetMM: offsetMM, includeInterior: includeInterior)
    }

    public static func outline(mask: [Bool], width: Int, height: Int, placement: PrintPlacement, offsetMM: Double = 0, includeInterior: Bool = false) -> VectorOutline? {
        guard width > 0, height > 0, mask.count == width * height else { return nil }
        guard mask.contains(true) else { return nil }
        let pitch = min(placement.widthMM / Double(width), placement.heightMM / Double(height))
        let radius = max(0, Int((max(0, offsetMM) / max(0.001, pitch)).rounded(.up)))
        let dilated = dilate(mask: mask, width: width, height: height, radius: radius)
        let absolutePaths = trace(mask: dilated.values, width: dilated.width, height: dilated.height)
            .filter { includeInterior || signedArea($0) > 0 }
            .map { path in
                path.map { point in
                    Point(
                        x: placement.xMM + (point.x - Double(radius)) * placement.widthMM / Double(width),
                        y: placement.yMM + (point.y - Double(radius)) * placement.heightMM / Double(height)
                    )
                }
            }
            .filter { $0.count > 2 }
        guard let outline = normalize(absolutePaths) else { return nil }
        return outline
    }

    private static func transparencyMask(bitmap: PhotoBitmap, width: Int, height: Int) -> [Bool] {
        var mask = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            let sourceY = y * bitmap.height / height
            for x in 0..<width {
                let sourceX = x * bitmap.width / width
                let i = bitmap.offset(x: sourceX, y: sourceY)
                mask[y * width + x] = bitmap.pixels[i + 3] > 0
            }
        }
        return mask
    }

    private static func dilate(mask: [Bool], width: Int, height: Int, radius: Int) -> (values: [Bool], width: Int, height: Int) {
        let outWidth = width + radius * 2
        let outHeight = height + radius * 2
        var output = [Bool](repeating: false, count: outWidth * outHeight)
        let r2 = radius * radius
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                for dy in -radius...radius {
                    for dx in -radius...radius where dx * dx + dy * dy <= r2 {
                        let xx = x + radius + dx
                        let yy = y + radius + dy
                        guard (0..<outWidth).contains(xx), (0..<outHeight).contains(yy) else { continue }
                        output[yy * outWidth + xx] = true
                    }
                }
            }
        }
        return (output, outWidth, outHeight)
    }

    private struct GridPoint: Hashable {
        var x: Int
        var y: Int
    }

    private struct Edge: Hashable {
        var start: GridPoint
        var end: GridPoint
    }

    private static func trace(mask: [Bool], width: Int, height: Int) -> [[Point]] {
        var edges: [Edge] = []
        func filled(_ x: Int, _ y: Int) -> Bool {
            (0..<width).contains(x) && (0..<height).contains(y) && mask[y * width + x]
        }
        for y in 0..<height {
            for x in 0..<width where filled(x, y) {
                if !filled(x, y - 1) { edges.append(Edge(start: GridPoint(x: x, y: y), end: GridPoint(x: x + 1, y: y))) }
                if !filled(x + 1, y) { edges.append(Edge(start: GridPoint(x: x + 1, y: y), end: GridPoint(x: x + 1, y: y + 1))) }
                if !filled(x, y + 1) { edges.append(Edge(start: GridPoint(x: x + 1, y: y + 1), end: GridPoint(x: x, y: y + 1))) }
                if !filled(x - 1, y) { edges.append(Edge(start: GridPoint(x: x, y: y + 1), end: GridPoint(x: x, y: y))) }
            }
        }

        var outgoing: [GridPoint: [GridPoint]] = [:]
        for edge in edges {
            outgoing[edge.start, default: []].append(edge.end)
        }

        var used = Set<Edge>()
        var paths: [[Point]] = []
        for edge in edges where !used.contains(edge) {
            var grid = [edge.start]
            var current = edge
            used.insert(current)
            while current.end != grid[0] {
                grid.append(current.end)
                guard let next = outgoing[current.end]?.first(where: { !used.contains(Edge(start: current.end, end: $0)) }) else { break }
                current = Edge(start: current.end, end: next)
                used.insert(current)
            }
            let simplified = simplify(grid)
            if simplified.count > 2 {
                paths.append(simplified.map { Point(x: Double($0.x), y: Double($0.y)) })
            }
        }
        return paths
    }

    private static func simplify(_ points: [GridPoint]) -> [GridPoint] {
        guard points.count > 2 else { return points }
        return points.indices.compactMap { index in
            let previous = points[(index + points.count - 1) % points.count]
            let current = points[index]
            let next = points[(index + 1) % points.count]
            let ax = current.x - previous.x
            let ay = current.y - previous.y
            let bx = next.x - current.x
            let by = next.y - current.y
            return ax * by == ay * bx ? nil : current
        }
    }

    private static func normalize(_ paths: [[Point]]) -> VectorOutline? {
        let points = paths.flatMap { $0 }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(), let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        let width = max(0.001, maxX - minX)
        let height = max(0.001, maxY - minY)
        let normalized = paths.map { path in
            LaserPath(closed: true, points: path.map { Point(x: ($0.x - minX) / width, y: ($0.y - minY) / height) })
        }
        return VectorOutline(placement: PrintPlacement(xMM: minX, yMM: minY, widthMM: width, heightMM: height), paths: normalized)
    }

    private static func signedArea(_ points: [Point]) -> Double {
        guard points.count > 2 else { return 0 }
        var area = 0.0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            area += points[index].x * next.y - next.x * points[index].y
        }
        return area / 2
    }
}

public enum VectorGCodeGenerator {
    public static func makeGCodeBody(paths: [LaserPath], settings: VectorSettings) -> String {
        let paths = paths.centerOutCutOrder(relativeTo: workAreaCenter, placement: settings.placement)
        guard !paths.isEmpty else { return "" }
        var text = settings.laser == .infrared ? "M114S2\n" : "M114S1\n"
        let power = power(settings.powerPercent)
        text += "M5\n"
        text += "G1 F\(fmt(settings.speedMMPerSecond * 60))\n"
        for path in paths {
            let first = absolute(path.points[0], settings: settings)
            text += "G0 X\(fmt(first.x)) Y\(fmt(first.y))\n"
            text += "M3 S\(power)\n"
            for point in path.points.dropFirst().map({ absolute($0, settings: settings) }) {
                text += "G1 X\(fmt(point.x)) Y\(fmt(point.y))\n"
            }
            if path.closed {
                text += "G1 X\(fmt(first.x)) Y\(fmt(first.y))\n"
            }
            text += "M5\n"
        }
        return text
    }

    static func makeProcessingGCodeBody(paths: [LaserPath], settings: VectorSettings, preserveOrder: Bool = false) -> String {
        let paths = preserveOrder ? paths.filter { $0.points.count > 1 } : paths.centerOutCutOrder(relativeTo: workAreaCenter, placement: settings.placement)
        guard !paths.isEmpty else { return "" }
        let power = power(settings.powerPercent)
        let feed = fmt(settings.speedMMPerSecond * 60)
        var text = """
        # blockConfig={"powerFactor": \(fmt(Double(power) / 1000)), "isVector": true}
        # F1 VECTOR HEAD
        # motion_start
        \(processingLightCommand(settings.laser))
        G90

        """
        for path in paths {
            let first = absolute(path.points[0], settings: settings)
            text += "G0 X\(fmt(first.x)) Y\(fmt(first.y))\n"
            for point in path.points.dropFirst().map({ absolute($0, settings: settings) }) {
                text += "G1 X\(fmt(point.x)) Y\(fmt(point.y)) S\(power) F\(feed)\n"
            }
            if path.closed {
                text += "G1 X\(fmt(first.x)) Y\(fmt(first.y)) S\(power) F\(feed)\n"
            }
            text += "G0 S0\n"
        }
        text += "# F1 VECTOR TAIL\n# motion_end\n"
        return text
    }

    public static func length(paths: [LaserPath], settings: VectorSettings) -> Double {
        paths.reduce(0) { total, path in
            guard path.points.count > 1 else { return total }
            let points = path.points.map { absolute($0, settings: settings) }
            let openLength = zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
            guard path.closed, let first = points.first, let last = points.last else { return total + openLength }
            return total + openLength + hypot(first.x - last.x, first.y - last.y)
        }
    }

    public static func previewSegments(paths: [LaserPath], settings: VectorSettings, startSecond: Double, durationSeconds: Double, preserveOrder: Bool = false) -> [GCodePreviewSegment] {
        let power = power(settings.powerPercent)
        let orderedPaths = preserveOrder ? paths.filter { $0.points.count > 1 } : paths.centerOutCutOrder(relativeTo: workAreaCenter, placement: settings.placement)
        let segments = orderedPaths.flatMap { path -> [GCodePreviewSegment] in
            let points = path.points.map { absolute($0, settings: settings) }
            var output = zip(points, points.dropFirst()).map {
                GCodePreviewSegment(x0MM: $0.0.x, y0MM: $0.0.y, x1MM: $0.1.x, y1MM: $0.1.y, power: power)
            }
            if path.closed, let first = points.first, let last = points.last {
                output.append(GCodePreviewSegment(x0MM: last.x, y0MM: last.y, x1MM: first.x, y1MM: first.y, power: power))
            }
            return output
        }
        let total = max(0.001, segments.reduce(0) { $0 + hypot($1.x1MM - $1.x0MM, $1.y1MM - $1.y0MM) })
        var time = startSecond
        return segments.map { segment in
            let duration = durationSeconds * hypot(segment.x1MM - segment.x0MM, segment.y1MM - segment.y0MM) / total
            defer { time += duration }
            return GCodePreviewSegment(x0MM: segment.x0MM, y0MM: segment.y0MM, x1MM: segment.x1MM, y1MM: segment.y1MM, power: segment.power, startSecond: time, durationSeconds: duration)
        }
    }

    private static func absolute(_ point: Point, settings: VectorSettings) -> Point {
        settings.placement.absolute(point)
    }

    private static var workAreaCenter: Point {
        Point(x: RasterGenerator.workAreaMM / 2, y: RasterGenerator.workAreaMM / 2)
    }

    private static func power(_ percent: Double) -> Int {
        max(0, min(1000, Int((percent * 10).rounded())))
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.3f", value).replacingOccurrences(of: ".000", with: "")
    }
}

public enum TextVectorGenerator {
    private static let millimetersPerPoint = 25.4 / 72.0

    public static func paths(for settings: TextSettings, placement: PrintPlacement) -> [LaserPath] {
        let boxWidth = max(1, placement.widthMM / millimetersPerPoint)
        let boxHeight = max(1, placement.heightMM / millimetersPerPoint)
        let lines = wrappedLines(for: settings, boxWidthPoints: boxWidth)
        return fit(rawPaths(for: settings, lines: lines, boxWidth: boxWidth), boxWidth: boxWidth, boxHeight: boxHeight, alignment: settings.alignment)
    }

    public static func wrappedLines(for settings: TextSettings, boxWidthPoints: Double) -> [String] {
        let font = CTFontCreateWithName(settings.fontFamily as CFString, max(1, settings.fontSize), nil)
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTKernAttributeName as NSAttributedString.Key: settings.letterSpacing
        ]

        var lines: [String] = []
        for paragraph in settings.text.components(separatedBy: .newlines) {
            let words = paragraph.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = words.first else {
                lines.append("")
                continue
            }
            var line = first
            for word in words.dropFirst() {
                let candidate = "\(line) \(word)"
                if lineWidth(candidate, attributes: attributes) <= boxWidthPoints {
                    line = candidate
                } else {
                    lines.append(line)
                    line = word
                }
            }
            lines.append(line)
        }
        return lines
    }

    private static func rawPaths(for settings: TextSettings, lines: [String], boxWidth: Double) -> [LaserPath] {
        let font = CTFontCreateWithName(settings.fontFamily as CFString, max(1, settings.fontSize), nil)
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTKernAttributeName as NSAttributedString.Key: settings.letterSpacing
        ]
        let lineHeight = max(1, settings.fontSize + max(0, settings.leading))
        var output: [LaserPath] = []
        for (row, text) in lines.enumerated() where !text.isEmpty {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let width = lineWidth(line)
            let x: Double
            switch settings.alignment {
            case .left:
                x = 0
            case .center:
                x = max(0, (boxWidth - width) / 2)
            case .right:
                x = max(0, boxWidth - width)
            }
            output += rawPaths(for: line, font: font, offset: CGPoint(x: x, y: -(settings.fontSize + Double(row) * lineHeight)))
        }
        return output
    }

    private static func rawPaths(for line: CTLine, font: CTFont, offset: CGPoint) -> [LaserPath] {
        let runs = CTLineGetGlyphRuns(line) as NSArray
        var output: [LaserPath] = []
        for runValue in runs {
            let run = runValue as! CTRun
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for index in glyphs.indices {
                guard let path = CTFontCreatePathForGlyph(font, glyphs[index], nil) else { continue }
                output += flatten(path: path, offset: CGPoint(x: positions[index].x + offset.x, y: positions[index].y + offset.y))
            }
        }
        return output
    }

    private static func fit(_ raw: [LaserPath], boxWidth: Double, boxHeight: Double, alignment: LaserTextAlignment) -> [LaserPath] {
        let local = raw.map { path in
            LaserPath(closed: path.closed, points: path.points.map {
                Point(x: $0.x / boxWidth, y: $0.y / boxHeight)
            })
        }
        let points = local.flatMap(\.points)
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(), let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return [] }
        let width = max(0.001, maxX - minX)
        let height = max(0.001, maxY - minY)
        let scale = min(1, min(1 / width, 1 / height))
        let xShift: Double
        switch alignment {
        case .left:
            xShift = -minX * scale
        case .center:
            xShift = (1 - width * scale) / 2 - minX * scale
        case .right:
            xShift = 1 - maxX * scale
        }
        let yShift = (1 - height * scale) / 2 - minY * scale
        return local.map { path in
            LaserPath(closed: path.closed, points: path.points.map {
                Point(x: $0.x * scale + xShift, y: $0.y * scale + yShift)
            })
        }
    }

    private static func lineWidth(_ text: String, attributes: [NSAttributedString.Key: Any]) -> Double {
        lineWidth(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)))
    }

    private static func lineWidth(_ line: CTLine) -> Double {
        var ascent = CGFloat.zero
        var descent = CGFloat.zero
        var leading = CGFloat.zero
        return Double(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    }

    private static func flatten(path: CGPath, offset: CGPoint) -> [LaserPath] {
        var output: [LaserPath] = []
        var current: [Point] = []
        var cursor = CGPoint.zero
        var subpathStart = CGPoint.zero
        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint:
                appendOpen(&current, to: &output)
                cursor = shifted(element.points[0], offset: offset)
                subpathStart = cursor
                current = [Point(x: cursor.x, y: -cursor.y)]
            case .addLineToPoint:
                cursor = shifted(element.points[0], offset: offset)
                current.append(Point(x: cursor.x, y: -cursor.y))
            case .addQuadCurveToPoint:
                let start = cursor
                let control = shifted(element.points[0], offset: offset)
                let end = shifted(element.points[1], offset: offset)
                for step in 1...8 {
                    let point = quad(start, control, end, CGFloat(step) / 8)
                    current.append(Point(x: point.x, y: -point.y))
                }
                cursor = end
            case .addCurveToPoint:
                let start = cursor
                let c1 = shifted(element.points[0], offset: offset)
                let c2 = shifted(element.points[1], offset: offset)
                let end = shifted(element.points[2], offset: offset)
                for step in 1...12 {
                    let point = cubic(start, c1, c2, end, CGFloat(step) / 12)
                    current.append(Point(x: point.x, y: -point.y))
                }
                cursor = end
            case .closeSubpath:
                if current.count > 2 {
                    output.append(LaserPath(closed: true, points: current))
                }
                current = []
                cursor = subpathStart
            @unknown default:
                break
            }
        }
        appendOpen(&current, to: &output)
        return output
    }

    private static func shifted(_ point: CGPoint, offset: CGPoint) -> CGPoint {
        CGPoint(x: point.x + offset.x, y: point.y + offset.y)
    }

    private static func appendOpen(_ current: inout [Point], to output: inout [LaserPath]) {
        if current.count > 1 {
            output.append(LaserPath(closed: false, points: current))
        }
        current = []
    }

    private static func quad(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * b.x + t * t * c.x, y: u * u * a.y + 2 * u * t * b.y + t * t * c.y)
    }

    private static func cubic(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x,
            y: u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y
        )
    }
}

public struct EditableVectorSelection: Equatable, Sendable {
    public var segmentIndex: Int
    public var nodeIndex: Int

    public init(segmentIndex: Int, nodeIndex: Int) {
        self.segmentIndex = segmentIndex
        self.nodeIndex = nodeIndex
    }
}

public enum VectorDrawingGenerator {
    public static func drawing(rawSegments: [[Point]], smoothness: Double = 0, accuracy: Double = 0) -> EditableVectorDrawing {
        fitted(EditableVectorDrawing(rawSegments: rawSegments, smoothness: smoothness, accuracy: accuracy))
    }

    public static func drawing(paths: [LaserPath]) -> EditableVectorDrawing {
        drawing(rawSegments: paths.map(\.points), smoothness: 0)
    }

    public static func appending(_ segment: [Point], to drawing: EditableVectorDrawing) -> EditableVectorDrawing {
        var raw = drawing.rawSegments
        if segment.count > 1 {
            raw.append(segment)
        }
        return self.drawing(rawSegments: raw, smoothness: drawing.smoothness, accuracy: drawing.accuracy)
    }

    public static func fitted(_ drawing: EditableVectorDrawing) -> EditableVectorDrawing {
        let raw = drawing.rawSegments.map { cleaned($0) }.filter { $0.count > 1 }
        let smoothness = min(1, max(0, drawing.smoothness))
        let accuracy = min(1, max(0, drawing.accuracy))
        let existing = drawing.nodes
        let nodes = raw.indices.map { index in
            existing.indices.contains(index) && !existing[index].isEmpty ? smoothed(existing[index], smoothness: smoothness) : fittedNodes(for: raw[index], smoothness: smoothness, accuracy: accuracy)
        }
        return EditableVectorDrawing(rawSegments: raw, smoothness: smoothness, accuracy: accuracy, nodes: nodes)
    }

    public static func paths(for drawing: EditableVectorDrawing) -> [LaserPath] {
        let drawing = fitted(drawing)
        return drawing.nodes.enumerated().compactMap { index, nodes in
            let raw = drawing.rawSegments.indices.contains(index) ? drawing.rawSegments[index] : nodes.map(\.point)
            let points = drawing.smoothness <= 0 ? nodes.map(\.point) : flattened(nodes: nodes, raw: raw)
            return points.count > 1 ? LaserPath(closed: false, points: points) : nil
        }
    }

    public static func connect(_ drawing: EditableVectorDrawing, _ first: EditableVectorSelection, _ second: EditableVectorSelection) -> EditableVectorDrawing {
        let drawing = fitted(drawing)
        guard first.segmentIndex != second.segmentIndex,
              drawing.nodes.indices.contains(first.segmentIndex),
              drawing.nodes.indices.contains(second.segmentIndex)
        else { return drawing }
        var segments = drawing.nodes.map { $0.map(\.point) }
        guard isEndpoint(first, in: segments), isEndpoint(second, in: segments) else { return drawing }
        var left = segments[first.segmentIndex]
        var right = segments[second.segmentIndex]
        if first.nodeIndex == 0 { left.reverse() }
        if second.nodeIndex == right.count - 1 { right.reverse() }
        left += right
        segments[first.segmentIndex] = left
        segments.remove(at: second.segmentIndex)
        return self.drawing(rawSegments: segments, smoothness: drawing.smoothness, accuracy: drawing.accuracy)
    }

    public static func disconnect(_ drawing: EditableVectorDrawing, at selection: EditableVectorSelection) -> EditableVectorDrawing {
        let drawing = fitted(drawing)
        guard drawing.nodes.indices.contains(selection.segmentIndex) else { return drawing }
        var segments = drawing.nodes.map { $0.map(\.point) }
        let segment = segments[selection.segmentIndex]
        guard selection.nodeIndex > 0, selection.nodeIndex < segment.count - 1 else { return drawing }
        segments[selection.segmentIndex] = Array(segment[...selection.nodeIndex])
        segments.insert(Array(segment[selection.nodeIndex...]), at: selection.segmentIndex + 1)
        return self.drawing(rawSegments: segments, smoothness: drawing.smoothness, accuracy: drawing.accuracy)
    }

    public static func erasing(_ drawing: EditableVectorDrawing, stroke: [Point], radius: Double) -> EditableVectorDrawing {
        let drawing = fitted(drawing)
        let stroke = cleaned(stroke)
        guard !stroke.isEmpty else { return drawing }
        let limit = max(0.0001, min(1, radius))
        var segments: [[Point]] = []
        for segment in paths(for: drawing).map(\.points) {
            var current: [Point] = []
            for index in 0..<(segment.count - 1) {
                let erased = minimumDistance(from: segment[index], to: segment[index + 1], stroke: stroke) <= limit
                if erased {
                    if current.count > 1 { segments.append(current) }
                    current = []
                } else {
                    if current.isEmpty { current.append(segment[index]) }
                    current.append(segment[index + 1])
                }
            }
            if current.count > 1 { segments.append(current) }
        }
        return self.drawing(rawSegments: segments, smoothness: drawing.smoothness, accuracy: drawing.accuracy)
    }

    public static func fittedNodes(for points: [Point], smoothness: Double, accuracy: Double = 0) -> [EditableVectorNode] {
        let points = cleaned(points)
        guard points.count > 2, smoothness > 0 else { return points.map { EditableVectorNode(point: $0) } }
        let accuracy = min(1, max(0, accuracy))
        let tolerance = 0.0007 + smoothness * smoothness * (0.075 * pow(1 - accuracy, 2) + 0.004 * (1 - accuracy))
        let cumulative = cumulativeLengths(points)
        var indices = [0, points.count - 1]
        while let split = worstSplit(points: points, cumulative: cumulative, indices: indices), split.error > tolerance, indices.count < points.count {
            indices.append(split.index)
            indices.sort()
        }
        return smoothed(indices.map { EditableVectorNode(point: points[$0]) }, smoothness: smoothness)
    }

    private static func cleaned(_ points: [Point]) -> [Point] {
        points.reduce(into: []) { output, point in
            if output.last.map({ distance($0, point) > 0.0001 }) ?? true {
                output.append(Point(x: min(1, max(0, point.x)), y: min(1, max(0, point.y))))
            }
        }
    }

    private static func isEndpoint(_ selection: EditableVectorSelection, in segments: [[Point]]) -> Bool {
        guard segments.indices.contains(selection.segmentIndex) else { return false }
        return selection.nodeIndex == 0 || selection.nodeIndex == segments[selection.segmentIndex].count - 1
    }

    private static func worstSplit(points: [Point], cumulative: [Double], indices: [Int]) -> (index: Int, error: Double)? {
        var worst: (index: Int, error: Double)?
        for pair in zip(indices, indices.dropFirst()) where pair.1 - pair.0 > 1 {
            let control = controlPoint(points: points, cumulative: cumulative, start: pair.0, end: pair.1)
            for index in (pair.0 + 1)..<pair.1 {
                let t = parameter(cumulative, start: pair.0, end: pair.1, index: index)
                let error = distance(points[index], quad(points[pair.0], control, points[pair.1], t))
                if worst == nil || error > worst!.error {
                    worst = (index, error)
                }
            }
        }
        return worst
    }

    private static func flattened(nodes: [EditableVectorNode], raw: [Point]) -> [Point] {
        guard let first = nodes.first?.point else { return [] }
        var output = [first]
        let rawIndices = nodeRawIndices(nodes: nodes, raw: raw)
        let cumulative = cumulativeLengths(raw)
        for index in 0..<(nodes.count - 1) {
            let start = nodes[index]
            let end = nodes[index + 1]
            let control = controlPoint(points: raw, cumulative: cumulative, start: rawIndices[index], end: rawIndices[index + 1])
            let firstControl = start.tangent.map { Point(x: start.point.x + $0.x, y: start.point.y + $0.y) } ?? control
            let secondControl = end.tangent.map { Point(x: end.point.x - $0.x, y: end.point.y - $0.y) } ?? control
            let steps = max(3, Int(distance(start.point, end.point) * 80))
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                output.append(start.tangent == nil && end.tangent == nil ? quad(start.point, control, end.point, t) : cubic(start.point, firstControl, secondControl, end.point, t))
            }
        }
        return output
    }

    private static func nodeRawIndices(nodes: [EditableVectorNode], raw: [Point]) -> [Int] {
        var minimum = 0
        return nodes.map { node in
            let match = raw.indices.dropFirst(minimum).min { distance(raw[$0], node.point) < distance(raw[$1], node.point) } ?? minimum
            minimum = match
            return match
        }
    }

    private static func smoothed(_ nodes: [EditableVectorNode], smoothness: Double) -> [EditableVectorNode] {
        guard smoothness > 0, nodes.count > 1 else {
            return nodes.map { EditableVectorNode(point: $0.point) }
        }
        let factor = 0.28 * min(1, max(0, smoothness))
        return nodes.indices.map { index in
            let point = nodes[index].point
            let previous = index > 0 ? nodes[index - 1].point : point
            let next = index < nodes.count - 1 ? nodes[index + 1].point : point
            let vector = index == 0 ? Point(x: next.x - point.x, y: next.y - point.y)
                : index == nodes.count - 1 ? Point(x: point.x - previous.x, y: point.y - previous.y)
                : Point(x: next.x - previous.x, y: next.y - previous.y)
            let limit = 0.45 * ([distance(point, previous), distance(point, next)].filter { $0 > 0.0001 }.min() ?? 0)
            let scaled = Point(x: vector.x * factor, y: vector.y * factor)
            let length = distance(Point(x: 0, y: 0), scaled)
            let tangent = length > limit && limit > 0 ? Point(x: scaled.x * limit / length, y: scaled.y * limit / length) : scaled
            return EditableVectorNode(point: point, tangent: nodes[index].tangent ?? tangent)
        }
    }

    private static func controlPoint(points: [Point], cumulative: [Double], start: Int, end: Int) -> Point {
        guard points.indices.contains(start), points.indices.contains(end), end > start else { return Point(x: 0.5, y: 0.5) }
        let a = points[start]
        let b = points[end]
        var numerator = Point(x: 0, y: 0)
        var denominator = 0.0
        for index in start...end {
            let t = parameter(cumulative, start: start, end: end, index: index)
            let u = 1 - t
            let q = 2 * u * t
            numerator.x += q * (points[index].x - u * u * a.x - t * t * b.x)
            numerator.y += q * (points[index].y - u * u * a.y - t * t * b.y)
            denominator += q * q
        }
        guard denominator > 0.000001 else { return Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        return Point(x: numerator.x / denominator, y: numerator.y / denominator)
    }

    private static func cumulativeLengths(_ points: [Point]) -> [Double] {
        points.reduce(into: [Double]()) { output, point in
            output.append((output.last ?? 0) + (output.indices.isEmpty ? 0 : distance(points[output.count - 1], point)))
        }
    }

    private static func parameter(_ cumulative: [Double], start: Int, end: Int, index: Int) -> Double {
        guard cumulative.indices.contains(start), cumulative.indices.contains(end), cumulative.indices.contains(index) else { return 0 }
        let length = cumulative[end] - cumulative[start]
        return length > 0.000001 ? min(1, max(0, (cumulative[index] - cumulative[start]) / length)) : Double(index - start) / Double(max(1, end - start))
    }

    private static func minimumDistance(from a: Point, to b: Point, stroke: [Point]) -> Double {
        guard stroke.count > 1 else { return pointDistance(stroke[0], toSegmentFrom: a, to: b) }
        return zip(stroke, stroke.dropFirst()).map { segmentDistance(a, b, $0, $1) }.min() ?? .infinity
    }

    private static func segmentDistance(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Double {
        if segmentsIntersect(a, b, c, d) { return 0 }
        return min(pointDistance(a, toSegmentFrom: c, to: d), pointDistance(b, toSegmentFrom: c, to: d), pointDistance(c, toSegmentFrom: a, to: b), pointDistance(d, toSegmentFrom: a, to: b))
    }

    private static func pointDistance(_ point: Point, toSegmentFrom a: Point, to b: Point) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.0000001 else { return distance(point, a) }
        let t = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return distance(point, Point(x: a.x + dx * t, y: a.y + dy * t))
    }

    private static func segmentsIntersect(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
        guard max(min(a.x, b.x), min(c.x, d.x)) <= min(max(a.x, b.x), max(c.x, d.x)) + 0.0000001,
              max(min(a.y, b.y), min(c.y, d.y)) <= min(max(a.y, b.y), max(c.y, d.y)) + 0.0000001
        else { return false }
        let abC = cross(a, b, c)
        let abD = cross(a, b, d)
        let cdA = cross(c, d, a)
        let cdB = cross(c, d, b)
        return abC * abD <= 0.0000001 && cdA * cdB <= 0.0000001
    }

    private static func cross(_ a: Point, _ b: Point, _ c: Point) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func quad(_ a: Point, _ b: Point, _ c: Point, _ t: Double) -> Point {
        let u = 1 - t
        return Point(x: u * u * a.x + 2 * u * t * b.x + t * t * c.x, y: u * u * a.y + 2 * u * t * b.y + t * t * c.y)
    }

    private static func cubic(_ a: Point, _ b: Point, _ c: Point, _ d: Point, _ t: Double) -> Point {
        let u = 1 - t
        return Point(
            x: u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x,
            y: u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y
        )
    }

    private static func distance(_ a: Point, _ b: Point) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }
}

public enum FrameGCodeGenerator {
    public static let maximumFrameSpeedMMPerSecond = 4000.0

    public static func makeGCode(for project: StoredProject, rasterData: [UUID: Data]) -> String {
        makeGCode(for: project.photos, rasterData: rasterData, speedMMPerSecond: project.frameSpeedMMPerSecond, mode: project.frameMode)
    }

    public static func makeGCode(for photos: [ProjectPhoto], rasterData: [UUID: Data], speedMMPerSecond: Double, mode: FrameMode = .outline) -> String {
        let paths = framePaths(for: photos, rasterData: rasterData, mode: mode)
        return makeGCode(paths: paths.isEmpty ? fallbackPaths : paths, speedMMPerSecond: speedMMPerSecond)
    }

    public static func framePaths(for photos: [ProjectPhoto], rasterData: [UUID: Data], mode: FrameMode = .outline) -> [LaserPath] {
        let objects = photos.filter(\.isEnabled).compactMap { photo -> FrameObject? in
            switch photo.mode {
            case .raster:
                guard
                    let data = rasterData[photo.id],
                    let mask = try? RasterGenerator.burnMask(from: data, settings: photo.settings),
                    let outline = VectorOutlineGenerator.outline(mask: mask.values, width: mask.width, height: mask.height, placement: mask.placement)
                else { return nil }
                return FrameObject(paths: absolute(outline.paths, placement: outline.placement))
            case .vector, .text:
                return FrameObject(paths: absolute(printablePaths(for: photo), placement: photo.resolvedVectorSettings.placement))
            }
        }
        return grouped(objects, mode: mode)
    }

    private static func printablePaths(for photo: ProjectPhoto) -> [LaserPath] {
        photo.mode == .text && photo.vectorPaths.isEmpty ? TextVectorGenerator.paths(for: photo.resolvedTextSettings, placement: photo.printPlacement) : photo.vectorPaths
    }

    private static func makeGCode(paths: [LaserPath], speedMMPerSecond: Double) -> String {
        let feed = fmt(min(maximumFrameSpeedMMPerSecond, max(1, speedMMPerSecond)) * 60)
        var lines = [
            "# F1 WALK BORDER",
            "G0 F180000",
            "M4 S0",
            "G1 F180000",
            "M114 S1"
        ]
        for path in paths {
            let points = path.points
            guard let first = points.first, points.count > 1 else { continue }
            lines.append("G0 X\(fmt(first.x)) Y\(fmt(first.y))")
            for (index, point) in points.dropFirst().enumerated() {
                lines.append("G1 X\(fmt(point.x)) Y\(fmt(point.y))\(index == 0 ? " S60 F\(feed)" : "")")
            }
            if path.closed {
                lines.append("G1 X\(fmt(first.x)) Y\(fmt(first.y))")
            }
            lines.append("G0 S0")
        }
        lines.append("# END")
        return lines.joined(separator: "\n") + "\n\n"
    }

    private static func absolute(_ paths: [LaserPath], placement: PrintPlacement) -> [LaserPath] {
        paths.map { path in
            LaserPath(closed: path.closed, points: path.points.map {
                Point(x: placement.xMM + $0.x * placement.widthMM, y: placement.yMM + $0.y * placement.heightMM)
            })
        }
    }

    private static func grouped(_ objects: [FrameObject], mode: FrameMode) -> [LaserPath] {
        if mode == .wrap { return wrap(objects) }
        var groups: [[FrameObject]] = []
        for object in objects {
            guard object.bounds != nil else { continue }
            var group = [object]
            var index = 0
            while index < groups.count {
                if groups[index].contains(where: { existing in group.contains { overlaps(existing, $0) } }) {
                    group += groups.remove(at: index)
                    index = 0
                } else {
                    index += 1
                }
            }
            groups.append(group)
        }
        return groups.flatMap { group in
            switch mode {
            case .outline:
                return group.count == 1 ? group[0].paths : union(group) ?? group.flatMap(\.paths)
            case .rectangle:
                return Bounds.union(group.compactMap(\.bounds)).map { [rectangle($0)] } ?? []
            case .wrap:
                return []
            }
        }
    }

    private static func wrap(_ objects: [FrameObject]) -> [LaserPath] {
        let points = convexHull(objects.flatMap { $0.paths.flatMap(\.points) })
        guard points.count > 1 else { return [] }
        return [LaserPath(closed: points.count > 2, points: points)]
    }

    private static func union(_ group: [FrameObject]) -> [LaserPath]? {
        guard let bounds = Bounds.union(group.compactMap(\.bounds)) else { return nil }
        let pitch = 0.25
        let width = max(1, Int((bounds.width / pitch).rounded(.up)))
        let height = max(1, Int((bounds.height / pitch).rounded(.up)))
        let placement = PrintPlacement(xMM: bounds.minX, yMM: bounds.minY, widthMM: max(0.001, bounds.width), heightMM: max(0.001, bounds.height))
        var mask = [Bool](repeating: false, count: width * height)

        for object in group {
            for path in object.paths {
                fill(path, in: &mask, width: width, height: height, placement: placement)
            }
        }
        guard let outline = VectorOutlineGenerator.outline(mask: mask, width: width, height: height, placement: placement) else { return nil }
        return absolute(outline.paths, placement: outline.placement)
    }

    private static func overlaps(_ left: FrameObject, _ right: FrameObject) -> Bool {
        guard let leftBounds = left.bounds, let rightBounds = right.bounds, leftBounds.overlaps(rightBounds) else { return false }
        for leftPath in left.paths {
            for rightPath in right.paths {
                if pathsOverlap(leftPath, rightPath) { return true }
            }
        }
        return false
    }

    private static func pathsOverlap(_ left: LaserPath, _ right: LaserPath) -> Bool {
        for leftSegment in segments(left) {
            for rightSegment in segments(right) where segmentsIntersect(leftSegment.0, leftSegment.1, rightSegment.0, rightSegment.1) {
                return true
            }
        }
        if left.closed, right.points.contains(where: { contains($0, in: left.points) }) { return true }
        if right.closed, left.points.contains(where: { contains($0, in: right.points) }) { return true }
        return false
    }

    private static func segments(_ path: LaserPath) -> [(Point, Point)] {
        var pairs = Array(zip(path.points, path.points.dropFirst()))
        if path.closed, let first = path.points.first, let last = path.points.last {
            pairs.append((last, first))
        }
        return pairs
    }

    private static func segmentsIntersect(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
        let d1 = direction(c, d, a)
        let d2 = direction(c, d, b)
        let d3 = direction(a, b, c)
        let d4 = direction(a, b, d)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
            || d1 == 0 && onSegment(a, c, d)
            || d2 == 0 && onSegment(b, c, d)
            || d3 == 0 && onSegment(c, a, b)
            || d4 == 0 && onSegment(d, a, b)
    }

    private static func direction(_ a: Point, _ b: Point, _ c: Point) -> Double {
        let value = (c.x - a.x) * (b.y - a.y) - (b.x - a.x) * (c.y - a.y)
        return abs(value) < 0.000001 ? 0 : value
    }

    private static func onSegment(_ point: Point, _ a: Point, _ b: Point) -> Bool {
        min(a.x, b.x) - 0.000001 <= point.x && point.x <= max(a.x, b.x) + 0.000001
            && min(a.y, b.y) - 0.000001 <= point.y && point.y <= max(a.y, b.y) + 0.000001
    }

    private static func fill(_ path: LaserPath, in mask: inout [Bool], width: Int, height: Int, placement: PrintPlacement) {
        if path.closed, path.points.count > 2 {
            for y in 0..<height {
                for x in 0..<width {
                    let point = Point(
                        x: placement.xMM + (Double(x) + 0.5) * placement.widthMM / Double(width),
                        y: placement.yMM + (Double(y) + 0.5) * placement.heightMM / Double(height)
                    )
                    if contains(point, in: path.points) {
                        mask[y * width + x] = true
                    }
                }
            }
        } else if let bounds = Bounds(paths: [path]) {
            fill(bounds, in: &mask, width: width, height: height, placement: placement)
        }
    }

    private static func fill(_ bounds: Bounds, in mask: inout [Bool], width: Int, height: Int, placement: PrintPlacement) {
        let x0 = max(0, min(width - 1, Int(((bounds.minX - placement.xMM) / placement.widthMM * Double(width)).rounded(.down))))
        let y0 = max(0, min(height - 1, Int(((bounds.minY - placement.yMM) / placement.heightMM * Double(height)).rounded(.down))))
        let x1 = max(x0, min(width - 1, Int(((bounds.maxX - placement.xMM) / placement.widthMM * Double(width)).rounded(.up))))
        let y1 = max(y0, min(height - 1, Int(((bounds.maxY - placement.yMM) / placement.heightMM * Double(height)).rounded(.up))))
        for y in y0...y1 {
            for x in x0...x1 {
                mask[y * width + x] = true
            }
        }
    }

    private static func contains(_ point: Point, in polygon: [Point]) -> Bool {
        var inside = false
        for index in polygon.indices {
            let next = polygon[(index + 1) % polygon.count]
            let current = polygon[index]
            if (current.y > point.y) != (next.y > point.y),
               point.x < (next.x - current.x) * (point.y - current.y) / max(0.000001, next.y - current.y) + current.x {
                inside.toggle()
            }
        }
        return inside
    }

    private static func rectangle(_ bounds: Bounds) -> LaserPath {
        return LaserPath(closed: true, points: [
            Point(x: bounds.minX, y: bounds.minY),
            Point(x: bounds.maxX, y: bounds.minY),
            Point(x: bounds.maxX, y: bounds.maxY),
            Point(x: bounds.minX, y: bounds.maxY)
        ])
    }

    private static func convexHull(_ points: [Point]) -> [Point] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        let unique = sorted.reduce(into: [Point]()) { output, point in
            if output.last != point { output.append(point) }
        }
        guard unique.count > 1 else { return unique }

        func cross(_ a: Point, _ b: Point, _ c: Point) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }

        var lower: [Point] = []
        for point in unique {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [Point] = []
        for point in unique.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    private static let fallbackPaths = [
        LaserPath(closed: true, points: [
            Point(x: 47.5, y: 47.5),
            Point(x: 67.5, y: 47.5),
            Point(x: 67.5, y: 67.5),
            Point(x: 47.5, y: 67.5)
        ])
    ]

    private static func fmt(_ value: Double) -> String {
        String(format: "%.3f", value).replacingOccurrences(of: ".000", with: "")
    }

    private struct FrameObject {
        var paths: [LaserPath]
        var bounds: Bounds?

        init?(paths: [LaserPath]) {
            let paths = paths.filter { $0.points.count > 1 }
            guard !paths.isEmpty else { return nil }
            self.paths = paths
            self.bounds = Bounds(paths: paths)
        }

        func overlaps(_ other: FrameObject) -> Bool {
            FrameGCodeGenerator.overlaps(self, other)
        }
    }

    private struct Bounds {
        var minX: Double
        var minY: Double
        var maxX: Double
        var maxY: Double

        var width: Double { maxX - minX }
        var height: Double { maxY - minY }

        init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
            self.minX = minX
            self.minY = minY
            self.maxX = maxX
            self.maxY = maxY
        }

        init?(paths: [LaserPath]) {
            let points = paths.flatMap(\.points)
            guard let minX = points.map(\.x).min(), let minY = points.map(\.y).min(), let maxX = points.map(\.x).max(), let maxY = points.map(\.y).max() else { return nil }
            self.init(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        }

        static func union(_ bounds: [Bounds]) -> Bounds? {
            guard let first = bounds.first else { return nil }
            return bounds.dropFirst().reduce(first) { result, next in
                Bounds(minX: min(result.minX, next.minX), minY: min(result.minY, next.minY), maxX: max(result.maxX, next.maxX), maxY: max(result.maxY, next.maxY))
            }
        }

        func overlaps(_ other: Bounds) -> Bool {
            minX < other.maxX && maxX > other.minX && minY < other.maxY && maxY > other.minY
        }
    }
}

public enum PrintGCodeGenerator {
    private static let minimumAssetPreviewSeconds = 1.0
    private static let maximumAssetPreviewSeconds = 3.0
    private static let maximumPreviewSeconds = 10.0

    public static func makeGCode(for photos: [ProjectPhoto], rasters: [UUID: RasterOutput], mode: RasterGCodeMode) -> String {
        let photos = photos.filter(\.isEnabled)
        var text = processingHead
        if mode == .scanline {
            let rasterPhotos = photos.filter { $0.mode == .raster && rasters[$0.id] != nil }
            for pass in 0..<(rasterPhotos.map(passCount).max() ?? 0) {
                let passPhotos = rasterPhotos.filter { pass < passCount($0) }
                text += RasterGenerator.makeProcessingGCodeBody(from: passPhotos.compactMap { rasters[$0.id] }, settings: passPhotos.map(\.settings), mode: .scanline)
            }
            for photo in photos where photo.mode == .vector || photo.mode == .text {
                for _ in 0..<passCount(photo) {
                    text += VectorGCodeGenerator.makeProcessingGCodeBody(paths: printablePaths(for: photo), settings: photo.resolvedVectorSettings, preserveOrder: photo.mode == .text)
                }
            }
        } else {
            for photo in photos {
                for _ in 0..<passCount(photo) {
                    if photo.mode == .raster, let raster = rasters[photo.id] {
                        text += RasterGenerator.makeProcessingGCodeBody(from: [raster], settings: [photo.settings], mode: .asset)
                    } else if photo.mode == .vector || photo.mode == .text {
                        text += VectorGCodeGenerator.makeProcessingGCodeBody(paths: printablePaths(for: photo), settings: photo.resolvedVectorSettings, preserveOrder: photo.mode == .text)
                    }
                }
            }
        }
        text += processingTail
        return text
    }

    public static func preview(for photos: [ProjectPhoto], rasters: [UUID: RasterOutput], mode: RasterGCodeMode) -> GCodePreview {
        let photos = photos.filter(\.isEnabled)
        let rasterPhotos = photos.filter { $0.mode == .raster && rasters[$0.id] != nil }
        let rasterOutputs = rasterPhotos.compactMap { rasters[$0.id] }
        var preview = RasterGenerator.preview(from: rasterOutputs, settings: rasterPhotos.map(\.settings), mode: mode)
        let rasterLayer = Dictionary(uniqueKeysWithValues: rasterPhotos.enumerated().map { ($0.element.id, $0.offset) })

        func assignRaster(_ photo: ProjectPhoto, start: Double, duration: Double) {
            guard let index = rasterLayer[photo.id] else { return }
            preview.rasterLayers[index].startSecond = start
            preview.rasterLayers[index].durationSeconds = duration
        }

        func appendVector(_ photo: ProjectPhoto, start: Double, duration: Double) {
            preview.segments += VectorGCodeGenerator.previewSegments(paths: printablePaths(for: photo), settings: photo.resolvedVectorSettings, startSecond: start, durationSeconds: duration, preserveOrder: photo.mode == .text)
        }

        if mode == .scanline {
            var items: [(photo: ProjectPhoto?, raw: Double)] = []
            let rasterRaw = (0..<(rasterPhotos.map(passCount).max() ?? 0)).reduce(0.0) { total, pass in
                let passPhotos = rasterPhotos.filter { pass < passCount($0) }
                let passRasters = passPhotos.compactMap { rasters[$0.id] }
                return total + RasterGenerator.preview(from: passRasters, settings: passPhotos.map(\.settings), mode: mode).estimatedDurationSeconds
            }
            if rasterRaw > 0 {
                items.append((nil, rasterRaw))
            }
            items += photos.filter { ($0.mode == .vector || $0.mode == .text) && !printablePaths(for: $0).isEmpty }.map {
                ($0, vectorDuration($0) * Double(passCount($0)))
            }
            var time = 0.0
            for (item, duration) in zip(items, previewDurations(raw: items.map { $0.raw })) {
                if let photo = item.photo {
                    appendVector(photo, start: time, duration: duration)
                } else {
                    for photo in rasterPhotos {
                        assignRaster(photo, start: time, duration: duration)
                    }
                }
                time += duration
            }
            preview.estimatedDurationSeconds = items.reduce(0) { $0 + $1.raw }
            preview.playbackDurationSeconds = max(0.001, time)
            return preview
        }

        let items = photos.compactMap { photo -> (photo: ProjectPhoto, raw: Double)? in
            if photo.mode == .raster, let raster = rasters[photo.id] {
                return (photo, RasterGenerator.previewDuration(raster: raster, settings: photo.settings) * Double(passCount(photo)))
            }
            if photo.mode == .vector || photo.mode == .text, !printablePaths(for: photo).isEmpty {
                return (photo, vectorDuration(photo) * Double(passCount(photo)))
            }
            return nil
        }
        var time = 0.0
        for (item, duration) in zip(items, previewDurations(raw: items.map { $0.raw })) {
            if item.photo.mode == .raster {
                assignRaster(item.photo, start: time, duration: duration)
            } else {
                appendVector(item.photo, start: time, duration: duration)
            }
            time += duration
        }
        preview.estimatedDurationSeconds = items.reduce(0) { $0 + $1.raw }
        preview.playbackDurationSeconds = max(0.001, time)
        return preview
    }

    public static func printableObjectCount(_ photos: [ProjectPhoto]) -> Int {
        photos.filter { $0.isEnabled && ($0.mode == .raster || (($0.mode == .vector || $0.mode == .text) && !printablePaths(for: $0).isEmpty)) }.count
    }

    private static func printablePaths(for photo: ProjectPhoto) -> [LaserPath] {
        let paths = photo.mode == .text && photo.vectorPaths.isEmpty ? TextVectorGenerator.paths(for: photo.resolvedTextSettings, placement: photo.printPlacement) : photo.vectorPaths
        return photo.mode == .text ? paths.textCutOrder : paths
    }

    private static func passCount(_ photo: ProjectPhoto) -> Int {
        max(1, min(ProjectPhoto.maximumPasses, photo.passes))
    }

    private static func vectorDuration(_ photo: ProjectPhoto) -> Double {
        VectorGCodeGenerator.length(paths: printablePaths(for: photo), settings: photo.resolvedVectorSettings) / max(0.001, photo.resolvedVectorSettings.speedMMPerSecond)
    }

    private static func previewDurations(raw: [Double]) -> [Double] {
        let clamped = raw.map { min(maximumAssetPreviewSeconds, max(minimumAssetPreviewSeconds, $0)) }
        let total = clamped.reduce(0, +)
        let scale = total > maximumPreviewSeconds ? maximumPreviewSeconds / total : 1
        return clamped.map { $0 * scale }
    }

    private static let processingHead = """
    # GLOBAL START

    # F1 HEAD
    G0 F180000
    M4 S0
    G1 F180000
    G0 X0 Y0

    """

    private static let processingTail = """
    # END
    # F1 TAIL
    G90
    G0 S0
    G1 F180000
    M6 P1

    # GLOBAL END

    """
}

private func processingLightCommand(_ laser: Laser) -> String {
    laser == .infrared ? "G22" : "G21"
}

public struct TileStep: Identifiable, Equatable, Sendable {
    public var id: Int { index }
    public var index: Int
    public var row: Int
    public var column: Int
    public var xMM: Double
    public var yMM: Double
    public var widthMM: Double
    public var heightMM: Double

    public var title: String {
        "Step \(index + 1)"
    }
}

public struct TilePlan: Equatable, Sendable {
    public var finalWidthMM: Double
    public var finalHeightMM: Double
    public var tileSizeMM: Double
    public var overlapMM: Double
    public var columns: Int
    public var rows: Int
    public var steps: [TileStep]
}

public enum TilePlanGenerator {
    public static func plan(finalWidthMM: Double, finalHeightMM: Double, tileSizeMM: Double = RasterGenerator.workAreaMM, overlapMM: Double = 0) -> TilePlan {
        let finalWidth = max(1, finalWidthMM)
        let finalHeight = max(1, finalHeightMM)
        let tileSize = min(RasterGenerator.workAreaMM, max(1, tileSizeMM))
        let overlap = min(tileSize - 0.001, max(0, overlapMM))
        let step = max(0.001, tileSize - overlap)
        let columns = max(1, Int(ceil(max(0, finalWidth - overlap) / step)))
        let rows = max(1, Int(ceil(max(0, finalHeight - overlap) / step)))
        let steps = (0..<rows).flatMap { row in
            (0..<columns).map { column in
                let x = Double(column) * step
                let y = Double(row) * step
                return TileStep(
                    index: row * columns + column,
                    row: row,
                    column: column,
                    xMM: x,
                    yMM: y,
                    widthMM: min(tileSize, finalWidth - x),
                    heightMM: min(tileSize, finalHeight - y)
                )
            }
        }
        return TilePlan(finalWidthMM: finalWidth, finalHeightMM: finalHeight, tileSizeMM: tileSize, overlapMM: overlap, columns: columns, rows: rows, steps: steps)
    }

    public static func raster(from data: Data, baseSettings: RasterSettings, step: TileStep, finalWidthMM: Double, finalHeightMM: Double) throws -> RasterOutput {
        try raster(from: RasterGenerator.grayscale(from: data), baseSettings: baseSettings, step: step, finalWidthMM: finalWidthMM, finalHeightMM: finalHeightMM)
    }

    public static func raster(from grayscale: [[UInt8]], baseSettings: RasterSettings, step: TileStep, finalWidthMM: Double, finalHeightMM: Double) -> RasterOutput {
        var settings = baseSettings
        settings.placement = PrintPlacement(xMM: 0, yMM: 0, widthMM: step.widthMM, heightMM: step.heightMM)
        settings.widthMM = step.widthMM
        settings.heightMM = step.heightMM
        return RasterGenerator.makeRaster(from: cropped(grayscale, step: step, finalWidthMM: finalWidthMM, finalHeightMM: finalHeightMM), settings: settings)
    }

    public static func cropped(_ grayscale: [[UInt8]], step: TileStep, finalWidthMM: Double, finalHeightMM: Double) -> [[UInt8]] {
        guard let first = grayscale.first, !first.isEmpty else { return [[255]] }
        let width = first.count
        let height = grayscale.count
        let x0 = clamp(Int((step.xMM / max(0.001, finalWidthMM) * Double(width)).rounded(.down)), 0, width - 1)
        let y0 = clamp(Int((step.yMM / max(0.001, finalHeightMM) * Double(height)).rounded(.down)), 0, height - 1)
        let x1 = clamp(Int(((step.xMM + step.widthMM) / max(0.001, finalWidthMM) * Double(width)).rounded(.up)), x0 + 1, width)
        let y1 = clamp(Int(((step.yMM + step.heightMM) / max(0.001, finalHeightMM) * Double(height)).rounded(.up)), y0 + 1, height)
        return (y0..<y1).map { y in Array(grayscale[y][x0..<x1]) }
    }

    private static func clamp(_ value: Int, _ minValue: Int, _ maxValue: Int) -> Int {
        min(maxValue, max(minValue, value))
    }
}

public enum TextureKind: String, CaseIterable, Codable, Sendable {
    case diagonal
    case crosshatch
    case dots
    case grid
    case waves
}

public enum TexturePathGenerator {
    public static func paths(kind: TextureKind, clippedTo closedPaths: [LaserPath], spacing: Double = 0.08) -> [LaserPath] {
        let closed = closedPaths.filter { $0.closed && $0.points.count > 2 }
        guard !closed.isEmpty else { return [] }
        return pattern(kind: kind, spacing: spacing) { point in
            closed.contains(where: { contains(point, in: $0) })
        }
    }

    public static func paths(kind: TextureKind, mask: RasterBurnMask, spacingMM: Double = 4) -> [LaserPath] {
        guard mask.width > 0, mask.height > 0, !mask.values.isEmpty else { return [] }
        let spacing = min(0.2, max(0.025, spacingMM / max(mask.placement.widthMM, mask.placement.heightMM, 0.001)))
        return pattern(kind: kind, spacing: spacing) { point in
            let x = min(mask.width - 1, max(0, Int((point.x * Double(mask.width)).rounded(.down))))
            let y = min(mask.height - 1, max(0, Int((point.y * Double(mask.height)).rounded(.down))))
            let index = y * mask.width + x
            return mask.values.indices.contains(index) && mask.values[index]
        }
    }

    private static func pattern(kind: TextureKind, spacing: Double, contains: (Point) -> Bool) -> [LaserPath] {
        let spacing = min(0.25, max(0.02, spacing))
        let radius = spacing * 0.28
        var paths: [LaserPath] = []
        var y = spacing / 2
        while y < 1 {
            var x = spacing / 2
            while x < 1 {
                let center = Point(x: x, y: y)
                if contains(center) {
                    paths += cell(kind: kind, center: center, radius: radius).map(clamped)
                }
                x += spacing
            }
            y += spacing
        }
        return paths
    }

    private static func cell(kind: TextureKind, center: Point, radius: Double) -> [LaserPath] {
        switch kind {
        case .diagonal:
            return [line(Point(x: center.x - radius, y: center.y + radius), Point(x: center.x + radius, y: center.y - radius))]
        case .crosshatch:
            return [
                line(Point(x: center.x - radius, y: center.y + radius), Point(x: center.x + radius, y: center.y - radius)),
                line(Point(x: center.x - radius, y: center.y - radius), Point(x: center.x + radius, y: center.y + radius))
            ]
        case .dots:
            return [LaserPath(closed: true, points: [
                Point(x: center.x, y: center.y - radius * 0.45),
                Point(x: center.x + radius * 0.45, y: center.y),
                Point(x: center.x, y: center.y + radius * 0.45),
                Point(x: center.x - radius * 0.45, y: center.y)
            ])]
        case .grid:
            return [
                line(Point(x: center.x - radius, y: center.y), Point(x: center.x + radius, y: center.y)),
                line(Point(x: center.x, y: center.y - radius), Point(x: center.x, y: center.y + radius))
            ]
        case .waves:
            return [LaserPath(closed: false, points: [
                Point(x: center.x - radius, y: center.y),
                Point(x: center.x - radius / 2, y: center.y - radius * 0.45),
                Point(x: center.x, y: center.y),
                Point(x: center.x + radius / 2, y: center.y + radius * 0.45),
                Point(x: center.x + radius, y: center.y)
            ])]
        }
    }

    private static func line(_ a: Point, _ b: Point) -> LaserPath {
        LaserPath(closed: false, points: [a, b])
    }

    private static func clamped(_ path: LaserPath) -> LaserPath {
        LaserPath(closed: path.closed, points: path.points.map {
            Point(x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y)))
        })
    }

    private static func contains(_ point: Point, in path: LaserPath) -> Bool {
        var inside = false
        var previous = path.points.count - 1
        for index in path.points.indices {
            let a = path.points[index]
            let b = path.points[previous]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            previous = index
        }
        return inside
    }
}

public enum LivePreviewGCodeGenerator {
    public static func makeGCode(path points: [Point], speedMMPerSecond: Double = 200, power: Int = 60) -> String {
        let points = points.map(clamped)
        guard let first = points.first else {
            return makeGCode(point: Point(x: RasterGenerator.workAreaMM / 2, y: RasterGenerator.workAreaMM / 2), speedMMPerSecond: speedMMPerSecond, power: power)
        }
        guard points.count > 1 else {
            return makeGCode(point: first, sizeMM: 1, speedMMPerSecond: speedMMPerSecond, power: power)
        }
        let feed = fmt(min(FrameGCodeGenerator.maximumFrameSpeedMMPerSecond, max(1, speedMMPerSecond)) * 60)
        let power = min(100, max(1, power))
        var lines = [
            "# F1 LIVE PREVIEW",
            "G0 F180000",
            "M4 S0",
            "G1 F180000",
            "M114 S1",
            "G0 X\(fmt(first.x)) Y\(fmt(first.y))"
        ]
        for (index, point) in points.dropFirst().enumerated() {
            lines.append("G1 X\(fmt(point.x)) Y\(fmt(point.y))\(index == 0 ? " S\(power) F\(feed)" : "")")
        }
        lines.append("G0 S0")
        lines.append("# END")
        return lines.joined(separator: "\n") + "\n\n"
    }

    public static func makeGCode(from start: Point, to end: Point, speedMMPerSecond: Double = 200, power: Int = 60) -> String {
        let start = clamped(start)
        let end = clamped(end)
        if hypot(start.x - end.x, start.y - end.y) < 0.05 {
            return makeGCode(point: end, sizeMM: 1, speedMMPerSecond: speedMMPerSecond, power: power)
        }
        return makeGCode(path: [start, end], speedMMPerSecond: speedMMPerSecond, power: power)
    }

    public static func makeGCode(point: Point, sizeMM: Double = 2, speedMMPerSecond: Double = 200, power: Int = 60) -> String {
        let point = clamped(point)
        let x = point.x
        let y = point.y
        let radius = min(6, max(0.2, sizeMM / 2))
        let x0 = max(0, x - radius)
        let x1 = min(RasterGenerator.workAreaMM, x + radius)
        let y0 = max(0, y - radius)
        let y1 = min(RasterGenerator.workAreaMM, y + radius)
        let feed = fmt(min(FrameGCodeGenerator.maximumFrameSpeedMMPerSecond, max(1, speedMMPerSecond)) * 60)
        let power = min(100, max(1, power))
        return """
        # F1 LIVE PREVIEW
        G0 F180000
        M4 S0
        G1 F180000
        M114 S1
        G0 X\(fmt(x0)) Y\(fmt(y))
        G1 X\(fmt(x1)) Y\(fmt(y)) S\(power) F\(feed)
        G0 S0
        G0 X\(fmt(x)) Y\(fmt(y0))
        G1 X\(fmt(x)) Y\(fmt(y1)) S\(power) F\(feed)
        G0 S0
        # END

        """
    }

    private static func clamped(_ point: Point) -> Point {
        Point(x: min(RasterGenerator.workAreaMM, max(0, point.x)), y: min(RasterGenerator.workAreaMM, max(0, point.y)))
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.3f", value).replacingOccurrences(of: ".000", with: "")
    }
}

public struct PhotoBitmap: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public func offset(x: Int, y: Int) -> Int {
        (y * width + x) * 4
    }
}

public enum PhotoEditor {
    public static func bitmap(from data: Data) throws -> PhotoBitmap {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { throw RasterError.badImage }
        let maxPixel = max(properties[kCGImagePropertyPixelWidth] as? Int ?? 1, properties[kCGImagePropertyPixelHeight] as? Int ?? 1)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { throw RasterError.badImage }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RasterError.badImage
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return PhotoBitmap(width: image.width, height: image.height, pixels: pixels)
    }

    public static func pngData(from bitmap: PhotoBitmap) -> Data? {
        guard bitmap.pixels.count == bitmap.width * bitmap.height * 4 else { return nil }
        let provider = CGDataProvider(data: Data(bitmap.pixels) as CFData)
        guard
            let provider,
            let image = CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bitmap.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    public static func magicErase(_ bitmap: PhotoBitmap, x: Int, y: Int, fuzziness: Int, minimumBridgePixels: Int = 0) -> PhotoBitmap {
        guard bitmap.width > 0, bitmap.height > 0 else { return bitmap }
        let x = min(bitmap.width - 1, max(0, x))
        let y = min(bitmap.height - 1, max(0, y))
        let base = bitmap.offset(x: x, y: y)
        let color = (Int(bitmap.pixels[base]), Int(bitmap.pixels[base + 1]), Int(bitmap.pixels[base + 2]))
        let threshold = max(0, fuzziness)
        var edited = bitmap
        let bridgeRadius = max(0, minimumBridgePixels) / 2
        guard bridgeRadius > 0 else {
            eraseConnectedMagic(&edited, x: x, y: y, color: color, threshold: threshold)
            return edited
        }
        let matching = magicMask(bitmap, color: color, threshold: threshold)
        let safe = bridgeSafeMask(matching, width: bitmap.width, height: bitmap.height, radius: bridgeRadius)
        let reached = bridgeReachMask(safe, width: bitmap.width, height: bitmap.height, x: x, y: y, radius: bridgeRadius)
        let reachedCounts = maskCounts(reached, width: bitmap.width, height: bitmap.height)
        for py in 0..<bitmap.height {
            for px in 0..<bitmap.width {
                let index = py * bitmap.width + px
                guard matching[index], maskSum(reachedCounts, width: bitmap.width, x0: max(0, px - bridgeRadius), y0: max(0, py - bridgeRadius), x1: min(bitmap.width - 1, px + bridgeRadius), y1: min(bitmap.height - 1, py + bridgeRadius)) > 0 else { continue }
                clearPixel(&edited.pixels, at: bitmap.offset(x: px, y: py))
            }
        }
        return edited
    }

    private static func eraseConnectedMagic(_ bitmap: inout PhotoBitmap, x: Int, y: Int, color: (Int, Int, Int), threshold: Int) {
        var seen = [Bool](repeating: false, count: bitmap.width * bitmap.height)
        var stack = [(x, y)]
        while let point = stack.popLast() {
            guard point.0 >= 0, point.0 < bitmap.width, point.1 >= 0, point.1 < bitmap.height else { continue }
            let index = point.1 * bitmap.width + point.0
            guard !seen[index] else { continue }
            seen[index] = true
            let offset = bitmap.offset(x: point.0, y: point.1)
            guard matches(bitmap.pixels, at: offset, color: color, threshold: threshold) else { continue }
            clearPixel(&bitmap.pixels, at: offset)
            stack.append((point.0 + 1, point.1))
            stack.append((point.0 - 1, point.1))
            stack.append((point.0, point.1 + 1))
            stack.append((point.0, point.1 - 1))
        }
    }

    public static func colorErase(_ bitmap: PhotoBitmap, x: Int, y: Int, fuzziness: Int) -> PhotoBitmap {
        guard bitmap.width > 0, bitmap.height > 0 else { return bitmap }
        let x = min(bitmap.width - 1, max(0, x))
        let y = min(bitmap.height - 1, max(0, y))
        let base = bitmap.offset(x: x, y: y)
        let color = (Int(bitmap.pixels[base]), Int(bitmap.pixels[base + 1]), Int(bitmap.pixels[base + 2]))
        let threshold = max(0, fuzziness)
        var edited = bitmap
        for i in stride(from: 0, to: edited.pixels.count, by: 4) {
            if matches(edited.pixels, at: i, color: color, threshold: threshold) {
                clearPixel(&edited.pixels, at: i)
            }
        }
        return edited
    }

    private static func matches(_ pixels: [UInt8], at offset: Int, color: (Int, Int, Int), threshold: Int) -> Bool {
        max(abs(Int(pixels[offset]) - color.0), abs(Int(pixels[offset + 1]) - color.1), abs(Int(pixels[offset + 2]) - color.2)) <= threshold
    }

    private static func magicMask(_ bitmap: PhotoBitmap, color: (Int, Int, Int), threshold: Int) -> [Bool] {
        stride(from: 0, to: bitmap.pixels.count, by: 4).map { matches(bitmap.pixels, at: $0, color: color, threshold: threshold) }
    }

    private static func bridgeSafeMask(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        let counts = maskCounts(mask, width: width, height: height)
        let area = (radius * 2 + 1) * (radius * 2 + 1)
        var safe = [Bool](repeating: false, count: mask.count)
        guard width > radius * 2, height > radius * 2 else { return safe }
        for y in radius..<(height - radius) {
            for x in radius..<(width - radius) where maskSum(counts, width: width, x0: x - radius, y0: y - radius, x1: x + radius, y1: y + radius) == area {
                safe[y * width + x] = true
            }
        }
        return safe
    }

    private static func bridgeReachMask(_ safe: [Bool], width: Int, height: Int, x: Int, y: Int, radius: Int) -> [Bool] {
        var reached = [Bool](repeating: false, count: safe.count)
        var stack = [(Int, Int)]()
        for py in max(0, y - radius)...min(height - 1, y + radius) {
            for px in max(0, x - radius)...min(width - 1, x + radius) where safe[py * width + px] {
                stack.append((px, py))
            }
        }
        while let point = stack.popLast() {
            guard point.0 >= 0, point.0 < width, point.1 >= 0, point.1 < height else { continue }
            let index = point.1 * width + point.0
            guard safe[index], !reached[index] else { continue }
            reached[index] = true
            stack.append((point.0 + 1, point.1))
            stack.append((point.0 - 1, point.1))
            stack.append((point.0, point.1 + 1))
            stack.append((point.0, point.1 - 1))
        }
        return reached
    }

    private static func maskCounts(_ mask: [Bool], width: Int, height: Int) -> [Int] {
        var counts = [Int](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var row = 0
            for x in 0..<width {
                row += mask[y * width + x] ? 1 : 0
                counts[(y + 1) * (width + 1) + x + 1] = counts[y * (width + 1) + x + 1] + row
            }
        }
        return counts
    }

    private static func maskSum(_ counts: [Int], width: Int, x0: Int, y0: Int, x1: Int, y1: Int) -> Int {
        let stride = width + 1
        return counts[(y1 + 1) * stride + x1 + 1] - counts[y0 * stride + x1 + 1] - counts[(y1 + 1) * stride + x0] + counts[y0 * stride + x0]
    }

    public static func erase(_ bitmap: PhotoBitmap, x: Double, y: Double, radius: Double) -> PhotoBitmap {
        var edited = bitmap
        let radius = max(0, radius)
        let r2 = radius * radius
        let minX = max(0, Int((x - radius).rounded(.down)))
        let maxX = min(bitmap.width - 1, Int((x + radius).rounded(.up)))
        let minY = max(0, Int((y - radius).rounded(.down)))
        let maxY = min(bitmap.height - 1, Int((y + radius).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return edited }
        for py in minY...maxY {
            for px in minX...maxX where pow(Double(px) - x, 2) + pow(Double(py) - y, 2) <= r2 {
                clearPixel(&edited.pixels, at: edited.offset(x: px, y: py))
            }
        }
        return edited
    }

    private static func clearPixel(_ pixels: inout [UInt8], at offset: Int) {
        pixels[offset] = 0
        pixels[offset + 1] = 0
        pixels[offset + 2] = 0
        pixels[offset + 3] = 0
    }

    public static func eraseStroke(_ bitmap: PhotoBitmap, from start: CGPoint, to end: CGPoint, radius: Double) -> PhotoBitmap {
        let distance = hypot(end.x - start.x, end.y - start.y)
        let steps = max(1, Int((distance / max(1, radius / 2)).rounded(.up)))
        var edited = bitmap
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            edited = erase(edited, x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t, radius: radius)
        }
        return edited
    }

    public static func levels(_ bitmap: PhotoBitmap, boundaries: [UInt8]) -> PhotoBitmap {
        let boundaries = boundaries.sorted()
        let levels = max(1, boundaries.count + 1)
        var edited = bitmap
        for i in stride(from: 0, to: edited.pixels.count, by: 4) {
            let gray = (Int(edited.pixels[i]) * 299 + Int(edited.pixels[i + 1]) * 587 + Int(edited.pixels[i + 2]) * 114) / 1000
            let bucket = boundaries.prefix { gray > Int($0) }.count
            let value = UInt8(levels == 1 ? 0 : bucket * 255 / (levels - 1))
            edited.pixels[i] = value
            edited.pixels[i + 1] = value
            edited.pixels[i + 2] = value
        }
        return edited
    }
}
