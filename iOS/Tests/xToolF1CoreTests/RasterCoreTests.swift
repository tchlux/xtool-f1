import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import xToolF1Core

final class RasterLogicTests: XCTestCase {
    func testGrayscaleConversionIsStable() throws {
        let gray = try RasterGenerator.grayscale(from: png(red: 255, green: 0, blue: 0))
        XCTAssertEqual(gray, [[76]])
    }

    func testTransparentPixelsRasterAsWhite() throws {
        let gray = try RasterGenerator.grayscale(from: png(width: 1, height: 1, rgba: [0, 0, 0, 0]))
        let raster = RasterGenerator.makeRaster(from: gray, settings: RasterSettings(placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 1, heightMM: 1), dpi: 25.4))

        XCTAssertEqual(gray, [[255]])
        XCTAssertEqual(raster.lines[4], "Y0 0")
    }

    func testPhotoEditorPNGDataCanBeDecodedForPreview() throws {
        let bitmap = try PhotoEditor.bitmap(from: png(width: 2, height: 1, rgba: [
            0, 0, 0, 255,
            255, 255, 255, 255
        ]))
        let data = try XCTUnwrap(PhotoEditor.pngData(from: bitmap))
        let decoded = try PhotoEditor.bitmap(from: data)

        XCTAssertEqual(decoded.width, 2)
        XCTAssertEqual(decoded.height, 1)
    }

    func testMagicEraserUsesConnectedFuzzinessThreshold() {
        let bitmap = PhotoBitmap(width: 3, height: 2, pixels: [
            100, 100, 100, 255,
            110, 100, 100, 255,
            140, 100, 100, 255,
            140, 100, 100, 255,
            140, 100, 100, 255,
            100, 100, 100, 255
        ])
        let edited = PhotoEditor.magicErase(bitmap, x: 0, y: 0, fuzziness: 10)

        XCTAssertEqual(Array(edited.pixels[0...3]), [0, 0, 0, 0])
        XCTAssertEqual(edited.pixels[3], 0)
        XCTAssertEqual(edited.pixels[7], 0)
        XCTAssertEqual(edited.pixels[11], 255)
        XCTAssertEqual(edited.pixels[23], 255)
    }

    func testMagicEraserMinimumBridgeBlocksNarrowGap() {
        let bitmap = bridgeBitmap(gap: 3...5)
        let leaked = PhotoEditor.magicErase(bitmap, x: 1, y: 4, fuzziness: 0)
        let blocked = PhotoEditor.magicErase(bitmap, x: 1, y: 4, fuzziness: 0, minimumBridgePixels: 5)

        XCTAssertEqual(alpha(leaked, x: 10, y: 4), 0)
        XCTAssertEqual(alpha(blocked, x: 2, y: 4), 0)
        XCTAssertEqual(alpha(blocked, x: 10, y: 4), 255)
    }

    func testMagicEraserMinimumBridgeAllowsWideGap() {
        let bitmap = bridgeBitmap(gap: 2...6)
        let edited = PhotoEditor.magicErase(bitmap, x: 1, y: 4, fuzziness: 0, minimumBridgePixels: 5)

        XCTAssertEqual(alpha(edited, x: 10, y: 4), 0)
    }

    func testColorEraserUsesGlobalFuzzinessThreshold() {
        let bitmap = PhotoBitmap(width: 3, height: 2, pixels: [
            100, 100, 100, 255,
            110, 100, 100, 255,
            140, 100, 100, 255,
            140, 100, 100, 255,
            140, 100, 100, 255,
            100, 100, 100, 255
        ])
        let edited = PhotoEditor.colorErase(bitmap, x: 0, y: 0, fuzziness: 10)

        XCTAssertEqual(Array(edited.pixels[0...3]), [0, 0, 0, 0])
        XCTAssertEqual(edited.pixels[3], 0)
        XCTAssertEqual(edited.pixels[7], 0)
        XCTAssertEqual(edited.pixels[11], 255)
        XCTAssertEqual(edited.pixels[23], 0)
    }

    func testManualEraserClearsBrushRadius() {
        let bitmap = PhotoBitmap(width: 3, height: 1, pixels: Array(repeating: 255, count: 12))
        let edited = PhotoEditor.erase(bitmap, x: 1, y: 0, radius: 0.5)

        XCTAssertEqual(edited.pixels[3], 255)
        XCTAssertEqual(Array(edited.pixels[4...7]), [0, 0, 0, 0])
        XCTAssertEqual(edited.pixels[7], 0)
        XCTAssertEqual(edited.pixels[11], 255)
    }

    func testManualEraserInterpolatesStrokeBetweenSamples() {
        let bitmap = PhotoBitmap(width: 7, height: 1, pixels: Array(repeating: 255, count: 28))
        let edited = PhotoEditor.eraseStroke(bitmap, from: CGPoint(x: 1, y: 0), to: CGPoint(x: 5, y: 0), radius: 0.5)

        XCTAssertEqual(edited.pixels[3], 255)
        for x in 1...5 {
            XCTAssertEqual(edited.pixels[x * 4 + 3], 0)
        }
        XCTAssertEqual(edited.pixels[27], 255)
    }

    func testLevelsQuantizationUsesBoundaries() {
        let bitmap = PhotoBitmap(width: 3, height: 1, pixels: [
            10, 10, 10, 255,
            120, 120, 120, 255,
            240, 240, 240, 255
        ])
        let edited = PhotoEditor.levels(bitmap, boundaries: [100, 200])

        XCTAssertEqual(Array(edited.pixels[0...2]), [0, 0, 0])
        XCTAssertEqual(Array(edited.pixels[4...6]), [127, 127, 127])
        XCTAssertEqual(Array(edited.pixels[8...10]), [255, 255, 255])
    }

    func testGrayscaleKeepsImageOrientation() throws {
        let gray = try RasterGenerator.grayscale(from: png(width: 2, height: 2, rgba: [
            255, 255, 255, 255, 0, 0, 0, 255,
            64, 64, 64, 255, 128, 128, 128, 255
        ]))
        XCTAssertEqual(gray, [[255, 0], [64, 128]])
    }

    func testRasterFittingRespectsWorkArea() {
        let fit = RasterGenerator.fit(width: 230, height: 57.5)
        XCTAssertEqual(fit.width, 115)
        XCTAssertEqual(fit.height, 28.75)
    }

    func testPlacementClampsToWorkArea() {
        let placement = RasterGenerator.clamp(PrintPlacement(xMM: 100, yMM: -5, widthMM: 40, heightMM: 200))
        XCTAssertEqual(placement.xMM, 75)
        XCTAssertEqual(placement.yMM, 0)
        XCTAssertEqual(placement.widthMM, 40)
        XCTAssertEqual(placement.heightMM, 115)
    }

    func testPlacementSizeConstraintPreservesPosition() {
        let placement = RasterGenerator.sizeConstrained(PrintPlacement(xMM: -10, yMM: 120, widthMM: 200, heightMM: 0.5))

        XCTAssertEqual(placement.xMM, -10)
        XCTAssertEqual(placement.yMM, 120)
        XCTAssertEqual(placement.widthMM, 115)
        XCTAssertEqual(placement.heightMM, 1)
    }

    func testMinimumSizeConstraintAllowsOversizedPlacement() {
        let placement = RasterGenerator.minimumSizeConstrained(PrintPlacement(xMM: -10, yMM: 120, widthMM: 200, heightMM: 0.5))

        XCTAssertEqual(placement.xMM, -10)
        XCTAssertEqual(placement.yMM, 120)
        XCTAssertEqual(placement.widthMM, 200)
        XCTAssertEqual(placement.heightMM, 1)
    }

    func testOffBedRasterClipsInsteadOfShifting() {
        let output = RasterGenerator.makeRaster(
            from: [[255, 0]],
            settings: RasterSettings(
                placement: PrintPlacement(xMM: -1, yMM: 0, widthMM: 2, heightMM: 1),
                dpi: 25.4,
                minPowerPercent: 0,
                maxPowerPercent: 10
            )
        )

        XCTAssertEqual(output.xMM, 0)
        XCTAssertEqual(output.yMM, 0)
        XCTAssertEqual(output.widthMM, 1)
        XCTAssertEqual(output.widthPixels, 1)
        XCTAssertEqual(output.lines[4], "Y0 100")
    }

    func testOffBedGCodeStaysInsideWorkArea() {
        let settings = RasterSettings(
            placement: PrintPlacement(xMM: -1, yMM: 0, widthMM: 2, heightMM: 1),
            dpi: 25.4,
            minPowerPercent: 0,
            maxPowerPercent: 10
        )
        let raster = RasterGenerator.makeRaster(from: [[255, 0]], settings: settings)
        let gcode = RasterGenerator.makeGCode(from: [raster], settings: [settings])

        XCTAssertFalse(gcode.contains("X-"))
        XCTAssertTrue(gcode.contains("G0 X0 Y0"))
    }

    func testFullyOffBedRasterIsSkipped() {
        let settings = RasterSettings(
            placement: PrintPlacement(xMM: -5, yMM: 0, widthMM: 2, heightMM: 1),
            dpi: 25.4
        )
        let raster = RasterGenerator.makeRaster(from: [[0, 0]], settings: settings)
        let gcode = RasterGenerator.makeGCode(from: [raster], settings: [settings])

        XCTAssertEqual(raster.widthPixels, 0)
        XCTAssertFalse(gcode.contains("M114S1"))
    }

    func testPowerMappingUsesMinAndMaxPower() {
        let settings = RasterSettings(minPowerPercent: 10, maxPowerPercent: 20)
        XCTAssertEqual(RasterGenerator.power(for: 255, settings: settings), 100)
        XCTAssertEqual(RasterGenerator.power(for: 0, settings: settings), 200)
    }

    func testRasterSettingsDefaultMaxPowerIsFullPower() throws {
        XCTAssertEqual(RasterSettings().maxPowerPercent, 100)
        XCTAssertEqual(try JSONDecoder().decode(RasterSettings.self, from: Data("{}".utf8)).maxPowerPercent, 100)
    }

    func testRasterSettingsDefaultDropThresholdIsOnePercent() throws {
        let settings = try JSONDecoder().decode(RasterSettings.self, from: Data("{}".utf8))

        XCTAssertEqual(settings.dropPowerThresholdPercent, 1)
        XCTAssertEqual(settings.dropPowerThreshold, 10)
    }

    func testScanlineOutputIsDeterministic() {
        let pixels: [[UInt8]] = [
            [255, 0],
            [128, 64]
        ]
        let output = RasterGenerator.makeRaster(
            from: pixels,
            settings: RasterSettings(
                placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 2, heightMM: 2),
                dpi: 25.4,
                minPowerPercent: 0,
                maxPowerPercent: 10,
                scanDirection: .leftToRight
            )
        )
        XCTAssertEqual(output.widthPixels, 2)
        XCTAssertEqual(output.heightPixels, 2)
        XCTAssertEqual(output.lines[4], "Y0 0,100")
        XCTAssertEqual(output.lines[5], "Y2 50,75")
    }

    func testPreviewRestoresBidirectionalScanlineOrder() throws {
        let output = RasterGenerator.makeRaster(
            from: [[255, 0], [128, 64]],
            settings: RasterSettings(
                placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 2, heightMM: 2),
                dpi: 25.4,
                minPowerPercent: 0,
                maxPowerPercent: 10,
                scanDirection: .bidirectional
            )
        )
        let preview = try XCTUnwrap(RasterGenerator.pngPreview(from: output))
        XCTAssertEqual(try RasterGenerator.grayscale(from: preview), [[255, 0], [128, 64]])
    }

    func testTilePlanNumbersPartialStepsRowMajor() {
        let plan = TilePlanGenerator.plan(finalWidthMM: 230, finalHeightMM: 140)

        XCTAssertEqual(plan.columns, 2)
        XCTAssertEqual(plan.rows, 2)
        XCTAssertEqual(plan.steps.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(plan.steps[1].xMM, 115)
        XCTAssertEqual(plan.steps[1].widthMM, 115)
        XCTAssertEqual(plan.steps[2].yMM, 115)
        XCTAssertEqual(plan.steps[2].heightMM, 25)
    }

    func testTileRasterCropsSourceRegionOntoBed() {
        let step = TileStep(index: 1, row: 0, column: 1, xMM: 1, yMM: 0, widthMM: 1, heightMM: 1)
        let raster = TilePlanGenerator.raster(
            from: [[255, 0]],
            baseSettings: RasterSettings(placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 2, heightMM: 1), dpi: 25.4, maxPowerPercent: 10),
            step: step,
            finalWidthMM: 2,
            finalHeightMM: 1
        )

        XCTAssertEqual(raster.xMM, 0)
        XCTAssertEqual(raster.widthMM, 1)
        XCTAssertEqual(raster.widthPixels, 1)
        XCTAssertEqual(raster.lines[4], "Y0 100")
    }

    func testTilePreviewKeepsTileRasterLayerDPI() {
        let step = TileStep(index: 0, row: 0, column: 0, xMM: 0, yMM: 0, widthMM: 25.4, heightMM: 2.54)
        let settings = RasterSettings(placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 50.8, heightMM: 2.54), dpi: 500, maxPowerPercent: 10)
        let photo = ProjectPhoto(id: UUID(), name: "Tile", settings: settings)
        let raster = TilePlanGenerator.raster(from: [[0, 0]], baseSettings: settings, step: step, finalWidthMM: 50.8, finalHeightMM: 2.54)
        let preview = PrintGCodeGenerator.preview(for: [photo], rasters: [photo.id: raster], mode: .asset)

        XCTAssertEqual(preview.rasterLayers.first?.widthPixels, 500)
    }

    func testTexturePathsStayInsideClosedVector() throws {
        let paths = TexturePathGenerator.paths(kind: .crosshatch, clippedTo: [
            LaserPath(closed: true, points: [
                Point(x: 0, y: 0),
                Point(x: 1, y: 0),
                Point(x: 1, y: 1),
                Point(x: 0, y: 1)
            ])
        ], spacing: 0.25)
        let bounds = try bounds(paths)

        XCTAssertFalse(paths.isEmpty)
        XCTAssertGreaterThanOrEqual(bounds.minX, 0)
        XCTAssertGreaterThanOrEqual(bounds.minY, 0)
        XCTAssertLessThanOrEqual(bounds.maxX, 1)
        XCTAssertLessThanOrEqual(bounds.maxY, 1)
    }

    func testLivePreviewGCodeClampsToWorkAreaAndUsesFramePower() {
        let gcode = LivePreviewGCodeGenerator.makeGCode(point: Point(x: -5, y: 120), sizeMM: 4)

        XCTAssertTrue(gcode.contains("# F1 LIVE PREVIEW"))
        XCTAssertTrue(gcode.contains("M114 S1"))
        XCTAssertTrue(gcode.contains("S60"))
        XCTAssertFalse(gcode.contains("X-"))
        XCTAssertFalse(gcode.contains("Y120"))
    }

    func testLivePreviewGCodeDrawsDragSegment() {
        let gcode = LivePreviewGCodeGenerator.makeGCode(from: Point(x: 1, y: 2), to: Point(x: 3, y: 4))

        XCTAssertTrue(gcode.contains("G0 X1 Y2"))
        XCTAssertTrue(gcode.contains("G1 X3 Y4 S60"))
    }

    func testLivePreviewGCodeDrawsRecentPath() {
        let gcode = LivePreviewGCodeGenerator.makeGCode(path: [
            Point(x: 1, y: 2),
            Point(x: 3, y: 4),
            Point(x: 5, y: 6)
        ])

        XCTAssertTrue(gcode.contains("G0 X1 Y2"))
        XCTAssertTrue(gcode.contains("G1 X3 Y4 S60"))
        XCTAssertTrue(gcode.contains("G1 X5 Y6"))
    }

    private func bridgeBitmap(gap: ClosedRange<Int>) -> PhotoBitmap {
        let width = 13
        let height = 9
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height where !gap.contains(y) {
            let offset = (y * width + 6) * 4
            pixels[offset] = 0
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
        }
        return PhotoBitmap(width: width, height: height, pixels: pixels)
    }

    private func alpha(_ bitmap: PhotoBitmap, x: Int, y: Int) -> UInt8 {
        bitmap.pixels[bitmap.offset(x: x, y: y) + 3]
    }

}
