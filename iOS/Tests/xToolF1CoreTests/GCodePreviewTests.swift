import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import xToolF1Core

final class GCodePreviewTests: XCTestCase {
    func testRasterGCodeIsRealF1MotionCode() {
        let settings = RasterSettings(
            laser: .infrared,
            placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 2, heightMM: 2),
            dpi: 25.4,
            minPowerPercent: 0,
            maxPowerPercent: 120,
            scanDirection: .bidirectional
        )
        let raster = RasterGenerator.makeRaster(from: [[255, 0], [128, 64]], settings: settings)
        let gcode = RasterGenerator.makeGCode(from: [raster], settings: [settings])
        let lines = gcode.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.prefix(3), ["$L", "G90", "G0 F240000"])
        XCTAssertTrue(lines.contains("M114S2"))
        XCTAssertTrue(lines.contains("M4 S0"))
        XCTAssertTrue(lines.contains("G0 X2 Y0"))
        XCTAssertFalse(lines.contains("G1 X2 S1000"))
        XCTAssertTrue(lines.contains("M4 S1000"))
        XCTAssertTrue(lines.contains("G4 P5"))
        XCTAssertTrue(lines.contains("G0 X2 Y2"))
        XCTAssertTrue(lines.contains("M4 S899"))
        XCTAssertEqual(lines.suffix(4), ["M116A127B127", "G90", "M6", "$P"])
        XCTAssertFalse(gcode.contains("S1200"))
    }

    func testRasterGCodeDropsBelowThresholdPixels() {
        let settings = RasterSettings(
            placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 3, heightMM: 1),
            dpi: 25.4,
            minPowerPercent: 0,
            maxPowerPercent: 2,
            dropPowerThresholdPercent: 1
        )
        let raster = RasterGenerator.makeRaster(from: [[255, 128, 0]], settings: settings)
        let gcode = RasterGenerator.makeGCode(from: [raster], settings: [settings])

        XCTAssertFalse(gcode.contains("M4 S0\nG4"))
        XCTAssertTrue(gcode.contains("S10"))
        XCTAssertTrue(gcode.contains("S20"))
    }

    func testRasterGCodeTravelsAcrossDroppedGaps() {
        let settings = RasterSettings(
            placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 3, heightMM: 1),
            dpi: 25.4,
            maxPowerPercent: 10,
            dropPowerThresholdPercent: 1,
            scanDirection: .leftToRight
        )
        let raster = RasterGenerator.makeRaster(from: [[0, 255, 0]], settings: settings)
        let preview = RasterGenerator.gcodePreview(from: RasterGenerator.makeGCode(from: [raster], settings: [settings]), includeSegments: true)

        XCTAssertEqual(preview.points.count, 2)
        guard preview.points.count == 2 else { return }
        XCTAssertEqual(preview.points[0].xMM, 0, accuracy: 0.001)
        XCTAssertEqual(preview.points[1].xMM, 3, accuracy: 0.001)
    }

    func testRasterGCodeCanScanlineAcrossAssets() throws {
        let settings = RasterSettings(
            placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 2, heightMM: 2),
            dpi: 25.4,
            maxPowerPercent: 10,
            scanDirection: .leftToRight
        )
        var rightSettings = settings
        rightSettings.placement.xMM = 3
        let left = RasterGenerator.makeRaster(from: [[0], [0]], settings: settings)
        let right = RasterGenerator.makeRaster(from: [[0], [0]], settings: rightSettings)
        let lines = RasterGenerator.makeGCode(from: [left, right], settings: [settings, rightSettings], mode: .scanline).split(separator: "\n").map(String.init)

        let leftY0 = try XCTUnwrap(lines.firstIndex(of: "G0 X0 Y0"))
        let rightY0 = try XCTUnwrap(lines.firstIndex(of: "G0 X3 Y0"))
        let leftY2 = try XCTUnwrap(lines.firstIndex(of: "G0 X0 Y2"))
        XCTAssertLessThan(leftY0, rightY0)
        XCTAssertLessThan(rightY0, leftY2)
    }

    func testRasterGCodeDefaultsToAssetOrder() throws {
        let settings = RasterSettings(
            placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 2, heightMM: 2),
            dpi: 25.4,
            maxPowerPercent: 10,
            scanDirection: .leftToRight
        )
        var rightSettings = settings
        rightSettings.placement.xMM = 3
        let left = RasterGenerator.makeRaster(from: [[0], [0]], settings: settings)
        let right = RasterGenerator.makeRaster(from: [[0], [0]], settings: rightSettings)
        let lines = RasterGenerator.makeGCode(from: [left, right], settings: [settings, rightSettings]).split(separator: "\n").map(String.init)

        let leftY0 = try XCTUnwrap(lines.firstIndex(of: "G0 X0 Y0"))
        let leftY2 = try XCTUnwrap(lines.firstIndex(of: "G0 X0 Y2"))
        let rightY0 = try XCTUnwrap(lines.firstIndex(of: "G0 X3 Y0"))
        XCTAssertLessThan(leftY0, leftY2)
        XCTAssertLessThan(leftY2, rightY0)
    }

    func testGCodePreviewUsesGeneratedCommandOrder() throws {
        let settings = RasterSettings(
            placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 2, heightMM: 2),
            dpi: 25.4,
            maxPowerPercent: 10,
            scanDirection: .leftToRight
        )
        var rightSettings = settings
        rightSettings.placement.xMM = 3
        let left = RasterGenerator.makeRaster(from: [[0], [0]], settings: settings)
        let right = RasterGenerator.makeRaster(from: [[0], [0]], settings: rightSettings)
        let sequential = RasterGenerator.gcodePreview(from: RasterGenerator.makeGCode(from: [left, right], settings: [settings, rightSettings], mode: .asset), pixels: 10, frameCount: 2, includeSegments: true)
        let simultaneous = RasterGenerator.gcodePreview(from: RasterGenerator.makeGCode(from: [left, right], settings: [settings, rightSettings], mode: .scanline), pixels: 10, frameCount: 2, includeSegments: true)

        XCTAssertLessThan(sequential.points[1].yMM, sequential.points[2].yMM)
        XCTAssertEqual(simultaneous.points[1].yMM, simultaneous.points[2].yMM, accuracy: 0.001)
    }

    func testMixedGCodePreviewFramesAnimateVectorAfterRasterInBothModes() throws {
        let rasterID = UUID()
        let rasterSettings = RasterSettings(
            placement: PrintPlacement(xMM: 5, yMM: 5, widthMM: 1, heightMM: 1),
            dpi: 25.4,
            maxPowerPercent: 100
        )
        let rasterPhoto = ProjectPhoto(id: rasterID, name: "Raster", settings: rasterSettings)
        let raster = RasterGenerator.makeRaster(from: [[0]], settings: rasterSettings)
        let vector = ProjectPhoto(
            name: "Vector",
            mode: .vector,
            settings: RasterSettings(),
            vectorSettings: VectorSettings(placement: PrintPlacement(xMM: 10, yMM: 10, widthMM: 10, heightMM: 10), speedMMPerSecond: 20, powerPercent: 100),
            vectorPaths: [LaserPath(closed: false, points: [Point(x: 0, y: 0), Point(x: 1, y: 0)])]
        )

        for mode in [RasterGCodeMode.asset, .scanline] {
            let gcode = PrintGCodeGenerator.makeGCode(for: [rasterPhoto, vector], rasters: [rasterID: raster], mode: mode)
            let preview = RasterGenerator.gcodePreview(from: gcode, pixels: 116, frameCount: 3)
            XCTAssertEqual(preview.frames.count, 3)
            let rasterOnly = try RasterGenerator.grayscale(from: preview.frames[1])
            let complete = try RasterGenerator.grayscale(from: preview.frames[2])

            XCTAssertLessThan(rasterOnly[5][5], 250)
            XCTAssertGreaterThan(rasterOnly[10][15], 250)
            XCTAssertLessThan(complete[10][15], 250)
            XCTAssertEqual(preview.sweeps.count, 2)
            XCTAssertEqual(preview.sweeps[0].yMM, 5, accuracy: 0.001)
            XCTAssertEqual(preview.sweeps[1].yMM, 10, accuracy: 0.001)
            XCTAssertNotNil(preview.frameSweeps[1])
            XCTAssertNotNil(preview.frameSweeps[2])
        }
    }

    func testGCodePreviewUsesOneImageAndOrderedSweeps() throws {
        let settings = RasterSettings(
            placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 20, heightMM: 20),
            dpi: 254,
            maxPowerPercent: 10
        )
        let raster = RasterGenerator.makeRaster(from: Array(repeating: Array(repeating: UInt8(0), count: 8), count: 8), settings: settings)
        let preview = RasterGenerator.gcodePreview(from: RasterGenerator.makeGCode(from: [raster], settings: [settings]), pixels: 80, frameCount: 8, includeSegments: true)

        XCTAssertFalse(preview.points.isEmpty)
        XCTAssertEqual(preview.sweeps.count, raster.heightPixels)
        XCTAssertNotNil(preview.imageData)
        XCTAssertEqual(preview.frames.count, 8)
        XCTAssertEqual(preview.frameSweeps.count, preview.frames.count)
        XCTAssertGreaterThan(preview.estimatedDurationSeconds, 0)
    }

    func testGCodePreviewFrameSweepsMatchFramePixels() throws {
        let settings = RasterSettings(
            placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 20, heightMM: 20),
            dpi: 254,
            maxPowerPercent: 10,
            scanDirection: .leftToRight
        )
        let raster = RasterGenerator.makeRaster(from: Array(repeating: Array(repeating: UInt8(0), count: 8), count: 8), settings: settings)
        let preview = RasterGenerator.gcodePreview(from: RasterGenerator.makeGCode(from: [raster], settings: [settings]), pixels: 80, frameCount: 8)

        for (data, sweep) in zip(preview.frames, preview.frameSweeps) {
            let rows = try RasterGenerator.grayscale(from: data)
            let visibleRows = rows.indices.filter { y in rows[y].contains { $0 < 250 } }
            guard let lastVisibleRow = visibleRows.last, let sweep else { continue }
            let visibleY = Double(lastVisibleRow) / 79 * RasterGenerator.workAreaMM
            XCTAssertEqual(visibleY, sweep.yMM, accuracy: 2)
        }
    }

    func testGCodePreviewFramesRespectYOffset() throws {
        let settings = RasterSettings(
            placement: PrintPlacement(xMM: 0, yMM: 36, widthMM: 20, heightMM: 20),
            dpi: 254,
            maxPowerPercent: 10,
            scanDirection: .leftToRight
        )
        let raster = RasterGenerator.makeRaster(from: Array(repeating: Array(repeating: UInt8(0), count: 8), count: 8), settings: settings)
        let preview = RasterGenerator.gcodePreview(from: RasterGenerator.makeGCode(from: [raster], settings: [settings]), pixels: 80, frameCount: 2)
        let rows = try RasterGenerator.grayscale(from: preview.frames.last ?? Data())
        let firstVisibleRow = try XCTUnwrap(rows.indices.first { y in rows[y].contains { $0 < 250 } })
        let visibleY = Double(firstVisibleRow) / 79 * RasterGenerator.workAreaMM

        XCTAssertEqual(visibleY, 36, accuracy: 2)
    }

    func testGCodePreviewLowDPIRendersSeparateDots() throws {
        let settings = RasterSettings(
            placement: PrintPlacement(xMM: 20, yMM: 20, widthMM: 30, heightMM: 50),
            dpi: 8,
            maxPowerPercent: 10,
            scanDirection: .leftToRight
        )
        let raster = RasterGenerator.makeRaster(from: Array(repeating: Array(repeating: UInt8(0), count: 8), count: 8), settings: settings)
        let preview = RasterGenerator.gcodePreview(from: RasterGenerator.makeGCode(from: [raster], settings: [settings]), pixels: 200)
        let rows = try RasterGenerator.grayscale(from: try XCTUnwrap(preview.imageData))
        let visibleRows = rows.indices.filter { y in rows[y].contains { $0 < 250 } }
        let rowGaps = zip(visibleRows, visibleRows.dropFirst()).map { $1 - $0 }
        let visibleColumns = rows.flatMap { row in row.indices.filter { row[$0] < 250 } }.sorted()
        let columnGaps = zip(visibleColumns, visibleColumns.dropFirst()).map { $1 - $0 }

        XCTAssertGreaterThan(rowGaps.max() ?? 0, 2)
        XCTAssertGreaterThan(columnGaps.max() ?? 0, 2)
    }

    func testGCodePreviewRetainsPointCoordinatesForVectorDotDisplay() throws {
        let settings = RasterSettings(
            placement: PrintPlacement(xMM: 10, yMM: 20, widthMM: 25.4, heightMM: 25.4),
            dpi: 2,
            maxPowerPercent: 10,
            scanDirection: .leftToRight
        )
        let raster = RasterGenerator.makeRaster(from: [[0, 0], [0, 0]], settings: settings)
        let preview = RasterGenerator.gcodePreview(from: RasterGenerator.makeGCode(from: [raster], settings: [settings]))

        XCTAssertEqual(preview.points.count, 4)
        XCTAssertEqual(preview.points[0].xMM, 10, accuracy: 0.001)
        XCTAssertEqual(preview.points[0].yMM, 20, accuracy: 0.001)
        XCTAssertEqual(preview.points[1].xMM, 35.4, accuracy: 0.001)
        XCTAssertEqual(preview.points[2].xMM, 10, accuracy: 0.001)
        XCTAssertEqual(preview.points[2].yMM, 45.4, accuracy: 0.001)
    }

    func testGCodePreviewDoesNotKeepSegmentsByDefault() throws {
        let settings = RasterSettings(
            placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 20, heightMM: 20),
            dpi: 254,
            maxPowerPercent: 10
        )
        let raster = RasterGenerator.makeRaster(from: Array(repeating: Array(repeating: UInt8(0), count: 8), count: 8), settings: settings)
        let preview = RasterGenerator.gcodePreview(from: RasterGenerator.makeGCode(from: [raster], settings: [settings]), pixels: 80)

        XCTAssertTrue(preview.segments.isEmpty)
        XCTAssertEqual(preview.sweeps.count, raster.heightPixels)
        XCTAssertNotNil(preview.imageData)
    }

    func testGCodePreviewSweepsIgnoreBlankRows() throws {
        let settings = RasterSettings(
            placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 2, heightMM: 2),
            dpi: 25.4,
            maxPowerPercent: 10,
            scanDirection: .leftToRight
        )
        let raster = RasterGenerator.makeRaster(from: [[255], [0]], settings: settings)
        let preview = RasterGenerator.gcodePreview(from: RasterGenerator.makeGCode(from: [raster], settings: [settings]))

        XCTAssertEqual(preview.sweeps.count, 1)
        XCTAssertEqual(try XCTUnwrap(preview.sweeps.first).yMM, 2, accuracy: 0.001)
    }

    func testGCodePreviewEstimatesDwellTime() {
        let settings = RasterSettings(
            placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 1, heightMM: 1),
            dpi: 25.4,
            speedMMPerSecond: 1000,
            maxPowerPercent: 100
        )
        let raster = RasterGenerator.makeRaster(from: [[0]], settings: settings)
        let preview = RasterGenerator.gcodePreview(from: RasterGenerator.makeGCode(from: [raster], settings: [settings]))

        XCTAssertEqual(preview.estimatedDurationSeconds, 0.001, accuracy: 0.0001)
    }

    func testStreamedRasterPreviewMatchesGeneratedGCodePreview() {
        let settings = RasterSettings(
            placement: PrintPlacement(xMM: 2, yMM: 3, widthMM: 2, heightMM: 2),
            dpi: 25.4,
            speedMMPerSecond: 1000,
            maxPowerPercent: 100
        )
        let raster = RasterGenerator.makeRaster(from: [[0, 255], [128, 0]], settings: settings)
        let gcodePreview = RasterGenerator.gcodePreview(from: RasterGenerator.makeGCode(from: [raster], settings: [settings]), pixels: 40, frameCount: 3)
        let streamedPreview = RasterGenerator.preview(from: [raster], settings: [settings], pixels: 40, frameCount: 3)

        XCTAssertTrue(streamedPreview.allPointsRetained)
        XCTAssertEqual(streamedPreview.points, gcodePreview.points)
        XCTAssertEqual(streamedPreview.sweeps, gcodePreview.sweeps)
        XCTAssertEqual(streamedPreview.frames.count, 0)
        XCTAssertEqual(streamedPreview.rasterLayers.count, 1)
        XCTAssertEqual(streamedPreview.rasterLayers[0].powers.count, raster.widthPixels * raster.heightPixels)
        XCTAssertEqual(streamedPreview.rasterLayers[0].displayPowers, streamedPreview.rasterLayers[0].powers)
        XCTAssertNotNil(RasterGenerator.pngPreview(from: streamedPreview, pixels: 40))
        XCTAssertEqual(streamedPreview.estimatedDurationSeconds, gcodePreview.estimatedDurationSeconds, accuracy: 0.0001)
    }

    func testStreamedPreviewKeepsCompactRasterAtHighDPI() {
        let settings = RasterSettings(
            placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 30, heightMM: 30),
            dpi: 1000,
            maxPowerPercent: 100
        )
        let raster = RasterGenerator.makeRaster(from: [[0]], settings: settings)
        let preview = RasterGenerator.preview(from: [raster], settings: [settings])

        XCTAssertFalse(preview.allPointsRetained)
        XCTAssertEqual(raster.widthPixels, 1181)
        XCTAssertEqual(raster.heightPixels, 1181)
        XCTAssertLessThanOrEqual(preview.points.count, 200_000)
        XCTAssertEqual(preview.frames.count, 0)
        XCTAssertEqual(preview.rasterLayers.count, 1)
        XCTAssertEqual(preview.rasterLayers[0].powers.count, raster.widthPixels * raster.heightPixels)
        XCTAssertLessThan(preview.rasterLayers[0].displayPowers.count, preview.rasterLayers[0].powers.count)
        XCTAssertLessThanOrEqual(max(preview.rasterLayers[0].displayWidthPixels, preview.rasterLayers[0].displayHeightPixels), 512)
        XCTAssertEqual(preview.rasterLayers[0].burnCount, raster.widthPixels * raster.heightPixels)
        XCTAssertGreaterThan(preview.rasterLayers[0].displayBurnCount, 0)
        XCTAssertGreaterThan(preview.estimatedDurationSeconds, 0)
    }

    func testPreviewPinchEndDoesNotApplyReleaseLocation() {
        var pinch = PreviewPinchStateMachine(zoom: 2, panX: 12, panY: -8)
        _ = pinch.update(phase: .began, touches: 2, scale: 1, locationX: 140, locationY: 160, centerX: 100, centerY: 100)
        let changed = pinch.update(phase: .changed, touches: 2, scale: 1.4, locationX: 145, locationY: 155, centerX: 100, centerY: 100)
        let ended = pinch.update(phase: .ended, touches: 0, scale: 1.4, locationX: 260, locationY: 20, centerX: 100, centerY: 100)

        XCTAssertEqual(ended, changed)
    }

    func testPreviewPinchKeepsCentroidContentStable() {
        var pinch = PreviewPinchStateMachine(zoom: 2, panX: 12, panY: -8)
        _ = pinch.update(phase: .began, touches: 2, scale: 1, locationX: 140, locationY: 160, centerX: 100, centerY: 100)
        let next = pinch.update(phase: .changed, touches: 2, scale: 1.4, locationX: 145, locationY: 155, centerX: 100, centerY: 100)
        let contentX = 100.0 + (140.0 - 100.0 - 12.0) / 2.0
        let contentY = 100.0 + (160.0 - 100.0 + 8.0) / 2.0
        let nextContentX = 100 + (145 - 100 - next.panX) / next.zoom
        let nextContentY = 100 + (155 - 100 - next.panY) / next.zoom

        XCTAssertEqual(nextContentX, contentX, accuracy: 0.0001)
        XCTAssertEqual(nextContentY, contentY, accuracy: 0.0001)
    }

    func testWorkspacePreviewCompositesMultipleRasters() throws {
        let left = RasterGenerator.makeRaster(
            from: [[0]],
            settings: RasterSettings(placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 57.5, heightMM: 115), dpi: 1, maxPowerPercent: 100)
        )
        let right = RasterGenerator.makeRaster(
            from: [[128]],
            settings: RasterSettings(placement: PrintPlacement(xMM: 57.5, yMM: 0, widthMM: 57.5, heightMM: 115), dpi: 1, maxPowerPercent: 100)
        )
        let preview = try XCTUnwrap(RasterGenerator.workspacePreview(from: [left, right], pixels: 2))

        XCTAssertEqual(try RasterGenerator.grayscale(from: preview), [[0, 128], [0, 128]])
    }

    func testWorkspacePreviewLeavesDroppedPixelsWhite() throws {
        let raster = RasterGenerator.makeRaster(
            from: [[255, 255, 0, 0, 0]],
            settings: RasterSettings(placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 115, heightMM: 115), dpi: 1, maxPowerPercent: 100, dropPowerThresholdPercent: 1)
        )
        let preview = try XCTUnwrap(RasterGenerator.workspacePreview(from: [raster], pixels: 2))

        XCTAssertEqual(try RasterGenerator.grayscale(from: preview), [[255, 0], [255, 0]])
    }

    func testWorkspacePreviewShowsLowPowerIncludedPixels() throws {
        let raster = RasterGenerator.makeRaster(
            from: [[0]],
            settings: RasterSettings(placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 115, heightMM: 115), dpi: 1, maxPowerPercent: 1, dropPowerThresholdPercent: 1)
        )
        let preview = try XCTUnwrap(RasterGenerator.workspacePreview(from: [raster], pixels: 1))

        XCTAssertLessThan(try XCTUnwrap(RasterGenerator.grayscale(from: preview).first?.first), 255)
    }

    func testVectorTestSquareStaysLowPower() {
        let project = LaserProject(
            name: "20mm test square",
            preview: true,
            operations: [
                LaserOperation(
                    laser: .blue,
                    powerPercent: 1,
                    speedMMPerSecond: 200,
                    paths: [
                        LaserPath(closed: true, points: [
                            Point(x: 47.5, y: 47.5),
                            Point(x: 67.5, y: 47.5),
                            Point(x: 67.5, y: 67.5),
                            Point(x: 47.5, y: 67.5)
                        ])
                    ]
                )
            ]
        )
        let gcode = GCodeGenerator.makeGCode(for: project)

        XCTAssertTrue(gcode.contains("M3 S10"))
        XCTAssertFalse(gcode.contains("M3 S1000"))
    }

}
