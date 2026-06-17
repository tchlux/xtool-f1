import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import xToolF1Core

final class FileStoreTests: XCTestCase {
    func testFileStorePersistsProjectsHistoryAndLog() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        let project = try store.addImageProject(data: Data([1, 2, 3]), originalName: "Photo")
        try store.add(record: PrintRecord(projectID: project.id, projectName: project.name, photoCount: 1, generatedLines: 2, generatedBytes: 10))
        try store.log("hello")
        try store.recordMachineHost("192.168.1.199")

        let loaded = try FileAppStore(root: root)
        XCTAssertEqual(loaded.data.projects.count, 1)
        XCTAssertEqual(loaded.data.history.count, 1)
        XCTAssertEqual(loaded.data.debugLog.first?.message, "hello")
        XCTAssertEqual(loaded.data.recentMachineHosts, ["192.168.1.199"])
    }

    func testOldStoreDataDefaultsRecentMachineHosts() throws {
        let json = #"{"projects":[],"history":[],"debugLog":[]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try decoder.decode(AppStoreData.self, from: Data(json.utf8))

        XCTAssertEqual(data.recentMachineHosts, [])
    }

    func testRecentMachineHostsAreMRUAndCapped() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)

        for host in ["1", "2", "3", "4", "5", "6", "3"] {
            try store.recordMachineHost(host)
        }

        XCTAssertEqual(store.data.recentMachineHosts, ["3", "6", "5", "4", "2"])
    }

    func testRenameAndDeleteProject() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        let project = try store.addImageProject(data: Data([1, 2, 3]), originalName: "Photo")
        try store.writeGenerated(projectID: project.id, text: "gcode", preview: Data([4]))

        try store.renameProject(id: project.id, to: "Renamed")
        XCTAssertEqual(store.data.projects.first?.name, "Renamed")

        try store.deleteProject(id: project.id)
        XCTAssertEqual(store.data.projects, [])
        XCTAssertEqual(store.data.libraryAssets.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(store.imageURL(for: project.photos[0])).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.projectsURL.appendingPathComponent(project.id.uuidString).appendingPathExtension("txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.projectsURL.appendingPathComponent(project.id.uuidString).appendingPathExtension("png").path))
    }

    func testNewProjectDefaultsNameToCreationDate() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        let project = try store.addImageProject(data: Data([1, 2, 3]))

        XCTAssertEqual(project.name, FileAppStore.defaultProjectName(for: project.createdAt))
        XCTAssertEqual(project.photos.first?.name, "Photo")
    }

    func testNewProjectPlacementRespectsImageOrientation() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        let project = try store.addImageProject(data: jpeg(width: 4, height: 2, orientation: 6))
        let placement = try XCTUnwrap(project.photos.first?.settings.placement)

        XCTAssertLessThan(placement.widthMM, placement.heightMM)
        XCTAssertEqual(placement.widthMM, 34, accuracy: 0.1)
        XCTAssertEqual(placement.heightMM, 68, accuracy: 0.1)
    }

    func testStoredProjectDecodesOldSinglePhotoDataWithoutUndoHistory() throws {
        let json = """
        {
          "createdAt": "2026-06-09T00:00:00Z",
          "id": "00000000-0000-0000-0000-000000000001",
          "mode": "raster",
          "name": "Old",
          "settings": {},
          "sourceImagePath": "Images/old.jpg",
          "updatedAt": "2026-06-09T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(StoredProject.self, from: Data(json.utf8))
        XCTAssertEqual(project.photos.first?.legacySourceImagePath, "Images/old.jpg")
        XCTAssertEqual(project.photos.first?.passes, 1)
        XCTAssertEqual(project.gcodeMode, .asset)
        XCTAssertEqual(project.undoHistory, [])
        XCTAssertEqual(project.redoHistory, [])
    }

    func testStoredProjectDecodesOldSinglePhotoUndoHistory() throws {
        let json = """
        {
          "createdAt": "2026-06-09T00:00:00Z",
          "id": "00000000-0000-0000-0000-000000000001",
          "mode": "raster",
          "name": "Old",
          "settings": {},
          "sourceImagePath": "Images/old.jpg",
          "updatedAt": "2026-06-09T00:00:00Z",
          "undoHistory": [{
            "mode": "raster",
            "name": "Previous",
            "settings": { "dpi": 250 },
            "sourceImagePath": "Images/previous.jpg"
          }]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(StoredProject.self, from: Data(json.utf8))
        XCTAssertEqual(project.undoHistory.first?.photos.first?.legacySourceImagePath, "Images/previous.jpg")
    }

    func testUndoAndRedoHistoryPersistWithProject() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        var project = try store.addImageProject(data: Data([1, 2, 3]), originalName: "Photo")
        let snapshot = project.snapshot
        project.photos[0].settings.placement.widthMM = 50
        project.undoHistory.append(snapshot)
        project.redoHistory.append(project.snapshot)
        try store.update(project: project)

        let loaded = try FileAppStore(root: root)
        XCTAssertEqual(loaded.data.projects.first?.undoHistory, [snapshot])
        XCTAssertEqual(loaded.data.projects.first?.redoHistory, [project.snapshot])
    }

    func testSnapshotRestoresWholeProjectFields() throws {
        var project = StoredProject(name: "Original", photos: [ProjectPhoto(sourceImagePath: "Images/a.jpg")])
        let snapshot = project.snapshot
        project.name = "Changed"
        project.gcodeMode = .scanline
        project.photos[0].mode = .vector
        project.photos[0].legacySourceImagePath = "Images/b.jpg"
        project.photos[0].settings.dpi = 250

        snapshot.restore(on: &project)
        XCTAssertEqual(project.snapshot, snapshot)
    }

    func testStoreAddsMultiplePhotosToProject() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        let project = try store.addImageProject(data: Data([1, 2, 3]), originalName: "Photo")
        _ = try store.addPhoto(data: Data([4, 5, 6]), to: project.id)

        XCTAssertEqual(store.data.projects.first?.photos.count, 2)
    }

    func testStoreDedupesImportedImagesByHash() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        let first = try store.addImageProject(data: Data([1, 2, 3]), originalName: "One")
        let second = try store.addImageProject(data: Data([1, 2, 3]), originalName: "Two")

        XCTAssertEqual(store.data.libraryAssets.count, 1)
        XCTAssertEqual(first.photos.first?.assetID, second.photos.first?.assetID)
    }

    func testImportsXCSSamplesAndSkipsRepeatedContent() throws {
        let samples = URL(fileURLWithPath: "/Users/thomaslux/Desktop/XCS-samples")
        guard FileManager.default.fileExists(atPath: samples.path) else {
            throw XCTSkip("XCS sample folder not available")
        }
        let urls = try FileManager.default.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xcs" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard urls.isEmpty == false else {
            throw XCTSkip("No XCS sample files available")
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)

        let first = store.importXCSProjects(from: urls)
        let second = store.importXCSProjects(from: urls)

        XCTAssertEqual(first.failures, [])
        XCTAssertEqual(first.imported.count, urls.count)
        XCTAssertEqual(second.imported.count, 0)
        XCTAssertEqual(second.skipped.count, urls.count)
        XCTAssertEqual(store.data.projects.count, urls.count)
        XCTAssertTrue(store.data.projects.allSatisfy { $0.importFingerprint?.isEmpty == false })
        XCTAssertTrue(store.data.projects.flatMap(\.photos).contains { $0.mode == .text && $0.textSettings?.text == "Jamaica VA" })
        XCTAssertTrue(store.data.projects.flatMap(\.photos).contains { abs($0.printPlacement.rotationDegrees) > 1 })
        XCTAssertTrue(store.data.projects.flatMap(\.photos).contains { !$0.isEnabled })
        if let inky = first.imported.first(where: { $0.name == "Inky" }) {
            XCTAssertEqual(inky.photos.count, 1)
        }
    }

    func testXCSImportSupportsArcAndShorthandVectorPaths() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        let url = root.appendingPathComponent("curves.xcs")
        let json = """
        {
          "extId": "F1",
          "created": 0,
          "modify": 0,
          "canvas": [{
            "displays": [{
              "id": "path-1",
              "type": "PATH",
              "visible": true,
              "visibleState": true,
              "zOrder": 0,
              "x": 0,
              "y": 0,
              "width": 110,
              "height": 30,
              "angle": 0,
              "dPath": "M 0 10 C 10 0 20 0 30 10 S 50 20 60 10 Q 65 5 70 10 T 80 10 A 10 10 0 0 1 100 20"
            }]
          }]
        }
        """
        try json.write(to: url, atomically: true, encoding: .utf8)

        let project = try XCTUnwrap(try store.importXCSProject(from: url))
        let asset = try XCTUnwrap(project.photos.first?.assetID.flatMap { id in store.data.libraryAssets.first { $0.id == id } })

        XCTAssertEqual(asset.kind, .vector)
        XCTAssertEqual(asset.vectorPaths.count, 1)
        XCTAssertGreaterThan(asset.vectorPaths[0].points.count, 30)
    }

    func testXCSImportSkipsObjectsOutsideWorkArea() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        let url = root.appendingPathComponent("off-bed.xcs")
        let image = png(width: 1, height: 1, rgba: [0, 0, 0, 255]).base64EncodedString()
        let json = """
        {
          "extId": "F1",
          "created": 0,
          "modify": 0,
          "canvas": [{
            "displays": [
              {
                "id": "path-1",
                "type": "PATH",
                "visible": true,
                "visibleState": true,
                "zOrder": 0,
                "x": 20,
                "y": 140,
                "width": 10,
                "height": 10,
                "angle": 0,
                "dPath": "M 20 140 L 30 140 L 30 150 Z"
              },
              {
                "id": "bitmap-1",
                "type": "BITMAP",
                "visible": true,
                "visibleState": true,
                "zOrder": 1,
                "x": 10,
                "y": 10,
                "width": 5,
                "height": 5,
                "angle": 0,
                "base64": "data:image/png;base64,\(image)"
              }
            ]
          }]
        }
        """
        try json.write(to: url, atomically: true, encoding: .utf8)

        let project = try XCTUnwrap(try store.importXCSProject(from: url))

        XCTAssertEqual(project.photos.count, 1)
        XCTAssertEqual(project.photos.first?.mode, .raster)
    }

    func testTextObjectCodableDefaultsAndPersistence() throws {
        let placement = PrintPlacement(xMM: 1, yMM: 2, widthMM: 3, heightMM: 4, rotationDegrees: 90)
        let photo = ProjectPhoto(name: "Hello", mode: .text, settings: RasterSettings(placement: placement), vectorSettings: VectorSettings(placement: placement), vectorPaths: [LaserPath(closed: false, points: [Point(x: 0, y: 0), Point(x: 1, y: 1)])], textSettings: TextSettings(text: "Hello", fontFamily: "Helvetica"), isEnabled: false)
        let decoded = try JSONDecoder().decode(ProjectPhoto.self, from: JSONEncoder().encode(photo))

        XCTAssertEqual(decoded.mode, .text)
        XCTAssertEqual(decoded.textSettings?.text, "Hello")
        XCTAssertEqual(decoded.printPlacement.rotationDegrees, 90)
        XCTAssertFalse(decoded.isEnabled)
    }

    func testTextGeneratorWrapsAndHonorsExplicitNewlines() {
        let settings = TextSettings(text: "Alpha beta gamma delta\nOmega", fontFamily: "Helvetica", fontSize: 18)

        XCTAssertGreaterThan(TextVectorGenerator.wrappedLines(for: settings, boxWidthPoints: 70).count, 2)
        XCTAssertEqual(TextVectorGenerator.wrappedLines(for: TextSettings(text: "Top\nBottom"), boxWidthPoints: 500), ["Top", "Bottom"])
    }

    func testTextAlignmentMovesGlyphsInsideTextBox() throws {
        let placement = PrintPlacement(xMM: 0, yMM: 0, widthMM: 60, heightMM: 20)
        let left = try bounds(TextVectorGenerator.paths(for: TextSettings(text: "Hi", alignment: .left), placement: placement))
        let center = try bounds(TextVectorGenerator.paths(for: TextSettings(text: "Hi", alignment: .center), placement: placement))
        let right = try bounds(TextVectorGenerator.paths(for: TextSettings(text: "Hi", alignment: .right), placement: placement))

        XCTAssertLessThan(left.minX, center.minX)
        XCTAssertLessThan(center.minX, right.minX)
    }

    func testTextGeneratorUsesUniformScaleForOverflow() throws {
        let paths = TextVectorGenerator.paths(
            for: TextSettings(text: "WWWWWWWWWWWWWWWW", fontFamily: "Helvetica", fontSize: 18),
            placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 10, heightMM: 60)
        )
        let box = try bounds(paths)

        XCTAssertLessThanOrEqual(box.maxX, 1.0001)
        XCTAssertLessThanOrEqual(box.maxY, 1.0001)
        XCTAssertLessThan(box.height, 0.6)
    }

    func testVectorAndTextLibraryAssetsCodable() throws {
        let drawing = EditableVectorDrawing(rawSegments: [[Point(x: 0, y: 0), Point(x: 1, y: 1)]], smoothness: 0)
        let asset = LibraryAsset(kind: .text, sha256: "abc", originalName: "Hello", vectorPaths: [LaserPath(closed: false, points: [Point(x: 0, y: 0), Point(x: 1, y: 1)])], vectorSettings: VectorSettings(), vectorDrawing: drawing, textSettings: TextSettings(text: "Hello"))
        let decoded = try JSONDecoder().decode(LibraryAsset.self, from: JSONEncoder().encode(asset))

        XCTAssertEqual(decoded.kind, .text)
        XCTAssertEqual(decoded.originalName, "Hello")
        XCTAssertEqual(decoded.vectorPaths.count, 1)
        XCTAssertEqual(decoded.vectorDrawing?.rawSegments.count, 1)
        XCTAssertEqual(decoded.textSettings?.text, "Hello")
        XCTAssertEqual(decoded.imagePath, "")
    }

    func testVectorDrawingDecodesMissingAccuracyAsDefault() throws {
        let data = #"{"rawSegments":[[{"x":0,"y":0},{"x":1,"y":1}]],"smoothness":0.5,"nodes":[]}"#.data(using: .utf8)!
        let drawing = try JSONDecoder().decode(EditableVectorDrawing.self, from: data)

        XCTAssertEqual(drawing.smoothness, 0.5)
        XCTAssertEqual(drawing.accuracy, 0)
    }

    func testVectorDrawingLiftCreatesSeparateSegments() {
        var drawing = EditableVectorDrawing()
        drawing = VectorDrawingGenerator.appending([Point(x: 0, y: 0), Point(x: 0.2, y: 0.2)], to: drawing)
        drawing = VectorDrawingGenerator.appending([Point(x: 0.6, y: 0.6), Point(x: 0.8, y: 0.8)], to: drawing)

        XCTAssertEqual(drawing.rawSegments.count, 2)
        XCTAssertEqual(VectorDrawingGenerator.paths(for: drawing).count, 2)
    }

    func testVectorDrawingZeroSmoothnessPreservesRawPoints() {
        let raw = [Point(x: 0, y: 0), Point(x: 0.2, y: 0.1), Point(x: 0.4, y: 0.3), Point(x: 1, y: 1)]
        let drawing = VectorDrawingGenerator.drawing(rawSegments: [raw], smoothness: 0)

        XCTAssertEqual(drawing.nodes[0].map(\.point), raw)
        XCTAssertEqual(VectorDrawingGenerator.paths(for: drawing)[0].points, raw)
    }

    func testVectorDrawingSmoothnessFitsFewerNodesAndPreservesEndpoints() throws {
        let raw = (0..<24).map { index in
            let x = Double(index) / 23
            return Point(x: x, y: 0.5 + sin(x * .pi * 2) * 0.16)
        }
        let drawing = VectorDrawingGenerator.drawing(rawSegments: [raw], smoothness: 1)
        let nodes = try XCTUnwrap(drawing.nodes.first)

        XCTAssertLessThan(nodes.count, raw.count)
        XCTAssertEqual(nodes.first?.point, raw.first)
        XCTAssertEqual(nodes.last?.point, raw.last)
    }

    func testVectorDrawingAccuracyKeepsMoreNodesAtSameSmoothness() throws {
        let raw = (0..<60).map { index in
            let x = Double(index) / 59
            return Point(x: x, y: 0.5 + sin(x * .pi * 3) * 0.12)
        }
        let loose = try XCTUnwrap(VectorDrawingGenerator.drawing(rawSegments: [raw], smoothness: 1, accuracy: 0).nodes.first)
        let accurate = try XCTUnwrap(VectorDrawingGenerator.drawing(rawSegments: [raw], smoothness: 1, accuracy: 1).nodes.first)

        XCTAssertGreaterThan(accurate.count, loose.count)
        XCTAssertEqual(accurate.first?.point, raw.first)
        XCTAssertEqual(accurate.last?.point, raw.last)
    }

    func testVectorDrawingSmoothnessRoundsFittedNodeDerivatives() throws {
        let corner = Point(x: 0.5, y: 0)
        let raw = [Point(x: 0, y: 0), corner, Point(x: 0.5, y: 0.5), Point(x: 1, y: 0.5)]
        let path = try XCTUnwrap(VectorDrawingGenerator.paths(for: VectorDrawingGenerator.drawing(rawSegments: [raw], smoothness: 1, accuracy: 1)).first)
        let index = try XCTUnwrap(path.points.indices.dropFirst().dropLast().min { distance(path.points[$0], corner) < distance(path.points[$1], corner) })
        let incoming = Point(x: path.points[index].x - path.points[index - 1].x, y: path.points[index].y - path.points[index - 1].y)
        let outgoing = Point(x: path.points[index + 1].x - path.points[index].x, y: path.points[index + 1].y - path.points[index].y)

        XCTAssertGreaterThan(dot(incoming, outgoing), 0.8)
    }

    func testVectorDrawingConnectsAndDisconnectsSelectedPoints() {
        let drawing = VectorDrawingGenerator.drawing(rawSegments: [
            [Point(x: 0, y: 0), Point(x: 0.2, y: 0.2)],
            [Point(x: 0.7, y: 0.7), Point(x: 1, y: 1)]
        ])
        let connected = VectorDrawingGenerator.connect(drawing, EditableVectorSelection(segmentIndex: 0, nodeIndex: 1), EditableVectorSelection(segmentIndex: 1, nodeIndex: 0))
        let disconnected = VectorDrawingGenerator.disconnect(connected, at: EditableVectorSelection(segmentIndex: 0, nodeIndex: 1))

        XCTAssertEqual(connected.rawSegments.count, 1)
        XCTAssertEqual(connected.rawSegments[0].count, 4)
        XCTAssertEqual(disconnected.rawSegments.count, 2)
    }

    func testVectorDrawingLineEraserSplitsCrossedSegments() {
        let raw = [Point(x: 0, y: 0.5), Point(x: 0.3, y: 0.5), Point(x: 0.7, y: 0.5), Point(x: 1, y: 0.5)]
        let drawing = VectorDrawingGenerator.drawing(rawSegments: [raw])
        let erased = VectorDrawingGenerator.erasing(drawing, stroke: [Point(x: 0.5, y: 0), Point(x: 0.5, y: 1)], radius: 0)

        XCTAssertEqual(erased.rawSegments.count, 2)
        XCTAssertEqual(erased.rawSegments[0], [raw[0], raw[1]])
        XCTAssertEqual(erased.rawSegments[1], [raw[2], raw[3]])
    }

    func testVectorDrawingRadiusEraserOnlyRemovesNearbyStrokeSections() {
        let raw = [Point(x: 0, y: 0.5), Point(x: 0.3, y: 0.5), Point(x: 0.7, y: 0.5), Point(x: 1, y: 0.5)]
        let drawing = VectorDrawingGenerator.drawing(rawSegments: [raw])
        let erased = VectorDrawingGenerator.erasing(drawing, stroke: [Point(x: 0.5, y: 0.62)], radius: 0.13)

        XCTAssertEqual(erased.rawSegments.count, 2)
        XCTAssertEqual(erased.rawSegments[0], [raw[0], raw[1]])
        XCTAssertEqual(erased.rawSegments[1], [raw[2], raw[3]])
    }

    func testStoreBackfillsVectorObjectsIntoLibrary() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        let photo = ProjectPhoto(name: "Rectangle", mode: .vector, vectorSettings: VectorSettings(), vectorPaths: [LaserPath(closed: true, points: [Point(x: 0, y: 0), Point(x: 1, y: 0), Point(x: 1, y: 1)])])
        store.data.projects = [StoredProject(name: "Vector", photos: [photo])]
        try store.save()

        let loaded = try FileAppStore(root: root)
        let object = try XCTUnwrap(loaded.data.projects.first?.photos.first)
        let asset = try XCTUnwrap(object.assetID.flatMap { id in loaded.data.libraryAssets.first { $0.id == id } })

        XCTAssertEqual(asset.kind, .vector)
        XCTAssertEqual(asset.originalName, "Rectangle")
        XCTAssertEqual(asset.vectorPaths.count, 1)
    }

    func testDerivedVectorAssetStaysAdjacentToSource() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        let project = try store.addImageProject(data: Data([1, 2, 3]), originalName: "Photo")
        let parent = try XCTUnwrap(project.photos.first?.assetID)
        var outline = ProjectPhoto(name: "Outline", mode: .vector, vectorSettings: VectorSettings(), vectorPaths: [LaserPath(closed: true, points: [Point(x: 0, y: 0), Point(x: 1, y: 0), Point(x: 1, y: 1)])])

        _ = store.syncObjectAsset(for: &outline, projectID: project.id, parentAssetID: parent, editKind: "outline")

        let parentIndex = try XCTUnwrap(store.data.libraryAssets.firstIndex { $0.id == parent })
        XCTAssertEqual(store.data.libraryAssets[store.data.libraryAssets.index(after: parentIndex)].id, outline.assetID)
        XCTAssertEqual(store.data.libraryAssets[store.data.libraryAssets.index(after: parentIndex)].mutation?.parentAssetID, parent)
    }

    func testDerivedPhotoEditAssetStaysAdjacentToSource() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        let first = try store.addImageProject(data: Data([1, 2, 3]), originalName: "One")
        _ = try store.addImageProject(data: Data([1, 2, 3]), originalName: "Two")
        let parent = try XCTUnwrap(first.photos.first?.assetID)
        let edited = try store.makeDerivedAsset(data: png(width: 1, height: 1, rgba: [0, 0, 0, 0]), from: first.photos[0], projectID: first.id, editKind: "magicEraser")

        let parentIndex = try XCTUnwrap(store.data.libraryAssets.firstIndex { $0.id == parent })
        XCTAssertEqual(store.data.libraryAssets[store.data.libraryAssets.index(after: parentIndex)].id, edited.id)
        XCTAssertEqual(edited.mutation?.parentAssetID, parent)
    }

    func testCanvasRotationSnapperSnapsSoftlyToFortyFiveDegrees() {
        XCTAssertEqual(CanvasRotationSnapper.snap(44), 45)
        XCTAssertEqual(CanvasRotationSnapper.snap(91), 90)
        XCTAssertEqual(CanvasRotationSnapper.snap(39), 39)
    }

    func testDerivedPhotoEditAssetDoesNotContaminateReuse() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        var first = try store.addImageProject(data: Data([1, 2, 3]), originalName: "One")
        let second = try store.addImageProject(data: Data([1, 2, 3]), originalName: "Two")
        let originalAssetID = try XCTUnwrap(first.photos.first?.assetID)
        let edited = try store.makeDerivedAsset(data: png(width: 1, height: 1, rgba: [0, 0, 0, 0]), from: first.photos[0], projectID: first.id, editKind: "magicEraser", values: ["fuzziness": 10])

        first.photos[0].assetID = edited.id
        try store.update(project: first)

        XCTAssertEqual(store.data.projects.first { $0.id == second.id }?.photos.first?.assetID, originalAssetID)
        XCTAssertEqual(store.data.projects.first { $0.id == first.id }?.photos.first?.assetID, edited.id)
        XCTAssertEqual(store.data.libraryAssets.first { $0.id == edited.id }?.mutation?.parentAssetID, originalAssetID)
    }

    func testPhotoEditReusesAssetWhenOnlyUsedByOneProject() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        let project = try store.addImageProject(data: Data([1, 2, 3]), originalName: "One")
        let originalAssetID = try XCTUnwrap(project.photos.first?.assetID)
        let edited = try store.makeDerivedAsset(data: png(width: 1, height: 1, rgba: [0, 0, 0, 0]), from: project.photos[0], projectID: project.id, editKind: "magicEraser")

        XCTAssertEqual(edited.id, originalAssetID)
        XCTAssertEqual(store.data.libraryAssets.count, 1)
        XCTAssertEqual(store.data.libraryAssets.first?.imagePath.hasSuffix(".png"), true)
    }

    func testPhotoEditSnapshotRestoresReusedAssetState() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        let project = try store.addImageProject(data: Data([1, 2, 3]), originalName: "One")
        let original = try XCTUnwrap(store.data.libraryAssets.first)
        let snapshot = StoredProjectSnapshot(project: project, libraryAssets: [original])

        _ = try store.makeDerivedAsset(data: png(width: 1, height: 1, rgba: [0, 0, 0, 0]), from: project.photos[0], projectID: project.id, editKind: "magicEraser")
        XCTAssertNotEqual(store.data.libraryAssets.first?.imagePath, original.imagePath)

        try store.restoreAssets(snapshot.libraryAssets)
        XCTAssertEqual(store.data.libraryAssets.first?.imagePath, original.imagePath)
    }

    func testPhotoEditAssetUndoHistoryPersistsAndRestoresPath() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        let project = try store.addImageProject(data: Data([1, 2, 3]), originalName: "One")
        let original = try XCTUnwrap(store.data.libraryAssets.first)

        _ = try store.makeDerivedAsset(data: png(width: 1, height: 1, rgba: [0, 0, 0, 255]), from: project.photos[0], projectID: project.id, editKind: "manualEraser")
        try store.save()
        let loaded = try FileAppStore(root: root)
        let edited = try XCTUnwrap(loaded.data.libraryAssets.first)

        XCTAssertEqual(edited.undoHistory.first?.imagePath, original.imagePath)
        XCTAssertNotEqual(edited.imagePath, original.imagePath)
        _ = try loaded.undoAsset(id: edited.id)
        XCTAssertEqual(loaded.data.libraryAssets.first?.imagePath, original.imagePath)
        XCTAssertEqual(loaded.data.libraryAssets.first?.redoHistory.first?.imagePath, edited.imagePath)
    }

    func testObjectAssetUndoHistoryPersistsAndRestoresVectorDrawing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        let projectID = UUID()
        let first = [Point(x: 0, y: 0), Point(x: 1, y: 1)]
        let second = [Point(x: 0, y: 1), Point(x: 1, y: 0)]
        var photo = ProjectPhoto(name: "Draw", mode: .vector, vectorSettings: VectorSettings(), vectorPaths: [LaserPath(closed: false, points: first)], vectorDrawing: EditableVectorDrawing(rawSegments: [first], smoothness: 0))

        _ = store.syncObjectAsset(for: &photo, projectID: projectID)
        photo.vectorPaths = [LaserPath(closed: false, points: second)]
        photo.vectorDrawing = EditableVectorDrawing(rawSegments: [second], smoothness: 0)
        let edited = try XCTUnwrap(try store.commitObjectAsset(for: &photo, projectID: projectID))
        let loaded = try FileAppStore(root: root)

        XCTAssertEqual(try XCTUnwrap(loaded.data.libraryAssets.first { $0.id == edited.id }).undoHistory.count, 1)
        XCTAssertEqual(try XCTUnwrap(try loaded.undoAsset(id: edited.id)).vectorDrawing?.rawSegments.first, first)
        XCTAssertEqual(try XCTUnwrap(try loaded.redoAsset(id: edited.id)).vectorDrawing?.rawSegments.first, second)
    }

    func testObjectAssetUndoHistoryPersistsAndRestoresTextSettings() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        let projectID = UUID()
        let placement = PrintPlacement(xMM: 10, yMM: 10, widthMM: 40, heightMM: 20)
        let first = TextSettings(text: "Hello", fontSize: 12)
        let second = TextSettings(text: "Hello\nWorld", fontSize: 18, alignment: .left)
        var photo = ProjectPhoto(name: "Hello", mode: .text, vectorSettings: VectorSettings(placement: placement), vectorPaths: TextVectorGenerator.paths(for: first, placement: placement), textSettings: first)

        _ = store.syncObjectAsset(for: &photo, projectID: projectID)
        photo.name = "Hello World"
        photo.textSettings = second
        photo.vectorPaths = TextVectorGenerator.paths(for: second, placement: placement)
        let edited = try XCTUnwrap(try store.commitObjectAsset(for: &photo, projectID: projectID))
        let loaded = try FileAppStore(root: root)

        XCTAssertEqual(try XCTUnwrap(loaded.data.libraryAssets.first { $0.id == edited.id }).undoHistory.count, 1)
        XCTAssertEqual(try XCTUnwrap(try loaded.undoAsset(id: edited.id)).textSettings, first)
        XCTAssertEqual(try XCTUnwrap(try loaded.redoAsset(id: edited.id)).textSettings, second)
    }

    func testObjectAssetsDedupeAndForkWhenSharedEditChangesContent() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        let firstProjectID = UUID()
        let secondProjectID = UUID()
        let placement = PrintPlacement(xMM: 10, yMM: 10, widthMM: 40, heightMM: 20)
        let text = TextSettings(text: "Hello", fontSize: 12)
        var first = ProjectPhoto(name: "Hello", mode: .text, vectorSettings: VectorSettings(placement: placement), vectorPaths: TextVectorGenerator.paths(for: text, placement: placement), textSettings: text)
        var second = ProjectPhoto(name: "Renamed", mode: .text, vectorSettings: VectorSettings(placement: placement), vectorPaths: TextVectorGenerator.paths(for: text, placement: placement), textSettings: text)

        _ = store.syncObjectAsset(for: &first, projectID: firstProjectID)
        _ = store.syncObjectAsset(for: &second, projectID: secondProjectID)
        XCTAssertEqual(first.assetID, second.assetID)
        XCTAssertEqual(store.data.libraryAssets.count, 1)

        store.data.projects = [
            StoredProject(id: firstProjectID, name: "First", photos: [first]),
            StoredProject(id: secondProjectID, name: "Second", photos: [second])
        ]
        second.name = "Display Rename"
        let renamed = try XCTUnwrap(try store.commitObjectAsset(for: &second, projectID: secondProjectID))
        XCTAssertEqual(renamed.id, first.assetID)
        XCTAssertEqual(store.data.libraryAssets.count, 1)

        let editedText = TextSettings(text: "Hello World", fontSize: 12)
        second.textSettings = editedText
        second.vectorPaths = TextVectorGenerator.paths(for: editedText, placement: placement)
        let edited = try XCTUnwrap(try store.commitObjectAsset(for: &second, projectID: secondProjectID))

        XCTAssertNotEqual(edited.id, first.assetID)
        XCTAssertEqual(second.assetID, edited.id)
        XCTAssertEqual(edited.mutation?.parentAssetID, first.assetID)
        XCTAssertEqual(store.data.libraryAssets.count, 2)
        XCTAssertEqual(store.data.libraryAssets.first { $0.id == first.assetID }?.textSettings?.text, "Hello")
    }

    func testDeleteUnusedAssetOnlyRemovesAssetsWithNoProjectUses() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        let project = try store.addImageProject(data: Data([1, 2, 3]), originalName: "One")
        let usedAssetID = try XCTUnwrap(project.photos.first?.assetID)
        let unused = try store.makeDerivedAsset(data: png(width: 1, height: 1, rgba: [0, 0, 0, 0]), from: ProjectPhoto(name: "Unused"), projectID: project.id, editKind: "magicEraser")

        try store.deleteUnusedAsset(id: usedAssetID)
        XCTAssertNotNil(store.data.libraryAssets.first { $0.id == usedAssetID })

        try store.deleteUnusedAsset(id: unused.id)
        XCTAssertNil(store.data.libraryAssets.first { $0.id == unused.id })
    }

    func testBatchDeleteUnusedAssetsOnlyRemovesUnusedSelection() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        let project = try store.addImageProject(data: Data([1, 2, 3]), originalName: "One")
        let usedAssetID = try XCTUnwrap(project.photos.first?.assetID)
        let unusedA = try store.makeDerivedAsset(data: png(width: 1, height: 1, rgba: [0, 0, 0, 0]), from: ProjectPhoto(name: "Unused A"), projectID: project.id, editKind: "magicEraser")
        let unusedB = try store.makeDerivedAsset(data: png(width: 1, height: 1, rgba: [255, 0, 0, 255]), from: ProjectPhoto(name: "Unused B"), projectID: project.id, editKind: "manualEraser")

        let deleted = try store.deleteUnusedAssets(ids: [usedAssetID, unusedA.id, unusedB.id])

        XCTAssertEqual(deleted, 2)
        XCTAssertNotNil(store.data.libraryAssets.first { $0.id == usedAssetID })
        XCTAssertNil(store.data.libraryAssets.first { $0.id == unusedA.id })
        XCTAssertNil(store.data.libraryAssets.first { $0.id == unusedB.id })
    }

    func testDeleteUnusedAssetRemovesUndoRedoImageFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        let project = try store.addImageProject(data: Data([1, 2, 3]), originalName: "One")
        let assetID = try XCTUnwrap(project.photos.first?.assetID)
        let originalPath = try XCTUnwrap(store.data.libraryAssets.first { $0.id == assetID }?.imagePath)
        let edited = try store.makeDerivedAsset(data: png(width: 1, height: 1, rgba: [0, 0, 0, 255]), from: project.photos[0], projectID: project.id, editKind: "manualEraser")
        let editedPath = edited.imagePath

        _ = try store.undoAsset(id: assetID)
        try store.deleteProject(id: project.id)
        try store.deleteUnusedAsset(id: assetID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.absoluteURL(for: originalPath).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.absoluteURL(for: editedPath).path))
    }

    func testStoreMigratesLegacyProjectPhotosToLibraryAssets() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let images = root.appendingPathComponent("Images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data([7, 8, 9]).write(to: images.appendingPathComponent("old.jpg"))
        try """
        {
          "projects": [{
            "createdAt": "2026-06-09T00:00:00Z",
            "id": "00000000-0000-0000-0000-000000000001",
            "mode": "raster",
            "name": "Old",
            "settings": {},
            "sourceImagePath": "Images/old.jpg",
            "updatedAt": "2026-06-09T00:00:00Z"
          }],
          "history": [],
          "debugLog": []
        }
        """.write(to: root.appendingPathComponent("store.json"), atomically: true, encoding: .utf8)

        let store = try FileAppStore(root: root)

        XCTAssertEqual(store.data.libraryAssets.count, 1)
        XCTAssertNotNil(store.data.projects.first?.photos.first?.assetID)
        XCTAssertNil(store.data.projects.first?.photos.first?.legacySourceImagePath)
    }

    func testNewProjectUsesLastPresetSettings() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        _ = try store.savePreset(name: "Wood", settings: RasterSettings(dpi: 250, maxPowerPercent: 70))
        let project = try store.addImageProject(data: Data([1, 2, 3]))

        XCTAssertEqual(project.photos.first?.settingsName, "Wood")
        XCTAssertEqual(project.photos.first?.settings.dpi, 250)
        XCTAssertEqual(project.photos.first?.settings.maxPowerPercent, 70)
    }

    func testAddedPhotoCopiesExistingProjectSettings() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        var project = try store.addImageProject(data: Data([1, 2, 3]))
        project.photos[0].settingsName = "Wood"
        project.photos[0].settings.dpi = 250
        try store.update(project: project)
        let updated = try XCTUnwrap(try store.addPhoto(data: Data([4, 5, 6]), to: project.id))

        XCTAssertEqual(updated.photos.last?.settingsName, "Wood")
        XCTAssertEqual(updated.photos.last?.settings.dpi, 250)
    }

}
