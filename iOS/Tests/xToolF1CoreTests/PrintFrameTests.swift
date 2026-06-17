import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import xToolF1Core

final class PrintFrameTests: XCTestCase {
    func testMixedGCodeKeepsAssetOrderWithVectorLines() {
        let vectorID = UUID()
        let rasterID = UUID()
        let vector = ProjectPhoto(
            id: vectorID,
            name: "Vector",
            mode: .vector,
            settings: RasterSettings(),
            vectorSettings: VectorSettings(placement: PrintPlacement(xMM: 10, yMM: 10, widthMM: 10, heightMM: 10), speedMMPerSecond: 20, powerPercent: 10),
            vectorPaths: [LaserPath(closed: false, points: [Point(x: 0, y: 0), Point(x: 1, y: 0)])]
        )
        let rasterSettings = RasterSettings(placement: PrintPlacement(xMM: 30, yMM: 30, widthMM: 1, heightMM: 1), dpi: 25.4, maxPowerPercent: 50, dropPowerThresholdPercent: 1)
        let rasterPhoto = ProjectPhoto(id: rasterID, name: "Raster", settings: rasterSettings)
        let raster = RasterGenerator.makeRaster(from: [[0]], settings: rasterSettings)
        let gcode = PrintGCodeGenerator.makeGCode(for: [vector, rasterPhoto], rasters: [rasterID: raster], mode: .asset)
        let preview = RasterGenerator.gcodePreview(from: gcode, includeSegments: true)

        XCTAssertLessThan(try XCTUnwrap(gcode.range(of: "G1 X20 Y10 S100")?.lowerBound), try XCTUnwrap(gcode.range(of: "G1 X31 Y30 S500")?.lowerBound))
        XCTAssertTrue(gcode.contains("# F1 HEAD"))
        XCTAssertFalse(gcode.contains("$L"))
        XCTAssertFalse(gcode.contains("G4 P"))
        XCTAssertTrue(gcode.contains("G0 X10 Y10"))
        XCTAssertTrue(gcode.contains("G1 X20 Y10 S100 F1200"))
        XCTAssertTrue(preview.segments.contains { $0.x0MM == 10 && $0.y0MM == 10 && $0.x1MM == 20 && $0.y1MM == 10 && $0.power == 100 })
    }

    func testPrintGCodeUsesF1ProcessingEnvelopeAndPoweredRasterMoves() {
        let id = UUID()
        let settings = RasterSettings(
            laser: .infrared,
            placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 2, heightMM: 1),
            dpi: 25.4,
            maxPowerPercent: 10,
            scanDirection: .leftToRight
        )
        let photo = ProjectPhoto(id: id, name: "Raster", settings: settings)
        let raster = RasterGenerator.makeRaster(from: [[0, 255]], settings: settings)
        let gcode = PrintGCodeGenerator.makeGCode(for: [photo], rasters: [id: raster], mode: .asset)

        XCTAssertTrue(gcode.hasPrefix("# GLOBAL START"))
        XCTAssertTrue(gcode.contains("# F1 HEAD"))
        XCTAssertTrue(gcode.contains("G22"))
        XCTAssertTrue(gcode.contains("G1 X1 Y0 S100 F12000"))
        XCTAssertTrue(gcode.contains("# F1 TAIL"))
        XCTAssertFalse(gcode.contains("$P"))
        XCTAssertFalse(gcode.contains("M4 S100"))
    }

    func testVectorCutsRunContainedPathsFirst() throws {
        let outer = LaserPath(closed: true, points: [Point(x: 0, y: 0), Point(x: 1, y: 0), Point(x: 1, y: 1), Point(x: 0, y: 1)])
        let inner = LaserPath(closed: true, points: [Point(x: 0.4, y: 0.4), Point(x: 0.6, y: 0.4), Point(x: 0.6, y: 0.6), Point(x: 0.4, y: 0.6)])
        let photo = ProjectPhoto(
            name: "Nested",
            mode: .vector,
            settings: RasterSettings(),
            vectorSettings: VectorSettings(placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 10, heightMM: 10), speedMMPerSecond: 20, powerPercent: 10),
            vectorPaths: [outer, inner]
        )
        let appGCode = PrintGCodeGenerator.makeGCode(for: [photo], rasters: [:], mode: .asset)
        let preview = PrintGCodeGenerator.preview(for: [photo], rasters: [:], mode: .asset)
        let projectGCode = GCodeGenerator.makeGCode(for: LaserProject(name: "Nested", preview: false, operations: [
            LaserOperation(laser: .blue, powerPercent: 10, speedMMPerSecond: 20, paths: [outer, inner])
        ]))

        XCTAssertLessThan(try XCTUnwrap(appGCode.range(of: "G0 X4 Y4")?.lowerBound), try XCTUnwrap(appGCode.range(of: "G0 X0 Y0\nG1 X10 Y0")?.lowerBound))
        XCTAssertLessThan(try XCTUnwrap(projectGCode.range(of: "G0 X0.400 Y0.400")?.lowerBound), try XCTUnwrap(projectGCode.range(of: "G0 X0 Y0")?.lowerBound))
        XCTAssertEqual(try XCTUnwrap(preview.segments.first).x0MM, 4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(preview.segments.first).y0MM, 4, accuracy: 0.001)
    }

    func testVectorCutsUseCenterOutOrderForUncontainedPaths() throws {
        func rect(_ x: Double, _ y: Double, _ size: Double) -> LaserPath {
            LaserPath(closed: true, points: [Point(x: x, y: y), Point(x: x + size, y: y), Point(x: x + size, y: y + size), Point(x: x, y: y + size)])
        }

        let center = rect(0.4, 0.4, 0.2)
        let farTiny = rect(0.8, 0.8, 0.05)
        let photo = ProjectPhoto(
            name: "Center Out",
            mode: .vector,
            settings: RasterSettings(),
            vectorSettings: VectorSettings(placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 115, heightMM: 115), speedMMPerSecond: 20, powerPercent: 10),
            vectorPaths: [farTiny, center]
        )
        let appGCode = PrintGCodeGenerator.makeGCode(for: [photo], rasters: [:], mode: .asset)
        let preview = PrintGCodeGenerator.preview(for: [photo], rasters: [:], mode: .asset)
        let projectGCode = GCodeGenerator.makeGCode(for: LaserProject(name: "Center Out", preview: false, operations: [
            LaserOperation(laser: .blue, powerPercent: 10, speedMMPerSecond: 20, paths: [rect(92, 92, 5), rect(46, 46, 23)])
        ]))

        XCTAssertLessThan(try XCTUnwrap(appGCode.range(of: "G0 X46 Y46")?.lowerBound), try XCTUnwrap(appGCode.range(of: "G0 X92 Y92")?.lowerBound))
        XCTAssertLessThan(try XCTUnwrap(projectGCode.range(of: "G0 X46 Y46")?.lowerBound), try XCTUnwrap(projectGCode.range(of: "G0 X92 Y92")?.lowerBound))
        XCTAssertEqual(try XCTUnwrap(preview.segments.first).x0MM, 46, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(preview.segments.first).y0MM, 46, accuracy: 0.001)
    }

    func testVectorCutsKeepContainedPathsBeforeCenterDistance() throws {
        let outer = LaserPath(closed: true, points: [Point(x: 0.3, y: 0.3), Point(x: 0.7, y: 0.3), Point(x: 0.7, y: 0.7), Point(x: 0.3, y: 0.7)])
        let inner = LaserPath(closed: true, points: [Point(x: 0.6, y: 0.6), Point(x: 0.65, y: 0.6), Point(x: 0.65, y: 0.65), Point(x: 0.6, y: 0.65)])
        let photo = ProjectPhoto(
            name: "Contained",
            mode: .vector,
            settings: RasterSettings(),
            vectorSettings: VectorSettings(placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 115, heightMM: 115), speedMMPerSecond: 20, powerPercent: 10),
            vectorPaths: [outer, inner]
        )
        let gcode = PrintGCodeGenerator.makeGCode(for: [photo], rasters: [:], mode: .asset)

        XCTAssertLessThan(try XCTUnwrap(gcode.range(of: "G0 X69 Y69")?.lowerBound), try XCTUnwrap(gcode.range(of: "G0 X34.500 Y34.500")?.lowerBound))
    }

    func testTextCutsUseReadingOrderWithContainedPathsFirst() throws {
        func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> LaserPath {
            LaserPath(closed: true, points: [
                Point(x: x, y: y),
                Point(x: x + width, y: y),
                Point(x: x + width, y: y + height),
                Point(x: x, y: y + height)
            ])
        }

        let left = rect(0.10, 0.12, 0.10, 0.10)
        let outer = rect(0.50, 0.10, 0.20, 0.20)
        let inner = rect(0.55, 0.15, 0.05, 0.05)
        let lower = rect(0.10, 0.55, 0.10, 0.10)
        let photo = ProjectPhoto(
            name: "Text",
            mode: .text,
            settings: RasterSettings(),
            vectorSettings: VectorSettings(placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 10, heightMM: 10), speedMMPerSecond: 20, powerPercent: 10),
            vectorPaths: [lower, outer, inner, left],
            textSettings: TextSettings(text: "Text")
        )
        let gcode = PrintGCodeGenerator.makeGCode(for: [photo], rasters: [:], mode: .asset)
        let preview = PrintGCodeGenerator.preview(for: [photo], rasters: [:], mode: .asset)

        func gcodeIndex(_ text: String) throws -> String.Index {
            try XCTUnwrap(gcode.range(of: text)?.lowerBound)
        }
        func previewIndex(x: Double, y: Double) throws -> Int {
            try XCTUnwrap(preview.segments.firstIndex { abs($0.x0MM - x) < 0.001 && abs($0.y0MM - y) < 0.001 })
        }

        XCTAssertLessThan(try gcodeIndex("G0 X1 Y1.200"), try gcodeIndex("G0 X5.500 Y1.500"))
        XCTAssertLessThan(try gcodeIndex("G0 X5.500 Y1.500"), try gcodeIndex("G0 X5 Y1"))
        XCTAssertLessThan(try gcodeIndex("G0 X5 Y1"), try gcodeIndex("G0 X1 Y5.500"))
        XCTAssertLessThan(try previewIndex(x: 1, y: 1.2), try previewIndex(x: 5.5, y: 1.5))
        XCTAssertLessThan(try previewIndex(x: 5.5, y: 1.5), try previewIndex(x: 5, y: 1))
        XCTAssertLessThan(try previewIndex(x: 5, y: 1), try previewIndex(x: 1, y: 5.5))
    }

    func testMixedPrintPreviewKeepsRasterAtSourceDPI() throws {
        let rasterID = UUID()
        let rasterSettings = RasterSettings(placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 25.4, heightMM: 2.54), dpi: 500, maxPowerPercent: 100)
        let rasterPhoto = ProjectPhoto(id: rasterID, name: "Raster", settings: rasterSettings)
        let raster = RasterGenerator.makeRaster(from: [[0, 0], [0, 0]], settings: rasterSettings)
        let vector = ProjectPhoto(
            name: "Vector",
            mode: .vector,
            settings: RasterSettings(),
            vectorSettings: VectorSettings(placement: PrintPlacement(xMM: 30, yMM: 0, widthMM: 10, heightMM: 10), speedMMPerSecond: 20, powerPercent: 10),
            vectorPaths: [LaserPath(closed: false, points: [Point(x: 0, y: 0), Point(x: 1, y: 0)])]
        )
        let preview = PrintGCodeGenerator.preview(for: [rasterPhoto, vector], rasters: [rasterID: raster], mode: .asset)
        let layer = try XCTUnwrap(preview.rasterLayers.first)

        XCTAssertEqual(raster.widthPixels, 500)
        XCTAssertEqual(layer.widthPixels, 500)
        XCTAssertNil(preview.imageData)
        XCTAssertTrue(preview.frames.isEmpty)
        XCTAssertFalse(preview.segments.isEmpty)
    }

    func testDisabledObjectsAreExcludedFromPrintPreviewAndFrame() throws {
        let rasterID = UUID()
        let rasterSettings = RasterSettings(placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 5, heightMM: 5), dpi: 25.4, maxPowerPercent: 100)
        let disabledRaster = ProjectPhoto(id: rasterID, name: "Disabled Raster", settings: rasterSettings, isEnabled: false)
        let enabledVector = ProjectPhoto(
            name: "Enabled Vector",
            mode: .vector,
            settings: RasterSettings(),
            vectorSettings: VectorSettings(placement: PrintPlacement(xMM: 20, yMM: 10, widthMM: 5, heightMM: 5), speedMMPerSecond: 20, powerPercent: 10),
            vectorPaths: [LaserPath(closed: true, points: [Point(x: 0, y: 0), Point(x: 1, y: 0), Point(x: 1, y: 1), Point(x: 0, y: 1)])]
        )
        let raster = RasterGenerator.makeRaster(from: [[0]], settings: rasterSettings)
        let photos = [disabledRaster, enabledVector]
        let preview = PrintGCodeGenerator.preview(for: photos, rasters: [rasterID: raster], mode: .asset)
        let framePath = try XCTUnwrap(FrameGCodeGenerator.framePaths(for: photos, rasterData: [rasterID: png(width: 1, height: 1, rgba: [0, 0, 0, 255])]).first)

        XCTAssertTrue(preview.rasterLayers.isEmpty)
        XCTAssertFalse(preview.segments.isEmpty)
        XCTAssertEqual(PrintGCodeGenerator.printableObjectCount(photos), 1)
        XCTAssertEqual(framePath.points.first?.x, 20)
        XCTAssertEqual(framePath.points.first?.y, 10)
    }

    func testVectorOnlyPrintPreviewEstimatesMachineDurationWithPasses() {
        let vector = ProjectPhoto(
            name: "Slow Vector",
            mode: .vector,
            settings: RasterSettings(),
            vectorSettings: VectorSettings(placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 10, heightMM: 10), speedMMPerSecond: 1, powerPercent: 10),
            vectorPaths: [LaserPath(closed: true, points: [Point(x: 0, y: 0), Point(x: 1, y: 0), Point(x: 1, y: 1), Point(x: 0, y: 1)])],
            passes: 2
        )

        let preview = PrintGCodeGenerator.preview(for: [vector], rasters: [:], mode: .asset)

        XCTAssertEqual(preview.estimatedDurationSeconds, 80, accuracy: 0.001)
        XCTAssertEqual(preview.playbackDurationSeconds, 3, accuracy: 0.001)
    }

    func testPrintGCodeRepeatsEachObjectPassesBeforeNextObject() throws {
        let first = ProjectPhoto(
            name: "First",
            mode: .vector,
            settings: RasterSettings(),
            vectorSettings: VectorSettings(placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 1, heightMM: 1), speedMMPerSecond: 1, powerPercent: 10),
            vectorPaths: [LaserPath(closed: false, points: [Point(x: 0, y: 0), Point(x: 1, y: 0)])],
            passes: 2
        )
        let second = ProjectPhoto(
            name: "Second",
            mode: .vector,
            settings: RasterSettings(),
            vectorSettings: VectorSettings(placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 1, heightMM: 1), speedMMPerSecond: 1, powerPercent: 20),
            vectorPaths: [LaserPath(closed: false, points: [Point(x: 0, y: 0), Point(x: 1, y: 0)])]
        )

        let gcode = PrintGCodeGenerator.makeGCode(for: [first, second], rasters: [:], mode: .asset)

        XCTAssertEqual(gcode.components(separatedBy: "\"powerFactor\": 0.100").count - 1, 2)
        XCTAssertEqual(gcode.components(separatedBy: "\"powerFactor\": 0.200").count - 1, 1)
        XCTAssertLessThan(try XCTUnwrap(gcode.range(of: "\"powerFactor\": 0.100")?.lowerBound), try XCTUnwrap(gcode.range(of: "\"powerFactor\": 0.200")?.lowerBound))
    }

    func testPrintPreviewTimingCapsAssetsAndTotalDuration() throws {
        let shortVectors = (0..<2).map { index in
            ProjectPhoto(
                name: "Vector \(index)",
                mode: .vector,
                settings: RasterSettings(),
                vectorSettings: VectorSettings(placement: PrintPlacement(xMM: Double(index * 10), yMM: 0, widthMM: 1, heightMM: 1), speedMMPerSecond: 100, powerPercent: 10),
                vectorPaths: [LaserPath(closed: false, points: [Point(x: 0, y: 0), Point(x: 1, y: 0)])]
            )
        }
        let shortPreview = PrintGCodeGenerator.preview(for: shortVectors, rasters: [:], mode: .asset)
        XCTAssertEqual(shortPreview.playbackDurationSeconds, 2, accuracy: 0.001)
        XCTAssertTrue(shortPreview.segments.allSatisfy { $0.durationSeconds >= 1 && $0.durationSeconds <= 3 })

        let manyVectors = (0..<12).map { index in
            ProjectPhoto(
                name: "Vector \(index)",
                mode: .vector,
                settings: RasterSettings(),
                vectorSettings: VectorSettings(placement: PrintPlacement(xMM: Double(index), yMM: 0, widthMM: 1, heightMM: 1), speedMMPerSecond: 100, powerPercent: 10),
                vectorPaths: [LaserPath(closed: false, points: [Point(x: 0, y: 0), Point(x: 1, y: 0)])]
            )
        }
        let cappedPreview = PrintGCodeGenerator.preview(for: manyVectors, rasters: [:], mode: .asset)
        XCTAssertLessThanOrEqual(cappedPreview.playbackDurationSeconds, 10)
        XCTAssertTrue(cappedPreview.segments.allSatisfy { $0.durationSeconds <= 3 })
        XCTAssertLessThan(try XCTUnwrap(cappedPreview.segments.first).durationSeconds, 1)
    }

    func testSimultaneousPrintPreviewTimesRasterGroupBeforeVectors() throws {
        let leftID = UUID()
        let rightID = UUID()
        let settings = RasterSettings(placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 1, heightMM: 1), dpi: 25.4, maxPowerPercent: 100)
        var rightSettings = settings
        rightSettings.placement.xMM = 3
        let left = ProjectPhoto(id: leftID, name: "Left", settings: settings)
        let right = ProjectPhoto(id: rightID, name: "Right", settings: rightSettings)
        let vector = ProjectPhoto(
            name: "Vector",
            mode: .vector,
            settings: RasterSettings(),
            vectorSettings: VectorSettings(placement: PrintPlacement(xMM: 10, yMM: 0, widthMM: 1, heightMM: 1), speedMMPerSecond: 100, powerPercent: 10),
            vectorPaths: [LaserPath(closed: false, points: [Point(x: 0, y: 0), Point(x: 1, y: 0)])]
        )
        let preview = PrintGCodeGenerator.preview(
            for: [left, right, vector],
            rasters: [
                leftID: RasterGenerator.makeRaster(from: [[0]], settings: settings),
                rightID: RasterGenerator.makeRaster(from: [[0]], settings: rightSettings)
            ],
            mode: .scanline
        )

        XCTAssertEqual(preview.rasterLayers[0].startSecond, 0, accuracy: 0.001)
        XCTAssertEqual(preview.rasterLayers[1].startSecond, 0, accuracy: 0.001)
        XCTAssertEqual(preview.rasterLayers[0].durationSeconds, preview.rasterLayers[1].durationSeconds, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(preview.segments.first).startSecond, preview.rasterLayers[0].durationSeconds, accuracy: 0.001)
        XCTAssertLessThanOrEqual(preview.playbackDurationSeconds, 10)
    }

    func testFrameGCodeUsesSelectedSpeed() {
        let vector = ProjectPhoto(
            name: "Vector",
            mode: .vector,
            settings: RasterSettings(),
            vectorSettings: VectorSettings(placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 10, heightMM: 10)),
            vectorPaths: [LaserPath(closed: false, points: [Point(x: 0, y: 0), Point(x: 1, y: 0)])]
        )
        let gcode = FrameGCodeGenerator.makeGCode(for: [vector], rasterData: [:], speedMMPerSecond: 150)

        XCTAssertTrue(gcode.contains("G1 X10 Y0 S60 F9000"))
    }

    func testFrameGCodeAllowsMachineTravelSpeed() {
        let vector = ProjectPhoto(
            name: "Vector",
            mode: .vector,
            settings: RasterSettings(),
            vectorSettings: VectorSettings(placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 10, heightMM: 10)),
            vectorPaths: [LaserPath(closed: false, points: [Point(x: 0, y: 0), Point(x: 1, y: 0)])]
        )
        let gcode = FrameGCodeGenerator.makeGCode(for: [vector], rasterData: [:], speedMMPerSecond: 5000)

        XCTAssertTrue(gcode.contains("G1 X10 Y0 S60 F240000"))
    }

    func testFrameRasterOutlineUsesBurnedPixelsNotPlacementBox() throws {
        let id = UUID()
        let photo = ProjectPhoto(
            id: id,
            name: "Raster",
            settings: RasterSettings(
                placement: PrintPlacement(xMM: 10, yMM: 20, widthMM: 30, heightMM: 30),
                dpi: 25.4,
                minPowerPercent: 0,
                maxPowerPercent: 100,
                dropPowerThresholdPercent: 1
            )
        )
        let image = png(width: 3, height: 3, rgba: [
            255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
            255, 255, 255, 255, 0, 0, 0, 255, 255, 255, 255, 255,
            255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255
        ])
        let points = try XCTUnwrap(FrameGCodeGenerator.framePaths(for: [photo], rasterData: [id: image]).first?.points)

        XCTAssertEqual(try XCTUnwrap(points.map(\.x).min()), 20, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(points.map(\.x).max()), 30, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(points.map(\.y).min()), 30, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(points.map(\.y).max()), 40, accuracy: 0.001)
    }

    func testFrameDisjointObjectsStaySeparate() {
        let paths = FrameGCodeGenerator.framePaths(for: [
            frameRectangle(x: 0, y: 0, width: 10, height: 10),
            frameRectangle(x: 20, y: 0, width: 10, height: 10)
        ], rasterData: [:])

        XCTAssertEqual(paths.count, 2)
    }

    func testFrameOverlappingObjectsUseUnionOutline() throws {
        let paths = FrameGCodeGenerator.framePaths(for: [
            frameRectangle(x: 0, y: 0, width: 10, height: 10),
            frameRectangle(x: 5, y: 0, width: 10, height: 10)
        ], rasterData: [:])
        let points = paths.flatMap(\.points)

        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(try XCTUnwrap(points.map(\.x).min()), 0, accuracy: 0.3)
        XCTAssertEqual(try XCTUnwrap(points.map(\.x).max()), 15, accuracy: 0.3)
        XCTAssertEqual(try XCTUnwrap(points.map(\.y).min()), 0, accuracy: 0.3)
        XCTAssertEqual(try XCTUnwrap(points.map(\.y).max()), 10, accuracy: 0.3)
    }

    func testFrameRectangleModeIsExplicit() throws {
        let triangle = ProjectPhoto(
            name: "Triangle",
            mode: .vector,
            settings: RasterSettings(),
            vectorSettings: VectorSettings(placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 10, heightMM: 10)),
            vectorPaths: [LaserPath(closed: true, points: [Point(x: 0, y: 0), Point(x: 1, y: 0), Point(x: 0.5, y: 1)])]
        )
        let outline = try XCTUnwrap(FrameGCodeGenerator.framePaths(for: [triangle], rasterData: [:], mode: .outline).first)
        let rectangle = try XCTUnwrap(FrameGCodeGenerator.framePaths(for: [triangle], rasterData: [:], mode: .rectangle).first)

        XCTAssertEqual(outline.points.count, 3)
        XCTAssertEqual(rectangle.points.count, 4)
    }

    func testFrameWrapModeUsesSingleConvexHullAcrossPrintedObjects() throws {
        func photo(_ name: String, placement: PrintPlacement) -> ProjectPhoto {
            ProjectPhoto(
                name: name,
                mode: .vector,
                settings: RasterSettings(),
                vectorSettings: VectorSettings(placement: placement),
                vectorPaths: [LaserPath(closed: true, points: [Point(x: 0, y: 0), Point(x: 1, y: 0), Point(x: 1, y: 1), Point(x: 0, y: 1)])]
            )
        }
        let left = photo("Left", placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 10, heightMM: 10))
        let right = photo("Right", placement: PrintPlacement(xMM: 30, yMM: 20, widthMM: 10, heightMM: 10))
        let outline = FrameGCodeGenerator.framePaths(for: [left, right], rasterData: [:], mode: .outline)
        let wrap = try XCTUnwrap(FrameGCodeGenerator.framePaths(for: [left, right], rasterData: [:], mode: .wrap).first)

        XCTAssertEqual(outline.count, 2)
        XCTAssertTrue(wrap.closed)
        XCTAssertEqual(wrap.points.count, 6)
        XCTAssertEqual(try XCTUnwrap(wrap.points.map(\.x).min()), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(wrap.points.map(\.x).max()), 40, accuracy: 0.001)
        XCTAssertFalse(wrap.points.contains { abs($0.x - 0) < 0.001 && abs($0.y - 30) < 0.001 })
        XCTAssertFalse(wrap.points.contains { abs($0.x - 40) < 0.001 && abs($0.y - 0) < 0.001 })
    }

    func testFrameVectorOutlineUsesPlacedVectorPath() {
        let vector = ProjectPhoto(
            name: "Vector",
            mode: .vector,
            settings: RasterSettings(),
            vectorSettings: VectorSettings(placement: PrintPlacement(xMM: 5, yMM: 7, widthMM: 10, heightMM: 20)),
            vectorPaths: [LaserPath(closed: false, points: [Point(x: 0.2, y: 0.3), Point(x: 1, y: 1)])]
        )
        let gcode = FrameGCodeGenerator.makeGCode(for: [vector], rasterData: [:], speedMMPerSecond: 100)

        XCTAssertTrue(gcode.contains("G0 X7 Y13"))
        XCTAssertTrue(gcode.contains("G1 X15 Y27 S60 F6000"))
    }

    func testFrameRasterOutlineIgnoresBelowThresholdPixels() {
        let id = UUID()
        let photo = ProjectPhoto(
            id: id,
            name: "Raster",
            settings: RasterSettings(
                placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 1, heightMM: 1),
                dpi: 25.4,
                minPowerPercent: 0,
                maxPowerPercent: 100,
                dropPowerThresholdPercent: 1
            )
        )

        XCTAssertTrue(FrameGCodeGenerator.framePaths(for: [photo], rasterData: [id: png(width: 1, height: 1, rgba: [255, 255, 255, 255])]).isEmpty)
    }

    func testFrameGCodeFallsBackToCenterSquareWhenNoPathsExist() {
        let gcode = FrameGCodeGenerator.makeGCode(for: [], rasterData: [:], speedMMPerSecond: 200)

        XCTAssertTrue(gcode.contains("G0 X47.500 Y47.500"))
        XCTAssertTrue(gcode.contains("G1 X67.500 Y47.500 S60 F12000"))
    }

}
