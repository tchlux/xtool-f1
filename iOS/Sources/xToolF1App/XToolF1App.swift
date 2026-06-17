import SwiftUI
import PhotosUI
import ImageIO
#if !APP_PROJECT
import xToolF1Core
#endif
#if os(iOS)
import UIKit
import Photos
import Darwin
private typealias PlatformImage = UIImage
#elseif os(macOS)
import AppKit
import Darwin
private typealias PlatformImage = NSImage
#endif

private enum AppLaunchScenario: String {
    case normal
    case editorSmoke = "editor-smoke"
    case editorVisual = "editor-visual"
    case canvasSmoke = "canvas-smoke"
    case previewProject = "preview-project"
    case firstProject = "first-project"
}

private struct AppLaunchState: Codable, @unchecked Sendable {
    var project: StoredProjectSnapshot?
    var projects: [StoredProjectSnapshot]?
    var libraryAssets: [LibraryAsset]?
    var selectedProjectName: String?
    var selectedObjectIDs: [UUID]?
    var selectedObjectNames: [String]?
    var editObjectID: UUID?
    var editObjectName: String?

    var storedProjects: [StoredProject] {
        (projects ?? project.map { [$0] } ?? []).map {
            StoredProject(name: $0.name, photos: $0.photos, gcodeMode: $0.gcodeMode, frameMode: $0.frameMode, frameSpeedMMPerSecond: $0.frameSpeedMMPerSecond)
        }
    }

    func selectedProject(in projects: [StoredProject]) -> StoredProject? {
        if let name = selectedProjectName, let project = projects.first(where: { $0.name == name }) { return project }
        return projects.first
    }

    func selectedObjectIDs(in project: StoredProject) -> Set<UUID> {
        var ids = Set(selectedObjectIDs ?? [])
        for name in selectedObjectNames ?? [] {
            ids.formUnion(project.photos.filter { $0.name == name }.map(\.id))
        }
        return ids.isEmpty ? Set(project.photos.prefix(1).map(\.id)) : ids
    }

    func editID(in project: StoredProject) -> UUID? {
        editObjectID ?? editObjectName.flatMap { name in project.photos.first { $0.name == name }?.id }
    }
}

private struct AppLaunchOptions: @unchecked Sendable {
    static let current = AppLaunchOptions(arguments: ProcessInfo.processInfo.arguments)

    let arguments: [String]
    let scenario: AppLaunchScenario
    let launchState: AppLaunchState?

    init(arguments: [String]) {
        self.arguments = arguments
        var scenario = AppLaunchScenario.normal
        for index in arguments.indices where arguments[index] == "--scenario" && arguments.indices.contains(index + 1) {
            scenario = AppLaunchScenario(rawValue: arguments[index + 1]) ?? scenario
        }
        if arguments.contains("--editor-smoke-test") { scenario = .editorSmoke }
        if arguments.contains("--editor-visual-test") { scenario = .editorVisual }
        self.scenario = scenario
        self.launchState = Self.decodeLaunchState(arguments)
        print("Launch scenario: \(scenario.rawValue)")
    }

    var resetStore: Bool { arguments.contains("--reset-store") || launchState != nil || scenario == .previewProject || scenario == .firstProject }
    var importFirstPhoto: Bool { arguments.contains("--import-first-photo") }
    var openFirstProject: Bool { arguments.contains("--open-first-project") || scenario == .firstProject }
    var seedPreviewProject: Bool { arguments.contains("--seed-preview-project") || scenario == .previewProject }
    var seedFirstProject: Bool { scenario == .firstProject }
    var simulateFirstProject: Bool { arguments.contains("--simulate-first-project") }
    var checkConnection: Bool { arguments.contains("--check-connection") }
    var phoneDeploy: Bool { arguments.contains("--phone-deploy") }

    private static func decodeLaunchState(_ arguments: [String]) -> AppLaunchState? {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let encoded = value(after: "--launch-state-json", in: arguments), let data = Data(base64Encoded: encoded) {
                return try decoder.decode(AppLaunchState.self, from: data)
            }
            if let path = value(after: "--launch-state", in: arguments) {
                return try decoder.decode(AppLaunchState.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            }
        } catch {
            print("Launch state decode failed: \(error.localizedDescription)")
        }
        return nil
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        arguments.indices.first { arguments[$0] == flag && arguments.indices.contains($0 + 1) }.map { arguments[$0 + 1] }
    }
}

@main
struct XToolF1App: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            LaunchModeBannerHost {
                if AppLaunchOptions.current.scenario == .editorSmoke {
                    EditorSmokeTestView()
                } else if AppLaunchOptions.current.scenario == .editorVisual {
                    EditorVisualTestView()
                } else if AppLaunchOptions.current.scenario == .canvasSmoke {
                    CanvasSmokeTestView(state: AppLaunchOptions.current.launchState)
                } else {
                    ContentView()
                        .environmentObject(model)
                }
            }
        }
    }
}

private struct LaunchModeBannerHost<Content: View>: View {
    let content: Content
    @State private var isVisible = true

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .overlay {
                if let title = LaunchModeBanner.title {
                    if isVisible {
                        ZStack {
                            LaunchModeBanner.color
                                .ignoresSafeArea()
                            Text(title)
                                .font(.system(size: 34, weight: .black, design: .monospaced))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .padding(32)
                        }
                        .transition(.opacity)
                    }
                }
            }
            .task {
                guard LaunchModeBanner.autoDismisses else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                withAnimation(.easeOut(duration: 0.2)) {
                    isVisible = false
                }
            }
    }
}

private enum LaunchModeBanner {
    static var title: String? {
        if AppLaunchOptions.current.scenario == .editorVisual {
            return "EDITOR VISUAL TEST"
        }
        if AppLaunchOptions.current.scenario == .editorSmoke {
            return "EDITOR SMOKE TEST"
        }
        if AppLaunchOptions.current.scenario == .canvasSmoke {
            return "CANVAS SMOKE TEST"
        }
        if AppLaunchOptions.current.phoneDeploy {
            return "PHONE DEPLOYMENT"
        }
        return nil
    }

    static var color: Color {
        AppLaunchOptions.current.scenario == .editorSmoke || AppLaunchOptions.current.scenario == .editorVisual || AppLaunchOptions.current.scenario == .canvasSmoke ? .orange : .green
    }

    static var autoDismisses: Bool {
        AppLaunchOptions.current.phoneDeploy
    }
}

private struct EditorVisualTestView: View {
    @State private var sourcePath: String?
    @State private var bitmaps: [PhotoBitmap] = []
    @State private var finished = false
    @State private var status = "Running editor visual test"
    private let originalData: Data
    private let staleSourcePath: String

    init() {
        let original = Self.uniformBitmap(width: 64, height: 64)
        let data = PhotoEditor.pngData(from: original) ?? Data()
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("xToolF1", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("editor-visual-source.png")
        let stale = dir.appendingPathComponent("editor-visual-stale-source.png")
        try? data.write(to: source, options: .atomic)
        try? data.write(to: stale, options: .atomic)
        originalData = data
        staleSourcePath = stale.path
        _sourcePath = State(initialValue: source.path)
    }

    var body: some View {
        PhotoEditScreen(
            photo: ProjectPhoto(name: "Editor Visual Test"),
            sourcePath: sourcePath,
            canUndo: false,
            canRedo: false,
            onCommit: { data, _, _ in commit(data) },
            onUndo: { (originalData, false, true) },
            onRedo: { (nil, false, false) },
            testMagicTap: CGPoint(x: 32, y: 32),
            testUndoAfterMagic: true,
            onBitmapChange: { bitmap in record(bitmap) }
        )
        .overlay {
            Text(status)
                .font(.headline.monospaced())
                .padding()
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func commit(_ data: Data) -> (canUndo: Bool, canRedo: Bool) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("xToolF1", isDirectory: true)
        try? data.write(to: dir.appendingPathComponent("editor-visual-committed.png"), options: .atomic)
        if let committed = try? PhotoEditor.bitmap(from: data) {
            print("Editor visual committed alpha0=\(Self.alphaZeroCount(in: committed)) greenOpaque=\(Self.greenOpaqueCount(in: committed))")
        }
        Task { @MainActor in
            sourcePath = staleSourcePath
            try? await Task.sleep(nanoseconds: 1_700_000_000)
            guard !finished else { return }
            finished = true
            do {
                try finish()
            } catch {
                fail(error)
            }
        }
        return (true, false)
    }

    private func record(_ bitmap: PhotoBitmap) {
        Task { @MainActor in
            bitmaps.append(bitmap)
        }
    }

    @MainActor private func finish() throws {
        guard let beforeBitmap = bitmaps.first, let afterBitmap = bitmaps.first(where: { Self.alphaZeroCount(in: $0) > 3500 }), let undoBitmap = bitmaps.last else {
            throw Self.testError("missing editor visual bitmaps count=\(bitmaps.count)")
        }
        let beforeSurface = try Self.renderSurfacePNG(from: beforeBitmap, revision: 1)
        let afterMagicSurface = try Self.renderSurfacePNG(from: afterBitmap, revision: 2)
        let afterUndoSurface = try Self.renderSurfacePNG(from: undoBitmap, revision: 3)
        let urls = try Self.write(before: beforeSurface, after: afterMagicSurface, undo: afterUndoSurface)
        let beforeCounts = try Self.pixelCounts(in: beforeSurface)
        let afterCounts = try Self.pixelCounts(in: afterMagicSurface)
        let undoCounts = try Self.pixelCounts(in: afterUndoSurface)
        print("Editor visual recorded bitmaps=\(bitmaps.count)")
        try Self.require(Self.greenOpaqueCount(in: beforeBitmap) > 3500, "initial editor bitmap was not green")
        try Self.require(Self.alphaZeroCount(in: afterBitmap) > 3500, "magic erase did not update current bitmap")
        try Self.require(Self.greenOpaqueCount(in: undoBitmap) > 3500, "undo did not restore current bitmap")
        try Self.require(beforeCounts.green > 3500, "before surface screenshot was not green: \(beforeCounts)")
        try Self.require(afterCounts.green < 50, "magic erase surface screenshot stayed green: \(afterCounts)")
        try Self.require(undoCounts.green > 3500, "undo surface screenshot did not return green: \(undoCounts)")
        status = "Editor visual test passed"
        print("Editor visual test passed")
        print("before=\(urls.before.path) green=\(beforeCounts.green) red=\(beforeCounts.red)")
        print("after=\(urls.after.path) green=\(afterCounts.green) red=\(afterCounts.red)")
        print("undo=\(urls.undo.path) green=\(undoCounts.green) red=\(undoCounts.red)")
        exit(0)
    }

    @MainActor private func fail(_ error: Error) {
        status = "Editor visual test failed: \(error.localizedDescription)"
        print(status)
        exit(1)
    }

    private static func uniformBitmap(width: Int, height: Int) -> PhotoBitmap {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 0
            pixels[i + 1] = 180
            pixels[i + 2] = 80
            pixels[i + 3] = 255
        }
        return PhotoBitmap(width: width, height: height, pixels: pixels)
    }

    @MainActor private static func renderSurfacePNG(from bitmap: PhotoBitmap, revision: Int) throws -> Data {
        let renderer = ImageRenderer(content:
            PhotoEditSurface(bitmap: bitmap, bitmapRevision: revision, tool: .magic, eraseRadiusPixels: 12, erasePreviewRadiusPixels: nil, rendersGestureLayer: false, onTap: { _, _ in }, onErase: { _ in })
                .frame(width: 256, height: 256)
        )
        renderer.scale = 1
        #if os(iOS)
        guard let data = renderer.uiImage?.pngData() else { throw testError("could not render editor surface") }
        return data
        #elseif os(macOS)
        guard let tiff = renderer.nsImage?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
        else { throw testError("could not render editor surface") }
        return data
        #endif
    }

    private static func write(before: Data, after: Data, undo: Data) throws -> (before: URL, after: URL, undo: URL) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("xToolF1", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let beforeURL = dir.appendingPathComponent("editor-visual-before.png")
        let afterURL = dir.appendingPathComponent("editor-visual-after.png")
        let undoURL = dir.appendingPathComponent("editor-visual-undo.png")
        try before.write(to: beforeURL, options: .atomic)
        try after.write(to: afterURL, options: .atomic)
        try undo.write(to: undoURL, options: .atomic)
        return (beforeURL, afterURL, undoURL)
    }

    private static func pixelCounts(in data: Data) throws -> (green: Int, red: Int) {
        let bitmap = try PhotoEditor.bitmap(from: data)
        var green = 0
        var red = 0
        for i in stride(from: 0, to: bitmap.pixels.count, by: 4) {
            let r = bitmap.pixels[i]
            let g = bitmap.pixels[i + 1]
            let b = bitmap.pixels[i + 2]
            let a = bitmap.pixels[i + 3]
            if a > 240 && g > 130 && r < 80 && b < 130 { green += 1 }
            if a > 240 && r > 200 && g < 80 && b < 80 { red += 1 }
        }
        return (green, red)
    }

    private static func alphaZeroCount(in bitmap: PhotoBitmap) -> Int {
        stride(from: 3, to: bitmap.pixels.count, by: 4).filter { bitmap.pixels[$0] == 0 }.count
    }

    private static func greenOpaqueCount(in bitmap: PhotoBitmap) -> Int {
        stride(from: 0, to: bitmap.pixels.count, by: 4).filter {
            bitmap.pixels[$0 + 3] > 240 && bitmap.pixels[$0 + 1] > 130 && bitmap.pixels[$0] < 80 && bitmap.pixels[$0 + 2] < 130
        }.count
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw testError(message) }
    }

    private static func testError(_ message: String) -> NSError {
        NSError(domain: "EditorVisualTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private struct CanvasSmokeTestView: View {
    @State private var photos: [ProjectPhoto]
    @State private var selectedPhotoIDs: Set<UUID>
    @State private var editing = false
    @State private var status = "Canvas smoke running"

    init(state: AppLaunchState? = nil) {
        let project = state?.storedProjects.first
        let photos = project?.photos.isEmpty == false ? project?.photos ?? [] : [Self.testObject()]
        let selected = project.flatMap { state?.selectedObjectIDs(in: $0) } ?? []
        _photos = State(initialValue: photos)
        _selectedPhotoIDs = State(initialValue: selected.isEmpty ? Set(photos.prefix(1).map(\.id)) : selected)
    }

    var body: some View {
        VStack(spacing: 12) {
            ProjectCanvasView(store: nil, photos: $photos, selectedPhotoIDs: $selectedPhotoIDs, isEditing: $editing, onDelete: delete)
                .frame(height: 360)
            Text(status)
                .font(.headline.monospaced())
        }
        .padding()
        .task { await run() }
    }

    @MainActor private func run() async {
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard let original = photos.first(where: { selectedPhotoIDs.contains($0.id) }) ?? photos.first else { return fail("missing canvas object") }
        let count = photos.count
        let pivot = original.printPlacement.absolute(rotationCenter(for: original))
        let rotated = rotatedPlacement(original.printPlacement, object: original, degrees: 44)
        guard rotatedPlacement(original.printPlacement, object: original, degrees: 725).rotationDegrees == 5 else {
            return fail("rotation degrees did not wrap by 360")
        }
        guard rotatedPlacement(original.printPlacement, object: original, degrees: -1).rotationDegrees == 359 else {
            return fail("negative rotation degrees did not wrap")
        }
        guard normalizedRotationReadoutDegrees(423) == 63, normalizedRotationReadoutDegrees(359.6) == 0 else {
            return fail("rotation readout did not wrap")
        }
        let resizeStart = PrintPlacement(xMM: 3, yMM: 4, widthMM: 80, heightMM: 40)
        let resizeDrag = Point(x: 80, y: 40)
        let resizeFactor = CanvasGeometry.resizeFactor(groupStart: resizeStart, translationMM: resizeDrag, minimum: 0.001)
        let oversized = RasterGenerator.minimumSizeConstrained(PrintPlacement(xMM: resizeStart.xMM, yMM: resizeStart.yMM, widthMM: resizeStart.widthMM * resizeFactor, heightMM: resizeStart.heightMM * resizeFactor))
        guard oversized.widthMM > RasterGenerator.workAreaMM, oversized.heightMM > 1 else {
            return fail("canvas resize stayed capped at print bed")
        }
        guard close(oversized.absolute(CanvasControlLocal.resize), Point(x: resizeStart.xMM + resizeStart.widthMM + resizeDrag.x, y: resizeStart.yMM + resizeStart.heightMM + resizeDrag.y)) else {
            return fail("canvas resize diagonal did not track drag")
        }
        let rotatedPivot = rotated.absolute(rotationCenter(for: original))
        guard hypot(pivot.x - rotatedPivot.x, pivot.y - rotatedPivot.y) < 0.0001 else {
            return fail("rotation pivot moved from \(pivot) to \(rotatedPivot)")
        }
        guard close(rotated.local(canvasControlPoint(for: rotated, local: CanvasControlLocal.resize)), CanvasControlLocal.resize) else {
            return fail("resize handle lost relative position")
        }
        guard close(rotated.local(canvasControlPoint(for: rotated, local: CanvasControlLocal.rotation)), CanvasControlLocal.rotation) else {
            return fail("rotation handle lost relative position")
        }
        let staleResize = Point(x: rotated.xMM + rotated.widthMM, y: rotated.yMM + rotated.heightMM)
        let resize = canvasControlPoint(for: rotated, local: CanvasControlLocal.resize)
        guard hypot(resize.x - staleResize.x, resize.y - staleResize.y) > 1 else {
            return fail("resize handle still uses unrotated bounds")
        }
        var settledOriginal = original
        settledOriginal.printPlacement = rotated
        let settledResize = restingObjectControlPoint(for: settledOriginal, local: CanvasControlLocal.resize)
        guard let settledBounds = selectionBounds(for: [settledOriginal]), close(settledResize, settledBounds.absolute(CanvasControlLocal.resize)) else {
            return fail("settled resize handle ignored visual bounds")
        }
        let settledDelete = restingObjectControlPoint(for: settledOriginal, local: CanvasControlLocal.delete)
        guard close(settledDelete, settledBounds.absolute(CanvasControlLocal.delete)) else {
            return fail("settled delete handle ignored visual bounds")
        }
        let activeStarts = [original.id: original.printPlacement]
        let activeResize = rotatingObjectControlPoint(for: original, local: CanvasControlLocal.resize, starts: activeStarts, groupCenter: pivot, delta: 44)
        guard close(activeResize, rotatedPoint(restingObjectControlPoint(for: original, local: CanvasControlLocal.resize), around: pivot, degrees: 44)) else {
            return fail("active resize handle did not rotate from start wrapped position")
        }
        guard hypot(activeResize.x - settledResize.x, activeResize.y - settledResize.y) > 1 else {
            return fail("active resize handle recomputed settled bounds during rotation")
        }
        let activeDelete = rotatingObjectControlPoint(for: original, local: CanvasControlLocal.delete, starts: activeStarts, groupCenter: pivot, delta: 44)
        guard close(activeDelete, rotatedPoint(restingObjectControlPoint(for: original, local: CanvasControlLocal.delete), around: pivot, degrees: 44)) else {
            return fail("active delete handle did not rotate from start wrapped position")
        }
        guard hypot(activeDelete.x - settledDelete.x, activeDelete.y - settledDelete.y) > 1 else {
            return fail("active delete handle recomputed settled bounds during rotation")
        }
        guard hypot(settledResize.x - resize.x, settledResize.y - resize.y) > 1 else {
            return fail("settled resize handle stayed on rotated local corner")
        }
        let rotatedDelete = canvasControlPoint(for: rotated, local: CanvasControlLocal.delete)
        guard hypot(settledDelete.x - rotatedDelete.x, settledDelete.y - rotatedDelete.y) > 1 else {
            return fail("settled delete handle stayed on rotated local corner")
        }
        if let other = photos.first(where: { $0.id != original.id }) {
            let objects = [original, other]
            let starts = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0.printPlacement) })
            guard let groupCenter = selectionCenter(for: objects, placements: starts), let groupStart = selectionBounds(for: objects, placements: starts) else {
                return fail("missing group rotation geometry")
            }
            let delta = 45.0
            let handleStart = groupRotationKnobPoint(groupStart: groupStart, groupCenter: groupCenter, delta: 0)
            guard close(groupRotationKnobPoint(groupStart: groupStart, groupCenter: groupCenter, delta: delta), rotatedPoint(handleStart, around: groupCenter, degrees: delta)) else {
                return fail("group rotation handle did not orbit group center")
            }
            let originalCenter = original.printPlacement.absolute(rotationCenter(for: original))
            let otherCenter = other.printPlacement.absolute(rotationCenter(for: other))
            let groupOriginal = rotatedGroupPlacement(original.printPlacement, object: original, degrees: original.printPlacement.rotationDegrees + delta, groupCenter: groupCenter, delta: delta)
            let groupOther = rotatedGroupPlacement(other.printPlacement, object: other, degrees: other.printPlacement.rotationDegrees + delta, groupCenter: groupCenter, delta: delta)
            var nextOriginal = original
            var nextOther = other
            nextOriginal.printPlacement = groupOriginal
            nextOther.printPlacement = groupOther
            let groupActiveDelete = rotatingObjectControlPoint(for: original, local: CanvasControlLocal.delete, starts: starts, groupCenter: groupCenter, delta: delta)
            guard close(groupActiveDelete, rotatedPoint(restingObjectControlPoint(for: original, local: CanvasControlLocal.delete, placements: starts), around: groupCenter, degrees: delta)) else {
                return fail("group active delete handle did not rotate from start wrapped position")
            }
            let groupSettledDelete = restingObjectControlPoint(for: nextOriginal, local: CanvasControlLocal.delete)
            guard hypot(groupActiveDelete.x - groupSettledDelete.x, groupActiveDelete.y - groupSettledDelete.y) > 1 else {
                return fail("group active delete handle recomputed settled bounds during rotation")
            }
            let nextOriginalCenter = groupOriginal.absolute(rotationCenter(for: original))
            let nextOtherCenter = groupOther.absolute(rotationCenter(for: other))
            guard close(nextOriginalCenter, rotatedPoint(originalCenter, around: groupCenter, degrees: delta)) else {
                return fail("group rotation did not move first object around group center")
            }
            guard close(nextOtherCenter, rotatedPoint(otherCenter, around: groupCenter, degrees: delta)) else {
                return fail("group rotation did not move second object around group center")
            }
            guard abs(hypot(originalCenter.x - otherCenter.x, originalCenter.y - otherCenter.y) - hypot(nextOriginalCenter.x - nextOtherCenter.x, nextOriginalCenter.y - nextOtherCenter.y)) < 0.0001 else {
                return fail("group rotation changed relative object spacing")
            }
            guard let nextGroupCenter = selectionCenter(for: [nextOriginal, nextOther]), close(nextGroupCenter, groupCenter) else {
                return fail("group rotation center drifted after rotation")
            }
        }
        photos[0].printPlacement = RasterGenerator.sizeConstrained(rotated)
        try? await Task.sleep(nanoseconds: 500_000_000)
        delete(original.id)
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard !photos.contains(where: { $0.id == original.id }), photos.count == count - 1, !selectedPhotoIDs.contains(original.id) else { return fail("delete left photos=\(photos.count) selected=\(selectedPhotoIDs.count)") }
        status = "Canvas smoke passed"
        print("Canvas smoke test passed")
        exit(0)
    }

    private func delete(_ id: UUID) {
        selectedPhotoIDs.remove(id)
        photos.removeAll { $0.id == id }
    }

    private func fail(_ message: String) {
        status = "Canvas smoke failed: \(message)"
        print(status)
        exit(1)
    }

    private func close(_ left: Point, _ right: Point) -> Bool {
        hypot(left.x - right.x, left.y - right.y) < 0.0001
    }

    private static func testObject() -> ProjectPhoto {
        let placement = PrintPlacement(xMM: 20, yMM: 28, widthMM: 52, heightMM: 34)
        let paths = [LaserPath(closed: true, points: [
            Point(x: 0.12, y: 0.18),
            Point(x: 0.92, y: 0.24),
            Point(x: 0.24, y: 0.82)
        ])]
        return ProjectPhoto(name: "Canvas Smoke Vector", mode: .vector, settings: RasterSettings(placement: placement), vectorSettings: VectorSettings(placement: placement), vectorPaths: paths)
    }
}

private struct EditorSmokeTestView: View {
    @State private var status = "Running editor smoke test"

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(status)
                .font(.title3.monospaced().bold())
                .multilineTextAlignment(.center)
        }
        .padding()
        .task {
            do {
                try EditorSmokeTest.run()
                status = "Editor smoke test passed"
                print(status)
                exit(0)
            } catch {
                status = "Editor smoke test failed: \(error.localizedDescription)"
                print(status)
                exit(1)
            }
        }
    }
}

private enum EditorSmokeTest {
    @MainActor
    static func run() throws {
        let draft = PhotoEditDraftModel()
        let original = PhotoBitmap(width: 3, height: 1, pixels: [
            100, 100, 100, 255,
            110, 100, 100, 255,
            140, 100, 100, 255
        ])
        draft.load(original)
        let originalRevision = draft.revision
        draft.previewMagic(at: CGPoint(x: 0, y: 0), fuzziness: 10, minimumBridgePixels: 0)
        try require(draft.revision > originalRevision, "magic erase preview did not advance revision")
        try require(draft.displayBitmap != nil, "magic erase preview did not create display bitmap")
        try require(draft.bitmap?.pixels[3] == 0, "magic erase preview did not erase tapped pixel")
        try require(draft.bitmap?.pixels[7] == 0, "magic erase preview did not erase fuzzy match")
        try require(draft.bitmap?.pixels[11] == 255, "magic erase preview over-erased outside threshold")
        draft.cancelPreview()
        try require(draft.bitmap?.pixels[3] == 255, "magic erase cancel did not restore preview base")
        draft.previewMagic(at: CGPoint(x: 0, y: 0), fuzziness: 10, minimumBridgePixels: 0)

        guard let originalData = PhotoEditor.pngData(from: original) else {
            throw NSError(domain: "EditorSmokeTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not encode original"])
        }
        let editedRevision = draft.revision
        _ = try requireData(draft.pngData(), "missing edited commit data")
        try require(draft.loadHistory(originalData), "undo history data did not decode")
        try require(draft.revision > editedRevision, "undo load did not advance revision")
        try require(draft.displayBitmap != nil, "undo load did not create display bitmap")
        try require(draft.bitmap?.pixels[3] == 255, "undo load did not restore tapped pixel")

        let levelsOriginal = PhotoBitmap(width: 2, height: 1, pixels: [
            50, 50, 50, 255,
            150, 150, 150, 255
        ])
        draft.load(levelsOriginal)
        let levelsRevision = draft.revision
        draft.previewLevels(boundaries: [100])
        try require(draft.revision > levelsRevision, "levels preview did not advance revision")
        try require(Array(draft.bitmap?.pixels[0...2] ?? []) == [0, 0, 0], "levels preview did not update dark bucket")
        try require(Array(draft.bitmap?.pixels[4...6] ?? []) == [255, 255, 255], "levels preview did not update light bucket")
        draft.cancelPreview()
        try require(draft.bitmap == levelsOriginal, "levels cancel did not restore preview base")

        let geometryBitmap = PhotoBitmap(width: 4, height: 2, pixels: [UInt8](repeating: 255, count: 32))
        let rect = PhotoEditGeometry.imageRect(in: CGSize(width: 400, height: 200), bitmap: geometryBitmap, zoom: 1, pan: .zero)
        try require(rect == CGRect(x: 0, y: 0, width: 400, height: 200), "editor image geometry changed unexpectedly: \(rect)")
        let centerPixel = PhotoEditGeometry.pixelPoint(CGPoint(x: 200, y: 100), in: CGSize(width: 400, height: 200), bitmap: geometryBitmap, zoom: 1, pan: .zero)
        try require(abs((centerPixel?.x ?? -1) - 1.5) < 0.001, "editor x mapping changed unexpectedly")
        try require(abs((centerPixel?.y ?? -1) - 0.5) < 0.001, "editor y mapping changed unexpectedly")
    }

    private static func requireData(_ data: Data?, _ message: String) throws -> Data {
        guard let data else {
            throw NSError(domain: "EditorSmokeTest", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return data
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw NSError(domain: "EditorSmokeTest", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

}

struct PrintProgressState: Equatable {
    var elapsedSeconds: Double
    var estimatedSeconds: Double
    var started: Bool
    var title: String

    var fraction: Double {
        min(1, max(0, elapsedSeconds / max(1, estimatedSeconds)))
    }
}

private enum MachineJobState: Equatable {
    case idle
    case checking
    case framing
    case stoppingFrame
    case preparing
    case printing(PrintProgressState?)
    case stoppingPrint(PrintProgressState?)
    case failed

    var checking: Bool {
        self == .checking
    }

    var framing: Bool {
        self == .framing || self == .stoppingFrame
    }

    var preparing: Bool {
        self == .preparing
    }

    var printing: Bool {
        switch self {
        case .printing, .stoppingPrint: true
        default: false
        }
    }

    var printProgress: PrintProgressState? {
        switch self {
        case .printing(let progress), .stoppingPrint(let progress): progress
        default: nil
        }
    }

    func title(connected: Bool) -> String {
        switch self {
        case .framing, .stoppingFrame: "previewing"
        case .printing, .stoppingPrint: "printing"
        case .preparing: "sending"
        case .checking: "connecting"
        case .idle, .failed: connected ? "machine ready" : "disconnected"
        }
    }
}

enum BasicShapeKind: String, CaseIterable, Identifiable {
    case rectangle
    case circle
    case line
    case draw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rectangle: "Rectangle"
        case .circle: "Circle"
        case .line: "Line"
        case .draw: "Draw"
        }
    }

    var icon: String {
        switch self {
        case .rectangle: "rectangle"
        case .circle: "circle"
        case .line: "line.diagonal"
        case .draw: "pencil.tip"
        }
    }
}

private extension TextureKind {
    var title: String {
        switch self {
        case .diagonal: "Diagonal"
        case .crosshatch: "Crosshatch"
        case .dots: "Dots"
        case .grid: "Grid"
        case .waves: "Waves"
        }
    }

    var icon: String {
        switch self {
        case .diagonal: "line.diagonal"
        case .crosshatch: "number"
        case .dots: "circle.grid.3x3.fill"
        case .grid: "square.grid.3x3"
        case .waves: "water.waves"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var store: FileAppStore?
    @Published var status = "Simulator mode"
    @Published private var machineState = MachineJobState.idle
    @Published var selectedProjectID: UUID?
    @Published var seededPreviewMode = false
    @Published var launchStateMode = false
    @Published var pendingEditObjectID: UUID?
    @Published var pendingSelectObjectIDs: Set<UUID> = []
    var machineEndpoint: F1MachineEndpoint?
    private var printMonitorTask: Task<Void, Never>?
    private var livePreviewSessionID = UUID()
    private var livePreviewInFlight = false
    private var livePreviewStarted = false
    private var livePreviewNeedsSend = false
    private var livePreviewLastSent = Date.distantPast
    private var livePreviewSendTask: Task<Void, Never>?
    private var livePreviewStopTask: Task<Void, Never>?
    private var livePreviewSamples: [LivePreviewSample] = []

    private struct LivePreviewSample {
        var point: Point
        var date: Date
    }

    init() {
        do {
            let launch = AppLaunchOptions.current
            if launch.resetStore {
                try? FileManager.default.removeItem(at: Self.rootURL)
            }
            store = try FileAppStore(root: Self.rootURL)
            try log("Opened app store at \(Self.rootURL.path)")
            try log("Launch scenario: \(launch.scenario.rawValue)")
            if let launchState = launch.launchState {
                try applyLaunchState(launchState)
            } else {
                if launch.openFirstProject {
                    selectedProjectID = store?.data.projects.first?.id
                }
                if launch.importFirstPhoto {
                    Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        importFirstPhoto()
                    }
                }
                if launch.seedPreviewProject {
                    seededPreviewMode = true
                    seedPreviewProject()
                }
                if launch.seedFirstProject {
                    seedFirstProject()
                }
                if launch.simulateFirstProject {
                    simulateFirstProjectWhenReady()
                }
            }
            if launch.checkConnection {
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    checkConnection()
                }
            }
        } catch {
            status = "Store failed: \(error.localizedDescription)"
        }
    }

    private func applyLaunchState(_ state: AppLaunchState) throws {
        guard let store else { return }
        launchStateMode = true
        try store.replace(projects: state.storedProjects.map(normalized), libraryAssets: state.libraryAssets ?? [])
        let selectedProject = state.selectedProject(in: store.data.projects)
        selectedProjectID = selectedProject?.id
        if let selectedProject {
            pendingSelectObjectIDs = state.selectedObjectIDs(in: selectedProject)
            pendingEditObjectID = state.editID(in: selectedProject)
        }
        try log("Applied launch state with \(store.data.projects.count) project(s)")
        objectWillChange.send()
    }

    var projects: [StoredProject] {
        store?.data.projects ?? []
    }

    var history: [PrintRecord] {
        store?.data.history ?? []
    }

    var libraryAssets: [LibraryAsset] {
        store?.data.libraryAssets ?? []
    }

    var settingPresets: [SettingPreset] {
        store?.data.settingPresets ?? []
    }

    var defaultVectorSettings: VectorSettings {
        store?.data.lastVectorSettings ?? VectorSettings()
    }

    var debugLog: [DebugLogEntry] {
        store?.data.debugLog ?? []
    }

    var recentMachineHosts: [String] {
        store?.data.recentMachineHosts ?? []
    }

    var defaultGCodeMode: RasterGCodeMode {
        get {
            UserDefaults.standard.string(forKey: Self.gcodeModeKey).flatMap(RasterGCodeMode.init(rawValue:)) ?? .asset
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.gcodeModeKey)
        }
    }

    var machineStatusTitle: String {
        machineState.title(connected: machineEndpoint != nil)
    }

    var checking: Bool {
        machineState.checking
    }

    var preparing: Bool {
        machineState.preparing
    }

    var framing: Bool {
        machineState.framing
    }

    var printing: Bool {
        machineState.printing
    }

    var printProgress: PrintProgressState? {
        machineState.printProgress
    }

    func importPhoto(_ data: Data, name: String = "Raster Photo") {
        do {
            var project = try store?.addImageProject(data: data, originalName: name)
            project?.gcodeMode = defaultGCodeMode
            if let project {
                try store?.update(project: project)
            }
            try log("Imported photo as project \(project?.id.uuidString ?? "")")
            selectedProjectID = project?.id
            objectWillChange.send()
        } catch {
            status = "Import failed"
            try? log("Import failed: \(error.localizedDescription)", level: .error)
        }
    }

    func addPhoto(_ data: Data, to project: StoredProject, name: String = "Raster Photo") -> StoredProject? {
        do {
            let updated = try store?.addPhoto(data: data, to: project.id, name: name)
            try log("Added photo to project \(project.id.uuidString)")
            objectWillChange.send()
            return updated
        } catch {
            status = "Import failed"
            try? log("Photo import failed: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    func importXCS(urls: [URL]) {
        guard let store else { return }
        let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        let summary = store.importXCSProjects(from: urls)
        if let project = summary.imported.first {
            selectedProjectID = project.id
        }
        let parts = [
            summary.imported.isEmpty ? nil : "\(summary.imported.count) imported",
            summary.skipped.isEmpty ? nil : "\(summary.skipped.count) skipped",
            summary.failures.isEmpty ? nil : "\(summary.failures.count) failed"
        ].compactMap { $0 }
        status = parts.isEmpty ? "No XCS projects imported" : "XCS import: " + parts.joined(separator: ", ")
        try? log(status)
        for failure in summary.failures {
            try? log("XCS import failed: \(failure)", level: .error)
        }
        objectWillChange.send()
    }

    func snapshot(for project: StoredProject) -> StoredProjectSnapshot {
        StoredProjectSnapshot(project: project, libraryAssets: project.photos.compactMap { store?.asset(for: $0) })
    }

    func importTextProject() {
        importObjectProject(Self.makeTextObject())
    }

    func importShapeProject(_ shape: BasicShapeKind) {
        importObjectProject(Self.makeShapeObject(shape))
    }

    func addText(to project: StoredProject) -> StoredProject? {
        add(Self.makeTextObject(), to: project)
    }

    func addShape(_ shape: BasicShapeKind, to project: StoredProject) -> StoredProject? {
        add(Self.makeShapeObject(shape), to: project)
    }

    func addShape(to project: StoredProject) -> StoredProject? {
        addShape(.rectangle, to: project)
    }

    private func importObjectProject(_ object: ProjectPhoto) {
        do {
            var project = StoredProject(name: object.name, photos: [object], gcodeMode: defaultGCodeMode, frameSpeedMMPerSecond: store?.data.lastFrameSpeedMMPerSecond ?? StoredProject.defaultFrameSpeedMMPerSecond)
            project = normalized(project)
            project = try store?.insert(project: project) ?? project
            selectedProjectID = project.id
            pendingEditObjectID = project.photos.first?.id
            objectWillChange.send()
        } catch {
            try? log("Object import failed: \(error.localizedDescription)", level: .error)
        }
    }

    private func add(_ object: ProjectPhoto, to project: StoredProject) -> StoredProject? {
        var updated = normalized(project)
        updated.photos.append(object)
        return self.update(updated, undoFrom: project.snapshot)
    }

    func saveVectorSettings(_ settings: VectorSettings) {
        do {
            try store?.saveVectorSettings(settings)
            objectWillChange.send()
        } catch {
            try? log("Vector settings save failed: \(error.localizedDescription)", level: .error)
        }
    }

    func saveFrameSpeed(_ speedMMPerSecond: Double) {
        do {
            try store?.saveFrameSpeed(speedMMPerSecond)
            objectWillChange.send()
        } catch {
            try? log("Frame speed save failed: \(error.localizedDescription)", level: .error)
        }
    }

    func importFirstPhoto() {
        #if os(iOS)
        Task {
            let authorized = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    continuation.resume(returning: status == .authorized || status == .limited)
                }
            }
            guard authorized else {
                status = "Photo access denied"
                try? log("Photo library access denied", level: .warning)
                return
            }

            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            guard let asset = PHAsset.fetchAssets(with: .image, options: options).firstObject else {
                status = "No simulator photos found"
                try? log("No photos found in library", level: .warning)
                return
            }

            let requestOptions = PHImageRequestOptions()
            requestOptions.isNetworkAccessAllowed = true
            requestOptions.deliveryMode = .highQualityFormat
            let data = await withCheckedContinuation { continuation in
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: requestOptions) { data, _, _, _ in
                    continuation.resume(returning: data)
                }
            }

            guard let data else {
                status = "Could not read simulator photo"
                try? log("Could not read first photo", level: .error)
                return
            }

            importPhoto(data, name: "Simulator Photo")
        }
        #endif
    }

    func seedPreviewProject() {
        do {
            guard let first = Self.seedImage(width: 160, height: 70), let second = Self.seedImage(width: 90, height: 110) else { return }
            var project = try store?.addImageProject(data: first, originalName: "Wide Preview")
            if let id = project?.id {
                project = try store?.addPhoto(data: second, to: id, name: "Tall Preview")
            }
            guard var project else { return }
            project.name = "Preview Check"
            if project.photos.indices.contains(0) {
                project.photos[0].settings.placement = PrintPlacement(xMM: 8, yMM: 36, widthMM: 58, heightMM: 26)
                project.photos[0].settings.dpi = 125
            }
            if project.photos.indices.contains(1) {
                project.photos[1].settings.placement = PrintPlacement(xMM: 74, yMM: 38, widthMM: 28, heightMM: 35)
                project.photos[1].settings.dpi = 125
            }
            try store?.update(project: project)
            selectedProjectID = project.id
            try log("Seeded preview verification project")
            objectWillChange.send()
        } catch {
            try? log("Preview seed failed: \(error.localizedDescription)", level: .error)
        }
    }

    func seedFirstProject() {
        do {
            guard let data = Self.seedImage(width: 96, height: 96) else { return }
            guard var project = try store?.addImageProject(data: data, originalName: "First Project") else { return }
            project.name = "First Project Check"
            project.photos[0].settings.placement = PrintPlacement(xMM: 30, yMM: 30, widthMM: 40, heightMM: 40)
            try store?.update(project: project)
            selectedProjectID = project.id
            try log("Seeded first project scenario")
            objectWillChange.send()
        } catch {
            try? log("First project seed failed: \(error.localizedDescription)", level: .error)
        }
    }

    func normalized(_ project: StoredProject) -> StoredProject {
        var saved = project
        saved.frameSpeedMMPerSecond = min(FrameGCodeGenerator.maximumFrameSpeedMMPerSecond, max(1, saved.frameSpeedMMPerSecond))
        for index in saved.photos.indices {
            saved.photos[index].passes = min(ProjectPhoto.maximumPasses, max(1, saved.photos[index].passes))
            saved.photos[index].printPlacement = RasterGenerator.minimumSizeConstrained(saved.photos[index].printPlacement)
            saved.photos[index].settings.widthMM = saved.photos[index].settings.placement.widthMM
            saved.photos[index].settings.heightMM = saved.photos[index].settings.placement.heightMM
            saved.photos[index].settings.lineSpacingMM = 25.4 / max(1, saved.photos[index].settings.dpi)
            saved.photos[index].settings.minPowerPercent = min(100, max(0, saved.photos[index].settings.minPowerPercent))
            saved.photos[index].settings.maxPowerPercent = min(100, max(saved.photos[index].settings.minPowerPercent, saved.photos[index].settings.maxPowerPercent))
            saved.photos[index].settings.dropPowerThresholdPercent = min(100, max(0, saved.photos[index].settings.dropPowerThresholdPercent))
            if saved.photos[index].mode == .vector || saved.photos[index].mode == .text {
                var vector = saved.photos[index].resolvedVectorSettings
                vector.placement = saved.photos[index].printPlacement
                vector.speedMMPerSecond = min(400, max(1, vector.speedMMPerSecond))
                vector.powerPercent = min(100, max(0, vector.powerPercent))
                saved.photos[index].vectorSettings = vector
                saved.photos[index].settings.placement = vector.placement
                if saved.photos[index].mode == .text {
                    saved.photos[index].vectorPaths = TextVectorGenerator.paths(for: saved.photos[index].resolvedTextSettings, placement: saved.photos[index].printPlacement)
                }
            }
        }
        return saved
    }

    @discardableResult
    func update(_ project: StoredProject, undoFrom: StoredProjectSnapshot? = nil) -> StoredProject? {
        do {
            var saved = normalized(project)
            if let undoFrom, undoFrom != snapshot(for: saved) {
                saved.undoHistory.append(undoFrom)
                saved.redoHistory.removeAll()
            }
            try store?.update(project: saved)
            objectWillChange.send()
            return saved
        } catch {
            try? log("Update failed: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    func renameProject(_ project: StoredProject, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try store?.renameProject(id: project.id, to: name)
            objectWillChange.send()
        } catch {
            try? log("Rename failed: \(error.localizedDescription)", level: .error)
        }
    }

    func applyPreset(_ preset: SettingPreset, to photoID: UUID, in project: inout StoredProject) {
        guard let index = project.photos.firstIndex(where: { $0.id == photoID }) else { return }
        project.photos[index].settings = preset.settings
        project.photos[index].settingsName = preset.name
        try? store?.selectPreset(id: preset.id)
        objectWillChange.send()
    }

    func savePreset(name: String, settings: RasterSettings) -> SettingPreset? {
        do {
            let preset = try store?.savePreset(name: name, settings: settings)
            objectWillChange.send()
            return preset
        } catch {
            try? log("Preset save failed: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    func updatePreset(id: UUID, settings: RasterSettings) {
        do {
            try store?.updatePreset(id: id, settings: settings)
            objectWillChange.send()
        } catch {
            try? log("Preset update failed: \(error.localizedDescription)", level: .error)
        }
    }

    func deleteProject(_ project: StoredProject) {
        do {
            try store?.deleteProject(id: project.id)
            if selectedProjectID == project.id {
                selectedProjectID = nil
            }
            objectWillChange.send()
        } catch {
            try? log("Delete failed: \(error.localizedDescription)", level: .error)
        }
    }

    func deleteUnusedAsset(_ asset: LibraryAsset) {
        do {
            try store?.deleteUnusedAsset(id: asset.id)
            objectWillChange.send()
        } catch {
            try? log("Asset delete failed: \(error.localizedDescription)", level: .error)
        }
    }

    func deleteUnusedAssets(ids: Set<UUID>) {
        do {
            let deleted = try store?.deleteUnusedAssets(ids: Array(ids)) ?? 0
            status = deleted == 1 ? "Deleted 1 unused asset" : "Deleted \(deleted) unused assets"
            try? log(status)
            objectWillChange.send()
        } catch {
            try? log("Batch asset delete failed: \(error.localizedDescription)", level: .error)
        }
    }

    func undoAsset(for photo: ProjectPhoto) -> Data? {
        do {
            guard let store, let id = photo.assetID, let asset = try store.undoAsset(id: id) else { return nil }
            objectWillChange.send()
            return try? Data(contentsOf: store.absoluteURL(for: asset.imagePath))
        } catch {
            try? log("Asset undo failed: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    func redoAsset(for photo: ProjectPhoto) -> Data? {
        do {
            guard let store, let id = photo.assetID, let asset = try store.redoAsset(id: id) else { return nil }
            objectWillChange.send()
            return try? Data(contentsOf: store.absoluteURL(for: asset.imagePath))
        } catch {
            try? log("Asset redo failed: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    func commitObjectAsset(_ photo: inout ProjectPhoto, projectID: UUID) -> (canUndo: Bool, canRedo: Bool) {
        do {
            guard let asset = try store?.commitObjectAsset(for: &photo, projectID: projectID) else { return (false, false) }
            objectWillChange.send()
            return (!asset.undoHistory.isEmpty, !asset.redoHistory.isEmpty)
        } catch {
            try? log("Object history save failed: \(error.localizedDescription)", level: .error)
            return objectAssetHistory(for: photo)
        }
    }

    func undoObjectAsset(for photo: ProjectPhoto) -> ProjectPhoto? {
        do {
            guard let store, let id = photo.assetID, let asset = try store.undoAsset(id: id) else { return nil }
            objectWillChange.send()
            return objectPhoto(photo, from: asset)
        } catch {
            try? log("Object undo failed: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    func redoObjectAsset(for photo: ProjectPhoto) -> ProjectPhoto? {
        do {
            guard let store, let id = photo.assetID, let asset = try store.redoAsset(id: id) else { return nil }
            objectWillChange.send()
            return objectPhoto(photo, from: asset)
        } catch {
            try? log("Object redo failed: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    func objectAssetHistory(for photo: ProjectPhoto) -> (canUndo: Bool, canRedo: Bool) {
        guard let asset = store?.asset(for: photo) else { return (false, false) }
        return (!asset.undoHistory.isEmpty, !asset.redoHistory.isEmpty)
    }

    private func objectPhoto(_ photo: ProjectPhoto, from asset: LibraryAsset) -> ProjectPhoto {
        var restored = photo
        restored.assetID = asset.id
        restored.name = asset.originalName
        restored.mode = asset.kind == .text ? .text : .vector
        restored.vectorPaths = asset.vectorPaths
        restored.vectorSettings = asset.vectorSettings
        restored.vectorDrawing = asset.vectorDrawing
        restored.textSettings = asset.textSettings
        if let placement = asset.vectorSettings?.placement {
            restored.printPlacement = placement
        }
        return restored
    }

    @discardableResult
    func undo(_ project: StoredProject) -> StoredProject? {
        do {
            var saved = normalized(project)
            guard let snapshot = saved.undoHistory.popLast() else { return nil }
            saved.redoHistory.append(self.snapshot(for: saved))
            snapshot.restore(on: &saved)
            try store?.restoreAssets(snapshot.libraryAssets)
            saved = normalized(saved)
            try store?.update(project: saved)
            objectWillChange.send()
            return saved
        } catch {
            try? log("Undo failed: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    @discardableResult
    func redo(_ project: StoredProject) -> StoredProject? {
        do {
            var saved = normalized(project)
            guard let snapshot = saved.redoHistory.popLast() else { return nil }
            saved.undoHistory.append(self.snapshot(for: saved))
            snapshot.restore(on: &saved)
            try store?.restoreAssets(snapshot.libraryAssets)
            saved = normalized(saved)
            try store?.update(project: saved)
            objectWillChange.send()
            return saved
        } catch {
            try? log("Redo failed: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    @discardableResult
    func commitPhotoEdit(_ imageData: Data, photoID: UUID, in project: StoredProject, editKind: String, values: [String: Double], undoFrom: StoredProjectSnapshot) -> StoredProject? {
        do {
            guard let store, let index = project.photos.firstIndex(where: { $0.id == photoID }) else { return nil }
            var updated = project
            let asset = try store.makeDerivedAsset(data: imageData, from: updated.photos[index], projectID: project.id, editKind: editKind, values: values)
            updated.photos[index].assetID = asset.id
            updated.photos[index].legacySourceImagePath = nil
            try log("Edited photo \(photoID.uuidString) with \(editKind)")
            return self.update(updated, undoFrom: undoFrom)
        } catch {
            status = "Edit failed"
            try? log("Photo edit failed: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    func simulatePrint(_ project: StoredProject) {
        do {
            guard let store else { return }
            let package = try printPackage(for: project)
            try store.writeGenerated(projectID: project.id, text: package.gcode, preview: package.preview)
            try store.add(record: PrintRecord(projectID: project.id, projectName: project.name, photoCount: package.photoCount, generatedLines: Self.lineCount(in: package.gcode), generatedBytes: package.gcode.utf8.count))
            try log("Simulated print for \(project.name): \(package.photoCount) objects, \(package.gcode.utf8.count) bytes")
            status = "Simulated print complete"
            objectWillChange.send()
        } catch {
            status = "Print failed"
            try? log("Print simulation failed: \(error.localizedDescription)", level: .error)
        }
    }

    func startFrame(_ project: StoredProject) {
        let cachedEndpoint = machineEndpoint
        let preferredHosts = recentMachineHosts
        let gcode: String
        do {
            gcode = try frameGCode(for: project)
        } catch {
            machineState = .failed
            status = "Frame failed"
            try? log("Frame generation failed: \(error.localizedDescription)", level: .error)
            return
        }
        machineState = .framing
        status = "Starting frame..."
        Task.detached {
            do {
                let endpoint = try cachedEndpoint ?? F1Discovery().discover(preferredHosts: preferredHosts)
                try F1FramingClient(host: endpoint.host, port: endpoint.httpPort).startFrame(gcode: gcode)
                await MainActor.run {
                    self.machineEndpoint = endpoint
                    try? self.store?.recordMachineHost(endpoint.host)
                    self.status = "Framing project outline"
                    try? self.log("Started frame on F1 at \(endpoint.host):\(endpoint.httpPort)")
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self.machineState = .failed
                    self.status = "Frame failed"
                    try? self.log("Frame failed: \(message)", level: .error)
                }
            }
        }
    }

    func stopFrame() {
        let cachedEndpoint = machineEndpoint
        let preferredHosts = recentMachineHosts
        machineState = .stoppingFrame
        status = "Stopping frame..."
        Task.detached {
            do {
                let endpoint = try cachedEndpoint ?? F1Discovery().discover(preferredHosts: preferredHosts)
                try F1FramingClient(host: endpoint.host, port: endpoint.httpPort).stop()
                await MainActor.run {
                    self.machineState = .idle
                    self.machineEndpoint = endpoint
                    try? self.store?.recordMachineHost(endpoint.host)
                    self.status = "Frame stopped"
                    try? self.log("Stopped frame on F1 at \(endpoint.host):\(endpoint.httpPort)")
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self.machineState = .failed
                    self.status = "Stop frame failed"
                    try? self.log("Stop frame failed: \(message)", level: .error)
                }
            }
        }
    }

    func stopPrint() {
        let cachedEndpoint = machineEndpoint
        let preferredHosts = recentMachineHosts
        machineState = .stoppingPrint(printProgress)
        status = "Stopping print..."
        Task.detached {
            do {
                let endpoint = try cachedEndpoint ?? F1Discovery().discover(preferredHosts: preferredHosts)
                try F1FramingClient(host: endpoint.host, port: endpoint.httpPort).stop()
                await MainActor.run {
                    self.machineState = .idle
                    self.printMonitorTask?.cancel()
                    self.printMonitorTask = nil
                    self.machineEndpoint = endpoint
                    try? self.store?.recordMachineHost(endpoint.host)
                    self.status = "Print stopped"
                    try? self.log("Stopped print on F1 at \(endpoint.host):\(endpoint.httpPort)")
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self.machineState = .failed
                    self.status = "Stop print failed"
                    try? self.log("Stop print failed: \(message)", level: .error)
                }
            }
        }
    }

    func previewLaser(at point: Point) {
        guard !preparing, !printing else { return }
        livePreviewStopTask?.cancel()
        livePreviewStopTask = nil
        appendLivePreviewPoint(point)
        if !livePreviewStarted {
            guard !livePreviewInFlight else {
                livePreviewNeedsSend = true
                return
            }
            sendLivePreview(replacing: false)
        } else {
            scheduleLivePreviewReplace()
        }
    }

    private func appendLivePreviewPoint(_ point: Point, now: Date = Date()) {
        pruneLivePreviewSamples(now: now)
        if let last = livePreviewSamples.last, hypot(last.point.x - point.x, last.point.y - point.y) < 0.1 {
            livePreviewSamples[livePreviewSamples.count - 1] = LivePreviewSample(point: point, date: now)
        } else {
            livePreviewSamples.append(LivePreviewSample(point: point, date: now))
        }
        pruneLivePreviewSamples(now: now)
    }

    private func pruneLivePreviewSamples(now: Date = Date()) {
        livePreviewSamples.removeAll { now.timeIntervalSince($0.date) > 1.5 }
    }

    private var livePreviewPoints: [Point] {
        pruneLivePreviewSamples()
        return livePreviewSamples.map(\.point)
    }

    private func scheduleLivePreviewReplace() {
        guard livePreviewStarted else {
            livePreviewNeedsSend = true
            return
        }
        livePreviewNeedsSend = true
        guard livePreviewSendTask == nil else { return }
        let delay = max(0, 0.08 - Date().timeIntervalSince(livePreviewLastSent))
        livePreviewSendTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await MainActor.run {
                self?.livePreviewSendTask = nil
                self?.flushLivePreviewReplace()
            }
        }
    }

    private func flushLivePreviewReplace() {
        guard livePreviewNeedsSend else { return }
        sendLivePreview(replacing: true)
    }

    private func sendLivePreview(replacing: Bool) {
        let points = livePreviewPoints
        guard !points.isEmpty else { return }
        livePreviewNeedsSend = false
        livePreviewLastSent = Date()
        let sessionID = livePreviewSessionID
        let cachedEndpoint = machineEndpoint
        let preferredHosts = recentMachineHosts
        if replacing {
            guard let cachedEndpoint else {
                livePreviewStarted = false
                sendLivePreview(replacing: false)
                return
            }
            Task.detached {
                F1FramingClient(host: cachedEndpoint.host, port: cachedEndpoint.httpPort).replaceFrameFast(gcode: LivePreviewGCodeGenerator.makeGCode(path: points))
            }
            return
        }

        machineState = .framing
        status = "Drawing preview"
        livePreviewInFlight = true
        Task.detached {
            do {
                let endpoint = try cachedEndpoint ?? F1Discovery().discover(preferredHosts: preferredHosts)
                let client = F1FramingClient(host: endpoint.host, port: endpoint.httpPort)
                try client.startFrame(gcode: LivePreviewGCodeGenerator.makeGCode(path: points), timeout: 2)
                await MainActor.run {
                    guard sessionID == self.livePreviewSessionID else { return }
                    self.livePreviewInFlight = false
                    self.livePreviewStarted = true
                    self.machineEndpoint = endpoint
                    if self.livePreviewNeedsSend {
                        self.scheduleLivePreviewReplace()
                    }
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    guard sessionID == self.livePreviewSessionID else { return }
                    self.livePreviewInFlight = false
                    self.resetLivePreviewSession()
                    self.machineState = .failed
                    self.status = "Preview failed"
                    try? self.log("Live preview failed: \(message)", level: .error)
                }
            }
        }
    }

    func finishLivePreviewGesture() {
        livePreviewStopTask?.cancel()
        livePreviewStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                self?.stopLivePreview()
            }
        }
    }

    func stopLivePreview() {
        resetLivePreviewSession()
        if framing {
            stopFrame()
        }
    }

    private func resetLivePreviewSession() {
        livePreviewSessionID = UUID()
        livePreviewInFlight = false
        livePreviewStarted = false
        livePreviewNeedsSend = false
        livePreviewSendTask?.cancel()
        livePreviewSendTask = nil
        livePreviewStopTask?.cancel()
        livePreviewStopTask = nil
        livePreviewSamples.removeAll()
    }

    func preparePrint(_ project: StoredProject) {
        do {
            guard let store else { throw AppError.noStore }
            let package = try printPackage(for: project)
            let cachedEndpoint = machineEndpoint
            let preferredHosts = recentMachineHosts
            let taskID = UUID().uuidString
            let projectID = project.id
            try store.writeGenerated(projectID: project.id, text: package.gcode, preview: package.preview)
            machineState = .preparing
            printMonitorTask?.cancel()
            status = "Sending to F1..."
            try log("Uploading \(package.name): \(package.gcode.utf8.count) bytes, task \(taskID)")

            Task.detached {
                do {
                    let endpoint = try cachedEndpoint ?? F1Discovery().discover(preferredHosts: preferredHosts)
                    let client = F1FramingClient(host: endpoint.host, port: endpoint.httpPort)
                    try client.connect()
                    try client.uploadProcessing(package.gcode, taskID: taskID)
                    var lastStatus: F1ProcessingStatus?
                    for _ in 0..<6 {
                        lastStatus = try? client.status()
                        if lastStatus?.ready == true { break }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    await MainActor.run {
                        self.machineState = .printing(nil)
                        self.machineEndpoint = endpoint
                        try? self.store?.recordMachineHost(endpoint.host)
                        try? self.store?.add(record: PrintRecord(projectID: projectID, projectName: package.name, photoCount: package.photoCount, generatedLines: Self.lineCount(in: package.gcode), generatedBytes: package.gcode.utf8.count))
                        self.startPrintMonitor(endpoint: endpoint, estimatedSeconds: package.estimatedDurationSeconds, ready: lastStatus?.ready == true || lastStatus?.idle == true, name: package.name)
                        if lastStatus?.ready == true {
                            self.status = "Ready on F1 - press side button"
                            try? self.log("F1 ready for \(package.name)")
                        } else {
                            self.status = "Uploaded - check F1"
                            try? self.log("Upload finished, status unclear: \(lastStatus?.raw ?? "no status")", level: .warning)
                        }
                        self.objectWillChange.send()
                    }
                } catch {
                    let message = error.localizedDescription
                    await MainActor.run {
                        self.machineState = .failed
                        self.status = "Upload failed"
                        try? self.log("Upload failed: \(message)", level: .error)
                    }
                }
            }
        } catch {
            machineState = .failed
            status = "Print failed"
            try? log("Print failed: \(error.localizedDescription)", level: .error)
        }
    }

    func prepareTilePrint(_ project: StoredProject, photoID: UUID, step: TileStep, finalWidthMM: Double, finalHeightMM: Double) {
        do {
            guard let store else { throw AppError.noStore }
            guard let photo = project.photos.first(where: { $0.id == photoID && $0.mode == .raster }), let url = store.imageURL(for: photo) else { throw AppError.noStore }
            let data = try Data(contentsOf: url)
            var tilePhoto = photo
            tilePhoto.id = UUID()
            tilePhoto.name = "\(step.title) \(photo.name)"
            tilePhoto.settings.placement = PrintPlacement(xMM: 0, yMM: 0, widthMM: step.widthMM, heightMM: step.heightMM)
            tilePhoto.settings.widthMM = step.widthMM
            tilePhoto.settings.heightMM = step.heightMM
            let raster = try TilePlanGenerator.raster(from: data, baseSettings: photo.settings, step: step, finalWidthMM: finalWidthMM, finalHeightMM: finalHeightMM)
            let gcode = PrintGCodeGenerator.makeGCode(for: [tilePhoto], rasters: [tilePhoto.id: raster], mode: .asset)
            let preview = PrintGCodeGenerator.preview(for: [tilePhoto], rasters: [tilePhoto.id: raster], mode: .asset)
            let package = PrintPackage(name: "\(project.name) \(step.title)", gcode: gcode, preview: RasterGenerator.pngPreview(from: preview), photoCount: 1, estimatedDurationSeconds: preview.estimatedDurationSeconds)
            let cachedEndpoint = machineEndpoint
            let preferredHosts = recentMachineHosts
            let taskID = UUID().uuidString
            let projectID = project.id
            try store.writeGenerated(projectID: project.id, text: package.gcode, preview: package.preview)
            machineState = .preparing
            printMonitorTask?.cancel()
            status = "Sending \(step.title)..."
            try log("Uploading \(package.name): \(package.gcode.utf8.count) bytes, task \(taskID)")

            Task.detached {
                do {
                    let endpoint = try cachedEndpoint ?? F1Discovery().discover(preferredHosts: preferredHosts)
                    let client = F1FramingClient(host: endpoint.host, port: endpoint.httpPort)
                    try client.connect()
                    try client.uploadProcessing(package.gcode, taskID: taskID)
                    let ready = (try? client.status())?.ready == true
                    await MainActor.run {
                        self.machineState = .printing(nil)
                        self.machineEndpoint = endpoint
                        try? self.store?.recordMachineHost(endpoint.host)
                        try? self.store?.add(record: PrintRecord(projectID: projectID, projectName: package.name, photoCount: package.photoCount, generatedLines: Self.lineCount(in: package.gcode), generatedBytes: package.gcode.utf8.count))
                        self.startPrintMonitor(endpoint: endpoint, estimatedSeconds: package.estimatedDurationSeconds, ready: ready, name: package.name)
                        self.status = ready ? "Ready on F1 - press side button" : "Uploaded - check F1"
                        self.objectWillChange.send()
                    }
                } catch {
                    let message = error.localizedDescription
                    await MainActor.run {
                        self.machineState = .failed
                        self.status = "Tile upload failed"
                        try? self.log("Tile upload failed: \(message)", level: .error)
                    }
                }
            }
        } catch {
            machineState = .failed
            status = "Tile print failed"
            try? log("Tile print failed: \(error.localizedDescription)", level: .error)
        }
    }

    private func startPrintMonitor(endpoint: F1MachineEndpoint, estimatedSeconds: Double, ready: Bool, name: String) {
        let estimate = max(1, estimatedSeconds)
        machineState = .printing(PrintProgressState(elapsedSeconds: 0, estimatedSeconds: estimate, started: !ready, title: ready ? "Waiting for side button" : "Printing"))
        printMonitorTask?.cancel()
        printMonitorTask = Task.detached {
            let client = F1FramingClient(host: endpoint.host, port: endpoint.httpPort)
            var startedAt: Date? = ready ? nil : Date()
            var sawReady = ready

            while !Task.isCancelled {
                let now = Date()
                let deviceStatus = try? client.status()
                if deviceStatus?.ready == true {
                    sawReady = true
                }
                if startedAt == nil, let deviceStatus, deviceStatus.working || (sawReady && !deviceStatus.ready && !deviceStatus.idle && !deviceStatus.finished && !deviceStatus.stopped) {
                    startedAt = now
                }

                let elapsed = startedAt.map { now.timeIntervalSince($0) } ?? 0
                let estimatedComplete = startedAt != nil && elapsed >= estimate
                let done = deviceStatus?.finished == true || deviceStatus?.stopped == true || (startedAt != nil && deviceStatus?.idle == true) || estimatedComplete
                let title = startedAt == nil ? "Waiting for side button" : "Printing"
                let completeStatus = deviceStatus?.stopped == true ? "Print stopped" : (estimatedComplete ? "Print complete (estimated)" : "Print finished")

                let shouldStop = await MainActor.run { () -> Bool in
                    guard self.printing else { return true }
                    if done {
                        self.machineState = .idle
                        self.printMonitorTask = nil
                        self.status = completeStatus
                        try? self.log("\(completeStatus) for \(name)")
                        return true
                    }
                    if case .stoppingPrint = self.machineState {
                        return false
                    }
                    self.machineState = .printing(PrintProgressState(elapsedSeconds: elapsed, estimatedSeconds: estimate, started: startedAt != nil, title: title))
                    return false
                }
                if shouldStop { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func simulateFirstProjectWhenReady() {
        Task {
            for _ in 0..<10 {
                if let project = projects.first {
                    selectedProjectID = project.id
                    simulatePrint(project)
                    return
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            try? log("No project available for launch simulation", level: .warning)
        }
    }

    func raster(for photo: ProjectPhoto) throws -> RasterOutput {
        guard let url = store?.imageURL(for: photo) else { throw AppError.noStore }
        let data = try Data(contentsOf: url)
        return try RasterGenerator.makeRaster(from: data, settings: photo.settings)
    }

    func frameGCode(for project: StoredProject) throws -> String {
        guard let store else { throw AppError.noStore }
        var rasterData: [UUID: Data] = [:]
        for photo in project.photos where photo.isEnabled && photo.mode == .raster {
            guard let url = store.imageURL(for: photo) else { throw AppError.noStore }
            rasterData[photo.id] = try Data(contentsOf: url)
        }
        return FrameGCodeGenerator.makeGCode(for: project, rasterData: rasterData)
    }

    nonisolated static func lineCount(in text: String) -> Int {
        text.isEmpty ? 0 : text.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
    }

    nonisolated static func printPreview(for photos: [ProjectPhoto], root: URL, assets: [LibraryAsset], mode: RasterGCodeMode) -> GCodePreview? {
        try? {
            let rasterPhotos = photos.filter { $0.isEnabled && $0.mode == .raster }
            let outputs = try rasterPhotos.map { photo in
                let path = photo.assetID.flatMap { id in assets.first { $0.id == id }?.imagePath } ?? photo.legacySourceImagePath
                let data = try Data(contentsOf: root.appendingPathComponent(path ?? ""))
                return try RasterGenerator.makeRaster(from: data, settings: photo.settings)
            }
            return PrintGCodeGenerator.preview(for: photos, rasters: Dictionary(uniqueKeysWithValues: zip(rasterPhotos.map(\.id), outputs)), mode: mode)
        }()
    }

    private func printPackage(for project: StoredProject) throws -> PrintPackage {
        let rasterPhotos = project.photos.filter { $0.isEnabled && $0.mode == .raster }
        let outputs = try rasterPhotos.map { try raster(for: $0) }
        let rasters = Dictionary(uniqueKeysWithValues: zip(rasterPhotos.map(\.id), outputs))
        let gcode = PrintGCodeGenerator.makeGCode(for: project.photos, rasters: rasters, mode: project.gcodeMode)
        let preview = PrintGCodeGenerator.preview(for: project.photos, rasters: rasters, mode: project.gcodeMode)
        return PrintPackage(name: project.name, gcode: gcode, preview: RasterGenerator.pngPreview(from: preview), photoCount: PrintGCodeGenerator.printableObjectCount(project.photos), estimatedDurationSeconds: preview.estimatedDurationSeconds)
    }

    func checkConnection() {
        let preferredHosts = recentMachineHosts
        machineState = .checking
        status = "Finding xTool F1..."
        try? log("Discovering xTool F1 on current Wi-Fi")
        Task.detached {
            let result = Result {
                let endpoint = try F1Discovery().discover(preferredHosts: preferredHosts)
                try F1FramingClient(host: endpoint.host, port: endpoint.httpPort).connect()
                return endpoint
            }
            await MainActor.run {
                switch result {
                case .success(let endpoint):
                    self.machineState = .idle
                    self.machineEndpoint = endpoint
                    try? self.store?.recordMachineHost(endpoint.host)
                    self.status = "Connected to F1 at \(endpoint.host):\(endpoint.httpPort)"
                    try? self.log("Connected to F1 at \(endpoint.host):\(endpoint.httpPort)")
                case .failure(let error):
                    self.machineState = .failed
                    self.status = "Not connected: \(error.localizedDescription)"
                    try? self.log("Discovery failed: \(error.localizedDescription)", level: .warning)
                }
            }
        }
    }

    func log(_ message: String, level: DebugLogLevel = .info) throws {
        try store?.log(message, level: level)
    }

    func clearLog() {
        try? store?.clearLog()
        objectWillChange.send()
    }

    private static var rootURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("xToolF1")
    }

    private static let gcodeModeKey = "defaultGCodeMode"

    private static func seedImage(width: Int, height: Int) -> Data? {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let horizontal = x * 90 / max(1, width - 1)
                let vertical = y * 80 / max(1, height - 1)
                let value = UInt8(max(0, min(255, 235 - horizontal - vertical)))
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255
            }
        }
        return PhotoEditor.pngData(from: PhotoBitmap(width: width, height: height, pixels: pixels))
    }

    private static func makeTextObject() -> ProjectPhoto {
        let placement = PrintPlacement(xMM: 37.5, yMM: 47.5, widthMM: 40, heightMM: 20)
        let text = TextSettings()
        return ProjectPhoto(name: text.text, mode: .text, settingsName: "Cut", settings: RasterSettings(placement: placement), vectorSettings: VectorSettings(placement: placement), vectorPaths: TextVectorGenerator.paths(for: text, placement: placement), textSettings: text)
    }

    private static func makeShapeObject(_ shape: BasicShapeKind) -> ProjectPhoto {
        let placement = PrintPlacement(xMM: 37.5, yMM: 37.5, widthMM: 40, heightMM: 40)
        let paths: [LaserPath]
        switch shape {
        case .rectangle:
            paths = [unitRectanglePath]
        case .circle:
            paths = [unitCirclePath]
        case .line:
            paths = [LaserPath(closed: false, points: [Point(x: 0, y: 0), Point(x: 1, y: 1)])]
        case .draw:
            paths = []
        }
        return ProjectPhoto(name: shape.title, mode: .vector, settingsName: "Cut", settings: RasterSettings(placement: placement), vectorSettings: VectorSettings(placement: placement), vectorPaths: paths, vectorDrawing: shape == .draw ? EditableVectorDrawing() : nil)
    }

    private static let unitRectanglePath = LaserPath(closed: true, points: [
        Point(x: 0, y: 0),
        Point(x: 1, y: 0),
        Point(x: 1, y: 1),
        Point(x: 0, y: 1)
    ])

    private static let unitCirclePath = LaserPath(closed: true, points: stride(from: 0, to: 32, by: 1).map {
        let angle = Double($0) * .pi * 2 / 32
        return Point(x: 0.5 + 0.5 * cos(angle), y: 0.5 + 0.5 * sin(angle))
    })

    private struct PrintPackage: Sendable {
        var name: String
        var gcode: String
        var preview: Data?
        var photoCount: Int
        var estimatedDurationSeconds: Double
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var photo: PhotosPickerItem?
    @State private var renamingProject: StoredProject?
    @State private var renameText = ""

    private var selectedProject: StoredProject? {
        model.selectedProjectID.flatMap { id in model.projects.first { $0.id == id } }
    }

    var body: some View {
        content
            .onOpenURL { model.importXCS(urls: [$0]) }
    }

    @ViewBuilder private var content: some View {
        if model.seededPreviewMode {
            SeededPreviewScreen(project: selectedProject)
        } else if let selectedProject {
            NavigationStack {
                ProjectDetailView(project: selectedProject) {
                    model.selectedProjectID = nil
                }
            }
        } else {
            projectTabs
        }
    }

    private var projectTabs: some View {
        TabView {
            NavigationStack {
                List {
                    Section {
                        if !model.seededPreviewMode {
                            if !model.launchStateMode {
                                PhotosPicker(selection: $photo, matching: .images) {
                                    Label("Photo", systemImage: "photo.badge.plus")
                                }
                                .accessibilityIdentifier("add.photo.picker")
                            }
                            Button {
                                model.importTextProject()
                            } label: {
                                Label("Text", systemImage: "textformat")
                            }
                            .accessibilityIdentifier("add.text")
                            Menu {
                                ForEach(BasicShapeKind.allCases) { shape in
                                    Button {
                                        model.importShapeProject(shape)
                                    } label: {
                                        Label(shape.title, systemImage: shape.icon)
                                    }
                                }
                            } label: {
                                Label("Shape", systemImage: "square.on.circle")
                            }
                            .accessibilityIdentifier("add.shape")
                        }
                    }

                    Section("Projects") {
                        if model.projects.isEmpty {
                            Text("No projects")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.projects) { project in
                            Button {
                                model.selectedProjectID = project.id
                            } label: {
                                HStack(spacing: 12) {
                                    if let first = project.photos.first {
                                        ObjectThumbnail(photo: first, path: model.store?.imageURL(for: first)?.path, size: 48, selected: false)
                                    } else {
                                        AssetThumbnail(path: nil, size: 48, selected: false)
                                    }
                                    VStack(alignment: .leading) {
                                        Text(project.name)
                                            .lineLimit(1)
                                        Text("\(project.photos.count) photo\(project.photos.count == 1 ? "" : "s") · \(project.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("project.row.\(project.id.uuidString)")
                            .contextMenu {
                                Button("Rename") {
                                    renamingProject = project
                                    renameText = project.name
                                }
                                Button(role: .destructive) {
                                    model.deleteProject(project)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    model.deleteProject(project)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .navigationTitle("")
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text(model.machineStatusTitle)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        MachineStatusButton()
                    }
                }
            }
            .tabItem { Label("Projects", systemImage: "list.bullet") }

            MachineView()
                .tabItem { Label("Machine", systemImage: "dot.viewfinder") }

            LibraryView()
                .tabItem { Label("Library", systemImage: "photo.stack") }

            HistoryView()
                .tabItem { Label("History", systemImage: "clock") }

            DebugLogView()
                .tabItem { Label("Log", systemImage: "doc.text") }
        }
        .onChange(of: photo) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await MainActor.run { model.importPhoto(data) }
                }
            }
        }
        .alert("Rename Project", isPresented: Binding(get: { renamingProject != nil }, set: { if !$0 { renamingProject = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingProject = nil }
            Button("Rename") {
                if let project = renamingProject {
                    model.renameProject(project, to: renameText)
                }
                renamingProject = nil
            }
        }
        .solidTabBar()
    }
}

private struct SeededPreviewScreen: View {
    @EnvironmentObject private var model: AppModel
    var project: StoredProject?
    @State private var preview: GCodePreview?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(project?.name ?? "Preview Check")
                .font(.largeTitle.bold())
            Text("Sequential · \(project?.photos.count ?? 0) objects · 115 x 115 mm")
                .foregroundStyle(.secondary)
            ProjectPrintPreviewView(preview: preview)
            Spacer()
        }
        .padding(20)
        .task(id: project?.id) {
            guard let project, let store = model.store else { return }
            preview = AppModel.printPreview(for: project.photos, root: store.root, assets: store.data.libraryAssets, mode: project.gcodeMode)
        }
    }
}

struct MachineStatusButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            model.checkConnection()
        } label: {
            ZStack(alignment: .bottomTrailing) {
                F1MachineIcon(connected: model.machineEndpoint != nil)
                    .frame(width: 34, height: 34)
                if model.checking {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 16, height: 16)
                        .background(.thinMaterial)
                        .clipShape(Circle())
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(model.checking)
        .accessibilityLabel(model.machineEndpoint == nil ? "Connect machine" : "Machine connected")
    }
}

struct F1MachineIcon: View {
    var connected: Bool

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let unit = side / 34
            ZStack {
                RoundedRectangle(cornerRadius: 5 * unit)
                    .fill(Color(red: 0.78, green: 0.82, blue: 0.66))
                    .frame(width: 19 * unit, height: 7 * unit)
                    .offset(x: -2 * unit, y: 10 * unit)
                RoundedRectangle(cornerRadius: 6 * unit)
                    .fill(Color(red: 0.17, green: 0.28, blue: 0.12).opacity(0.86))
                    .overlay(RoundedRectangle(cornerRadius: 6 * unit).stroke(Color.white.opacity(0.45), lineWidth: 1 * unit))
                    .frame(width: 19 * unit, height: 25 * unit)
                    .offset(y: -2 * unit)
                RoundedRectangle(cornerRadius: 4 * unit)
                    .fill(Color(red: 0.70, green: 0.76, blue: 0.53))
                    .frame(width: 15 * unit, height: 5 * unit)
                    .offset(x: -1 * unit, y: -1 * unit)
                RoundedRectangle(cornerRadius: 3 * unit)
                    .stroke(Color(red: 0.82, green: 0.86, blue: 0.66), lineWidth: 2 * unit)
                    .frame(width: 12 * unit, height: 7 * unit)
                    .offset(x: -3 * unit, y: 5 * unit)
                Circle()
                    .fill(Color.red)
                    .frame(width: 5 * unit, height: 5 * unit)
                    .offset(x: 11 * unit, y: 11 * unit)
                Circle()
                    .fill(Color.blue)
                    .frame(width: 3.5 * unit, height: 3.5 * unit)
                    .shadow(color: .blue, radius: 3 * unit)
                    .offset(x: -3 * unit, y: 15 * unit)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .saturation(connected ? 1 : 0)
        .opacity(connected ? 1 : 0.48)
    }
}

private struct MachineView: View {
    @EnvironmentObject private var model: AppModel
    @State private var armed = false
    @State private var point = Point(x: RasterGenerator.workAreaMM / 2, y: RasterGenerator.workAreaMM / 2)

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    F1MachineIcon(connected: model.machineEndpoint != nil)
                        .frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.machineStatusTitle)
                            .font(.headline)
                        Text(model.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    MachineStatusButton()
                }

                LivePreviewPad(point: $point, armed: armed) { point in
                    model.previewLaser(at: point)
                } onEnded: {
                    model.finishLivePreviewGesture()
                }

                HStack {
                    Label("\(point.x, specifier: "%.1f"), \(point.y, specifier: "%.1f") mm", systemImage: "scope")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        armed.toggle()
                        if !armed {
                            model.stopLivePreview()
                        }
                    } label: {
                        Label(armed ? "Disarm" : "Arm", systemImage: armed ? "pause.circle" : "play.circle")
                            .frame(width: 112, height: 42)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.preparing || model.printing)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("Machine")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    MachineStatusButton()
                }
            }
            .onDisappear {
                if armed {
                    armed = false
                    model.stopLivePreview()
                }
            }
        }
    }
}

private struct LivePreviewPad: View {
    @Binding var point: Point
    @State private var livePoint = Point(x: RasterGenerator.workAreaMM / 2, y: RasterGenerator.workAreaMM / 2)
    @State private var lastReadoutUpdate = Date.distantPast
    @State private var lastMachineUpdate = Date.distantPast
    var armed: Bool
    var onMoved: (Point) -> Void
    var onEnded: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.06))
                MachinePadGrid()
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 0.6)
                Circle()
                    .fill(armed ? Color.blue : Color.secondary)
                    .shadow(color: armed ? .blue.opacity(0.7) : .clear, radius: 6)
                    .frame(width: 12, height: 12)
                    .offset(x: CGFloat(livePoint.x / RasterGenerator.workAreaMM) * side - 6, y: CGFloat(livePoint.y / RasterGenerator.workAreaMM) * side - 6)
            }
            .frame(width: side, height: side)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.35)))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let next = Self.point(from: value.location, side: side)
                        livePoint = next
                        updateReadout(next)
                        if armed {
                            updateMachine(next)
                        }
                    }
                    .onEnded { _ in
                        point = livePoint
                        if armed {
                            onEnded()
                        }
                    }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            livePoint = point
        }
    }

    private func updateReadout(_ next: Point) {
        let now = Date()
        guard now.timeIntervalSince(lastReadoutUpdate) >= 0.1 else { return }
        lastReadoutUpdate = now
        point = next
    }

    private func updateMachine(_ next: Point) {
        let now = Date()
        guard now.timeIntervalSince(lastMachineUpdate) >= 0.016 else { return }
        lastMachineUpdate = now
        DispatchQueue.main.async {
            onMoved(next)
        }
    }

    private static func point(from location: CGPoint, side: CGFloat) -> Point {
        Point(
            x: Double(min(side, max(0, location.x)) / max(1, side)) * RasterGenerator.workAreaMM,
            y: Double(min(side, max(0, location.y)) / max(1, side)) * RasterGenerator.workAreaMM
        )
    }
}

private struct MachinePadGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0...10 {
            let offset = CGFloat(index) * rect.width / 10
            path.move(to: CGPoint(x: rect.minX + offset, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + offset))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + offset))
        }
        return path
    }
}

private struct TileGridPreview: View {
    var plan: TilePlan
    var selectedIndex: Int
    var completed: Set<Int>

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / CGFloat(plan.finalWidthMM), proxy.size.height / CGFloat(plan.finalHeightMM))
            let width = CGFloat(plan.finalWidthMM) * scale
            let height = CGFloat(plan.finalHeightMM) * scale
            let x0 = (proxy.size.width - width) / 2
            let y0 = (proxy.size.height - height) / 2
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                    .frame(width: width, height: height)
                    .offset(x: x0, y: y0)

                ForEach(plan.steps) { step in
                    let selected = step.index == selectedIndex
                    let rect = CGRect(
                        x: x0 + CGFloat(step.xMM) * scale,
                        y: y0 + CGFloat(step.yMM) * scale,
                        width: CGFloat(step.widthMM) * scale,
                        height: CGFloat(step.heightMM) * scale
                    )
                    Rectangle()
                        .fill((completed.contains(step.index) ? Color.green : Color.accentColor).opacity(selected ? 0.30 : 0.12))
                        .overlay(Rectangle().stroke(selected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: selected ? 2 : 1))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                    Text("\(step.index + 1)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
    }
}

@MainActor
private final class ProjectEditSession: ObservableObject {
    @Published var project: StoredProject
    @Published var selectedPhotoIDs: Set<UUID> = []
    @Published var preview: GCodePreview?
    @Published var previewLoading = false
    @Published var previewDarkBackground = false
    @Published var canvasEditing = false
    @Published var canvasViewportGestureActive = false
    @Published var editingPhotoID: UUID?
    @Published var editingVectorID: UUID?
    @Published var actionMessage: String?
    @Published var pendingUndoSnapshot: StoredProjectSnapshot?
    @Published var pendingRedoSnapshot: StoredProjectSnapshot?
    var lastSavedSnapshot: StoredProjectSnapshot?
    var saveTask: Task<Void, Never>?
    var previewTask: Task<Void, Never>?

    init(project: StoredProject) {
        self.project = project
    }

    deinit {
        saveTask?.cancel()
        previewTask?.cancel()
    }
}

struct ProjectDetailView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var session: ProjectEditSession
    var onClose: (() -> Void)?
    @State private var photo: PhotosPickerItem?
    @State private var renaming = false
    @State private var draftName = ""
    @State private var namingPreset = false
    @State private var presetName = ""
    @State private var tilePhotoID: UUID?
    @State private var tileWidthMM = RasterGenerator.workAreaMM
    @State private var tileHeightMM = RasterGenerator.workAreaMM
    @State private var tileOverlapMM = 0.0
    @State private var tileStepIndex = 0
    @State private var completedTileSteps: Set<Int> = []

    init(project: StoredProject, onClose: (() -> Void)? = nil) {
        _session = StateObject(wrappedValue: ProjectEditSession(project: project))
        self.onClose = onClose
    }

    private var project: StoredProject {
        get { session.project }
        nonmutating set { session.project = newValue }
    }

    private var selectedPhotoIDs: Set<UUID> {
        get { session.selectedPhotoIDs }
        nonmutating set { session.selectedPhotoIDs = newValue }
    }

    private var lastSavedSnapshot: StoredProjectSnapshot? {
        get { session.lastSavedSnapshot }
        nonmutating set { session.lastSavedSnapshot = newValue }
    }

    private var pendingUndoSnapshot: StoredProjectSnapshot? {
        get { session.pendingUndoSnapshot }
        nonmutating set { session.pendingUndoSnapshot = newValue }
    }

    private var pendingRedoSnapshot: StoredProjectSnapshot? {
        get { session.pendingRedoSnapshot }
        nonmutating set { session.pendingRedoSnapshot = newValue }
    }

    private var saveTask: Task<Void, Never>? {
        get { session.saveTask }
        nonmutating set { session.saveTask = newValue }
    }

    private var previewTask: Task<Void, Never>? {
        get { session.previewTask }
        nonmutating set { session.previewTask = newValue }
    }

    private var preview: GCodePreview? {
        get { session.preview }
        nonmutating set { session.preview = newValue }
    }

    private var previewLoading: Bool {
        get { session.previewLoading }
        nonmutating set { session.previewLoading = newValue }
    }

    private var previewDarkBackground: Bool {
        get { session.previewDarkBackground }
        nonmutating set { session.previewDarkBackground = newValue }
    }

    private var canvasEditing: Bool {
        get { session.canvasEditing }
        nonmutating set { session.canvasEditing = newValue }
    }

    private var canvasViewportGestureActive: Bool {
        get { session.canvasViewportGestureActive }
        nonmutating set { session.canvasViewportGestureActive = newValue }
    }

    private var editingPhotoID: UUID? {
        get { session.editingPhotoID }
        nonmutating set { session.editingPhotoID = newValue }
    }

    private var editingVectorID: UUID? {
        get { session.editingVectorID }
        nonmutating set { session.editingVectorID = newValue }
    }

    private var actionMessage: String? {
        get { session.actionMessage }
        nonmutating set { session.actionMessage = newValue }
    }

    private var selectedPhotoIndex: Int? {
        guard selectedPhotoIDs.count == 1, let selectedPhotoID = selectedPhotoIDs.first else { return nil }
        return project.photos.firstIndex { $0.id == selectedPhotoID }
    }

    private var canUndo: Bool {
        pendingUndoSnapshot != nil || !project.undoHistory.isEmpty
    }

    private var canRedo: Bool {
        pendingUndoSnapshot == nil && (pendingRedoSnapshot != nil || !project.redoHistory.isEmpty)
    }

    private var hasPrintableObject: Bool {
        PrintGCodeGenerator.printableObjectCount(project.photos) > 0
    }

    private var selectedRasterPhoto: ProjectPhoto? {
        let selected = project.photos.filter { selectedPhotoIDs.contains($0.id) && $0.mode == .raster }
        return selected.count == 1 ? selected[0] : nil
    }

    private var objectSummary: String {
        let enabled = project.photos.filter(\.isEnabled).count
        let total = project.photos.count
        if enabled == total {
            return "\(total) object\(total == 1 ? "" : "s")"
        }
        return "\(enabled) of \(total) enabled"
    }

    private var machineConnected: Bool {
        model.machineEndpoint != nil
    }

    private var editingPhotoBinding: Binding<ProjectPhoto?> {
        Binding {
            editingPhotoID.flatMap { id in project.photos.first { $0.id == id && $0.mode == .raster } }
        } set: { photo in
            editingPhotoID = photo?.id
        }
    }

    private var editingVectorBinding: Binding<ProjectPhoto?> {
        Binding {
            editingVectorID.flatMap { id in project.photos.first { $0.id == id && ($0.mode == .vector || $0.mode == .text) } }
        } set: { photo in
            editingVectorID = photo?.id
        }
    }

    var body: some View {
        detailScroll
            .background(screenBackground)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                printActionBar
                    .background(.regularMaterial)
            }
            .navigationTitle("")
            .inlineNavigationTitle()
            .hideTabBar()
            .toolbar { detailToolbar }
            .alert("Rename Project", isPresented: $renaming) {
                TextField("Name", text: $draftName)
                Button("Cancel", role: .cancel) { renaming = false }
                Button("Rename", action: commitRename)
            }
            .alert("Save Settings", isPresented: $namingPreset) {
                TextField("Name", text: $presetName)
                Button("Cancel", role: .cancel) { namingPreset = false }
                Button("Save", action: saveNamedPreset)
            }
            .photoEditorCover(item: editingPhotoBinding) { photo in
                let asset = model.store?.asset(for: photo)
                PhotoEditScreen(photo: photo, sourcePath: photoPath(photo), canUndo: asset?.undoHistory.isEmpty == false, canRedo: asset?.redoHistory.isEmpty == false) { data, kind, values in
                    commitPhotoEdit(data, photoID: photo.id, editKind: kind, values: values)
                } onUndo: {
                    undoPhotoEdit(photoID: photo.id)
                } onRedo: {
                    redoPhotoEdit(photoID: photo.id)
                } onCreateOutline: { outline, offset, includeInterior in
                    createOutline(outline, sourcePhotoID: photo.id, offsetMM: offset, includeInterior: includeInterior)
                }
            }
            .photoEditorCover(item: editingVectorBinding) { photo in
                let history = model.objectAssetHistory(for: photo)
                ObjectEditScreen(photo: photo, photos: project.photos, store: model.store, canUndo: history.canUndo, canRedo: history.canRedo) { updated in
                    commitObjectEdit(updated)
                } onUndo: {
                    undoObjectEdit(photoID: photo.id)
                } onRedo: {
                    redoObjectEdit(photoID: photo.id)
                } onDuplicate: {
                    duplicateObject(id: photo.id)
                } onDelete: {
                    deleteObject(id: photo.id)
                }
            }
            .onAppear {
                project = model.normalized(project)
                lastSavedSnapshot = project.snapshot
                applyPendingSelection()
                openPendingEdit()
                resetTileDraftIfNeeded()
                schedulePreview(delay: 0)
            }
            .onDisappear {
                previewTask?.cancel()
                flushAutosave()
            }
            .onChange(of: project.snapshot) { _ in
                editChanged()
                resetTileDraftIfNeeded()
                if !canvasEditing { schedulePreview() }
            }
            .onChange(of: model.libraryAssets) { _ in
                schedulePreview(delay: 0)
            }
            .onChange(of: photo) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await MainActor.run {
                            flushAutosave()
                            if let saved = model.addPhoto(data, to: project) {
                                project = model.normalized(saved)
                                selectOnly(project.photos.last?.id)
                                lastSavedSnapshot = project.snapshot
                                schedulePreview(delay: 0)
                            }
                        }
                    }
                }
            }
            .onChange(of: model.pendingEditObjectID) { _ in
                openPendingEdit()
            }
            .onChange(of: model.pendingSelectObjectIDs) { _ in
                applyPendingSelection()
            }
            .onChange(of: selectedPhotoIDs) { _ in
                resetTileDraftIfNeeded()
            }
    }

    private var detailScroll: some View {
        ScrollView {
            VStack(spacing: 16) {
                projectMeta
                canvasCard
                if let tilePhoto = selectedRasterPhoto, tilePanelNeeded(for: tilePhoto) {
                    SectionCard("Tiles") {
                        tilePanel(photo: tilePhoto)
                    }
                }
                SectionCard("Print Preview", accessory: AnyView(PrintPreviewBackdropToggle(darkBackground: session.previewDarkBackground) {
                    previewDarkBackground.toggle()
                })) {
                    printPreview
                }
            }
            .padding(16)
            .padding(.bottom, 16)
        }
        .scrollDisabled(canvasViewportGestureActive || canvasEditing)
    }

    private var canvasCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProjectCanvasView(store: model.store, photos: $session.project.photos, selectedPhotoIDs: $session.selectedPhotoIDs, isEditing: $session.canvasEditing, onEdit: editObject, onDelete: deleteObject, onViewportGestureChanged: { canvasViewportGestureActive = $0 }) {
                schedulePreview()
            }
                .padding(.horizontal, -16)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("print.space")
            HStack {
                Label("115 x 115 mm", systemImage: "square.grid.3x3")
                Spacer()
                if project.photos.isEmpty {
                    Text("No photo selected")
                } else {
                    thumbnailStrip
                }
            }
            .padding(.top, 12)
            .font(.caption)
            .foregroundStyle(.secondary)
            if let index = selectedPhotoIndex {
                Divider()
                    .padding(.top, 12)
                settingsPanel(index: index)
                    .padding(.top, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(project.photos.enumerated()), id: \.element.id) { index, photo in
                    if index > 0 {
                        deselectThumbnailGap
                            .frame(width: 6, height: 34)
                    }
                    Button {
                        toggleSelection(photo.id)
                    } label: {
                        ObjectThumbnail(photo: photo, path: photoPath(photo), size: 34, selected: selectedPhotoIDs.contains(photo.id))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            editObject(photo)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button {
                            toggleObjectEnabled(id: photo.id)
                        } label: {
                            Label(photo.isEnabled ? "Disable" : "Enable", systemImage: photo.isEnabled ? "eye.slash" : "eye")
                        }
                        Button(role: .destructive) {
                            deleteObject(id: photo.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                deselectThumbnailGap
                    .frame(width: 180, height: 34)
            }
        }
        .frame(maxWidth: 180)
    }

    private var deselectThumbnailGap: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                selectedPhotoIDs.removeAll()
            }
    }

    @ToolbarContentBuilder private var detailToolbar: some ToolbarContent {
            if let onClose {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onClose) {
                        Label("Projects", systemImage: "chevron.left")
                    }
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                MachineStatusButton()

                Button {
                    undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!canUndo)

                Button {
                    redo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!canRedo)
            }

            ToolbarItem(placement: .principal) {
                Text(project.name)
                    .font(.headline)
                    .lineLimit(1)
                    .onLongPressGesture {
                        draftName = project.name
                        renaming = true
                    }
                    .accessibilityIdentifier("project.title")
            }
    }

    private var printActionBar: some View {
        VStack(spacing: 5) {
            if let actionMessage {
                Text(actionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.thinMaterial)
                    .clipShape(Capsule())
            }

            if let progress = model.printProgress {
                printProgressView(progress)
            }

            frameSpeedControl

            HStack {
                Button {
                    flushAutosave()
                    if !model.framing && !hasPrintableObject {
                        showActionMessage(project.photos.isEmpty ? "Add an object to frame" : "Enable an object to frame")
                        return
                    }
                    if !machineConnected && !model.framing {
                        unavailableMachineTapped()
                        return
                    }
                    model.framing ? model.stopFrame() : model.startFrame(project)
                } label: {
                    Label(model.framing ? "Stop" : "Frame", systemImage: model.framing ? "stop.circle" : "viewfinder")
                        .frame(width: 128, height: 56)
                }
                .buttonStyle(.plain)
                .foregroundStyle(machineConnected && hasPrintableObject || model.framing ? Color.primary : Color.secondary)
                .background(frameButtonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
                .disabled(model.preparing || model.printing)
                .accessibilityIdentifier("frame.project")

                Spacer(minLength: 16)

                Button {
                    flushAutosave()
                    if !model.printing && !hasPrintableObject {
                        showActionMessage(project.photos.isEmpty ? "Add an object to print" : "Enable an object to print")
                        return
                    }
                    if !machineConnected && !model.printing {
                        unavailableMachineTapped()
                        return
                    }
                    model.printing ? model.stopPrint() : model.preparePrint(project)
                } label: {
                    Label(printButtonTitle, systemImage: printButtonIcon)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(width: 128, height: 56)
                }
                .buttonStyle(.plain)
                .foregroundStyle(printButtonForeground)
                .background(printButtonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
                .disabled(model.preparing || model.framing)
                .accessibilityIdentifier("prepare.print")
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
    }

    private var frameSpeedControl: some View {
        VStack(spacing: 5) {
            Picker("Frame Mode", selection: frameModeBinding) {
                Text("Outline").tag(FrameMode.outline)
                Text("Box").tag(FrameMode.rectangle)
                Text("Wrap").tag(FrameMode.wrap)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("frame.mode")

            HStack(spacing: 8) {
                Label("Frame", systemImage: "speedometer")
                    .font(.caption)
                Slider(value: frameSpeedBinding, in: 1...FrameGCodeGenerator.maximumFrameSpeedMMPerSecond, onEditingChanged: { editing in
                    if !editing {
                        model.saveFrameSpeed(project.frameSpeedMMPerSecond)
                    }
                })
                    .accessibilityIdentifier("frame.speed")
                Text("\(project.frameSpeedMMPerSecond, specifier: "%.0f") mm/s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .disabled(model.framing || model.printing || model.preparing)
    }

    private func printProgressView(_ progress: PrintProgressState) -> some View {
        VStack(spacing: 4) {
            ProgressView(value: progress.fraction)
            HStack {
                Text(progress.title)
                Spacer()
                Text("\(formatClock(progress.elapsedSeconds)) / \(formatClock(progress.estimatedSeconds))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
    }

    private var printButtonTitle: String {
        if model.printing { return "Stop" }
        if model.preparing { return "Sending" }
        return "Print"
    }

    private var printButtonIcon: String {
        model.printing ? "stop.circle" : "paperplane.fill"
    }

    private var secondaryButtonBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #elseif os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    private var frameButtonBackground: Color {
        machineConnected && hasPrintableObject || model.framing ? secondaryButtonBackground : inactiveButtonBackground
    }

    private var printButtonBackground: Color {
        if model.printing { return .red }
        return machineConnected && hasPrintableObject ? .accentColor : inactiveButtonBackground
    }

    private var printButtonForeground: Color {
        machineConnected && hasPrintableObject || model.printing ? .white : .secondary
    }

    private var inactiveButtonBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGray5)
        #elseif os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    private var projectMeta: some View {
        HStack {
            Text("\(objectSummary) · Updated \(project.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                if !model.seededPreviewMode && !model.launchStateMode {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Photo", systemImage: "photo.badge.plus")
                    }
                }
                Button {
                    addTextObject()
                } label: {
                    Label("Text", systemImage: "textformat")
                }
                Menu {
                    ForEach(BasicShapeKind.allCases) { shape in
                        Button {
                            addShapeObject(shape)
                        } label: {
                            Label(shape.title, systemImage: shape.icon)
                        }
                    }
                } label: {
                    Label("Shape", systemImage: "square.on.circle")
                }
                Menu {
                    ForEach(TextureKind.allCases, id: \.self) { kind in
                        Button {
                            addTextureObject(kind)
                        } label: {
                            Label(kind.title, systemImage: kind.icon)
                        }
                    }
                } label: {
                    Label("Texture", systemImage: "square.grid.3x3.fill")
                }
                .disabled(selectedPhotoIndex == nil)
            } label: {
                Label("Add", systemImage: "plus")
            }
            .accessibilityIdentifier("project.add")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tilePanel(photo: ProjectPhoto) -> some View {
        let plan = TilePlanGenerator.plan(finalWidthMM: tileWidthMM, finalHeightMM: tileHeightMM, overlapMM: tileOverlapMM)
        let selected = min(max(0, tileStepIndex), max(0, plan.steps.count - 1))
        let step = plan.steps[selected]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                NumberField(value: $tileWidthMM, suffix: "W mm", range: 1...2000)
                NumberField(value: $tileHeightMM, suffix: "H mm", range: 1...2000)
            }
            NumberField(value: $tileOverlapMM, suffix: "overlap", range: 0...50)
            TileGridPreview(plan: plan, selectedIndex: selected, completed: completedTileSteps)
                .frame(height: 180)
            Stepper("\(step.title) of \(plan.steps.count)", value: Binding {
                selected
            } set: {
                tileStepIndex = min(max(0, $0), max(0, plan.steps.count - 1))
            }, in: 0...max(0, plan.steps.count - 1))
            Text("\(step.widthMM, specifier: "%.1f") x \(step.heightMM, specifier: "%.1f") mm at row \(step.row + 1), column \(step.column + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                flushAutosave()
                if !machineConnected {
                    unavailableMachineTapped()
                    return
                }
                completedTileSteps.insert(step.index)
                model.prepareTilePrint(project, photoID: photo.id, step: step, finalWidthMM: plan.finalWidthMM, finalHeightMM: plan.finalHeightMM)
            } label: {
                Label("Print \(step.title)", systemImage: completedTileSteps.contains(step.index) ? "checkmark.circle" : "paperplane.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.preparing || model.printing || model.framing)
        }
    }

    private func tilePanelNeeded(for photo: ProjectPhoto) -> Bool {
        max(tileWidthMM, photo.settings.placement.widthMM) > RasterGenerator.workAreaMM || max(tileHeightMM, photo.settings.placement.heightMM) > RasterGenerator.workAreaMM
    }

    private func photoPath(_ photo: ProjectPhoto) -> String? {
        model.store?.imageURL(for: photo)?.path
    }

    private func settingsPanel(index: Int) -> some View {
        let dotDuration = Binding<Double>(
            get: { project.photos[index].settings.dotDurationMicroseconds },
            set: { project.photos[index].settings.dotDurationMicroseconds = min(3000, max(10, $0)) }
        )
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(project.photos[index].name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Button(role: .destructive) {
                    deleteObject(id: project.photos[index].id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .font(.caption)
            }

            Toggle("Enabled for print", isOn: $session.project.photos[index].isEnabled)
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("object.enabled")
            PassStepper(passes: passBinding(index))

            HStack(spacing: 4) {
                Text("Placement")
                    .font(.subheadline.weight(.semibold))
                Text("(mm)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                CompactNumberField("X", value: placementBinding(index, \.xMM))
                CompactNumberField("Y", value: placementBinding(index, \.yMM))
                CompactNumberField("W", value: placementBinding(index, \.widthMM))
                CompactNumberField("H", value: placementBinding(index, \.heightMM))
            }
            CompactNumberField("Rotation", value: placementBinding(index, \.rotationDegrees))

            if project.photos[index].mode == .raster {
                presetRow(index: index)
                Text("Raster")
                    .font(.subheadline.weight(.semibold))
                Picker("Laser", selection: $session.project.photos[index].settings.laser) {
                    Text("Blue").tag(Laser.blue)
                    Text("IR").tag(Laser.infrared)
                }
                .pickerStyle(.segmented)
                Picker("DPI", selection: $session.project.photos[index].settings.dpi) {
                    Text("125").tag(125.0)
                    Text("250").tag(250.0)
                    Text("500").tag(500.0)
                }
                .pickerStyle(.segmented)
                SettingRow("Custom DPI") { NumberField(value: $session.project.photos[index].settings.dpi, suffix: "DPI", range: RasterSettings.minimumDPI...RasterSettings.maximumDPI) }
                SettingSlider("Speed", value: $session.project.photos[index].settings.speedMMPerSecond, range: 1...400, suffix: "mm/s")
                SettingSlider("Dot Duration", value: dotDuration, range: 10...3000, suffix: "μs")
                SettingSlider("Min Power", value: $session.project.photos[index].settings.minPowerPercent, range: 0...100, suffix: "%")
                SettingSlider("Max Power", value: $session.project.photos[index].settings.maxPowerPercent, range: 1...100, suffix: "%")
                SettingSlider("Drop Below", value: $session.project.photos[index].settings.dropPowerThresholdPercent, range: 0...100, suffix: "%")
                Picker("Scan", selection: $session.project.photos[index].settings.scanDirection) {
                    Text("Left to right").tag(ScanDirection.leftToRight)
                    Text("Bidirectional").tag(ScanDirection.bidirectional)
                }
                .pickerStyle(.segmented)
            } else {
                HStack {
                    Text(project.photos[index].mode == .text ? "Text" : "Vector")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button {
                        editObject(project.photos[index])
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .font(.caption)
                }
                Picker("Laser", selection: vectorLaserBinding(index)) {
                    Text("Blue").tag(Laser.blue)
                    Text("IR").tag(Laser.infrared)
                }
                .pickerStyle(.segmented)
                SettingSlider("Speed", value: vectorBinding(index, \.speedMMPerSecond), range: 1...400, suffix: "mm/s", onCommit: {
                    model.saveVectorSettings(project.photos[index].resolvedVectorSettings)
                })
                SettingSlider("Power", value: vectorBinding(index, \.powerPercent), range: 0...100, suffix: "%", onCommit: {
                    model.saveVectorSettings(project.photos[index].resolvedVectorSettings)
                })
            }
        }
    }

    private func passBinding(_ index: Int) -> Binding<Int> {
        Binding {
            project.photos[index].passes
        } set: {
            project.photos[index].passes = min(ProjectPhoto.maximumPasses, max(1, $0))
        }
    }

    private func placementBinding(_ index: Int, _ keyPath: WritableKeyPath<PrintPlacement, Double>) -> Binding<Double> {
        Binding {
            let value = project.photos[index].printPlacement[keyPath: keyPath]
            return keyPath == \.rotationDegrees ? normalizedRotationDegrees(value) : value
        } set: { value in
            if keyPath == \.rotationDegrees {
                project.photos[index].printPlacement = RasterGenerator.sizeConstrained(rotatedPlacement(project.photos[index].printPlacement, object: project.photos[index], degrees: value))
            } else {
                project.photos[index].printPlacement[keyPath: keyPath] = value
            }
            if project.photos[index].mode == .vector || project.photos[index].mode == .text {
                model.saveVectorSettings(project.photos[index].resolvedVectorSettings)
            }
        }
    }

    private func vectorBinding(_ index: Int, _ keyPath: WritableKeyPath<VectorSettings, Double>) -> Binding<Double> {
        Binding {
            project.photos[index].resolvedVectorSettings[keyPath: keyPath]
        } set: { value in
            var vector = project.photos[index].resolvedVectorSettings
            vector[keyPath: keyPath] = value
            project.photos[index].vectorSettings = vector
            project.photos[index].settings.placement = vector.placement
        }
    }

    private func vectorLaserBinding(_ index: Int) -> Binding<Laser> {
        Binding {
            project.photos[index].resolvedVectorSettings.laser
        } set: { laser in
            var vector = project.photos[index].resolvedVectorSettings
            vector.laser = laser
            project.photos[index].vectorSettings = vector
            project.photos[index].settings.placement = vector.placement
            model.saveVectorSettings(vector)
        }
    }

    private func presetRow(index: Int) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.settingPresets) { preset in
                    Button(preset.name) {
                        model.applyPreset(preset, to: project.photos[index].id, in: &project)
                    }
                }
                if !model.settingPresets.isEmpty { Divider() }
                Button("Save As...") {
                    presetName = project.photos[index].settingsName == "Custom" ? "" : project.photos[index].settingsName
                    namingPreset = true
                }
            } label: {
                Label(project.photos[index].settingsName, systemImage: "slider.horizontal.3")
                    .lineLimit(1)
            }
            Spacer()
            if let preset = model.settingPresets.first(where: { $0.name == project.photos[index].settingsName }) {
                Button("Update") {
                    model.updatePreset(id: preset.id, settings: project.photos[index].settings)
                }
                .font(.caption)
            }
            Button {
                presetName = project.photos[index].settingsName == "Custom" ? "" : project.photos[index].settingsName
                namingPreset = true
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
        }
    }

    private var printPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("G-code", selection: gcodeModeBinding) {
                Text("Sequential").tag(RasterGCodeMode.asset)
                Text("Simultaneous").tag(RasterGCodeMode.scanline)
            }
            .pickerStyle(.segmented)
            ProjectPrintPreviewView(preview: preview, isLoading: previewLoading, darkBackground: previewDarkBackground)
                .id(project.gcodeMode)
                .accessibilityIdentifier("print.preview")
            Text("\(gcodeModeTitle) · \(objectSummary) · 115 x 115 mm\(previewDurationText)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var previewDurationText: String {
        guard let seconds = preview?.estimatedDurationSeconds, seconds > 0 else { return "" }
        return " · \(formatDuration(seconds))"
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = max(1, Int(seconds.rounded()))
        let minutes = total / 60
        let seconds = total % 60
        return minutes > 0 ? "~\(minutes)m \(seconds)s" : "~\(seconds)s"
    }

    private func formatClock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let seconds = total % 60
        return "\(minutes):\(seconds < 10 ? "0" : "")\(seconds)"
    }

    private var gcodeModeTitle: String {
        project.gcodeMode == .asset ? "Sequential" : "Simultaneous"
    }

    private var gcodeModeBinding: Binding<RasterGCodeMode> {
        Binding {
            project.gcodeMode
        } set: { mode in
            project.gcodeMode = mode
            model.defaultGCodeMode = mode
            schedulePreview(delay: 0, clear: true)
        }
    }

    private var frameSpeedBinding: Binding<Double> {
        Binding {
            project.frameSpeedMMPerSecond
        } set: { speed in
            project.frameSpeedMMPerSecond = min(FrameGCodeGenerator.maximumFrameSpeedMMPerSecond, max(1, speed))
        }
    }

    private var frameModeBinding: Binding<FrameMode> {
        Binding {
            project.frameMode
        } set: { mode in
            project.frameMode = mode
        }
    }

    private func commitRename() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            renaming = false
            return
        }
        project.name = name
        renaming = false
    }

    private func saveNamedPreset() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = selectedPhotoIndex, !name.isEmpty else {
            namingPreset = false
            return
        }
        if let preset = model.savePreset(name: name, settings: project.photos[index].settings) {
            project.photos[index].settingsName = preset.name
        }
        namingPreset = false
    }

    private func showActionMessage(_ message: String) {
        actionMessage = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if actionMessage == message {
                actionMessage = nil
            }
        }
    }

    private func unavailableMachineTapped() {
        showActionMessage("Trying to connect")
        model.checkConnection()
    }

    private func selectOnly(_ id: UUID?) {
        selectedPhotoIDs = id.map { Set([$0]) } ?? []
    }

    private func openPendingEdit() {
        guard let id = model.pendingEditObjectID, project.photos.contains(where: { $0.id == id }) else { return }
        model.pendingEditObjectID = nil
        selectOnly(id)
        editingVectorID = id
    }

    private func applyPendingSelection() {
        let objectIDs = Set(project.photos.map(\.id))
        let ids = model.pendingSelectObjectIDs.intersection(objectIDs)
        guard !ids.isEmpty else { return }
        selectedPhotoIDs = ids
        model.pendingSelectObjectIDs.subtract(ids)
    }

    private func resetTileDraftIfNeeded() {
        guard let photo = selectedRasterPhoto else {
            tilePhotoID = nil
            completedTileSteps.removeAll()
            return
        }
        guard tilePhotoID == photo.id else {
            tilePhotoID = photo.id
            tileWidthMM = max(1, photo.settings.placement.widthMM)
            tileHeightMM = max(1, photo.settings.placement.heightMM)
            tileOverlapMM = 0
            tileStepIndex = 0
            completedTileSteps.removeAll()
            return
        }
        tileWidthMM = max(tileWidthMM, photo.settings.placement.widthMM)
        tileHeightMM = max(tileHeightMM, photo.settings.placement.heightMM)
    }

    private func addTextObject() {
        flushAutosave()
        if let saved = model.addText(to: project) {
            project = model.normalized(saved)
            selectOnly(project.photos.last?.id)
            editingVectorID = project.photos.last?.id
            lastSavedSnapshot = project.snapshot
            schedulePreview(delay: 0)
        }
    }

    private func addShapeObject(_ shape: BasicShapeKind) {
        flushAutosave()
        if let saved = model.addShape(shape, to: project) {
            project = model.normalized(saved)
            selectOnly(project.photos.last?.id)
            editingVectorID = project.photos.last?.id
            lastSavedSnapshot = project.snapshot
            schedulePreview(delay: 0)
        }
    }

    private func addTextureObject(_ kind: TextureKind) {
        flushAutosave()
        guard let sourceIndex = selectedPhotoIndex else {
            showActionMessage("Select one object for texture")
            return
        }
        do {
            let source = project.photos[sourceIndex]
            let made = try makeTextureObject(kind, source: source)
            guard !made.vectorPaths.isEmpty else {
                showActionMessage("No texture area found")
                return
            }
            var object = made
            _ = model.store?.syncObjectAsset(for: &object, projectID: project.id, parentAssetID: source.assetID, editKind: "texture")
            project.photos.insert(object, at: project.photos.index(after: sourceIndex))
            selectOnly(object.id)
            model.saveVectorSettings(object.resolvedVectorSettings)
            showActionMessage("Added \(kind.title.lowercased()) texture")
            schedulePreview(delay: 0, clear: true)
        } catch {
            showActionMessage("Texture failed")
            try? model.log("Texture failed: \(error.localizedDescription)", level: .error)
        }
    }

    private func makeTextureObject(_ kind: TextureKind, source: ProjectPhoto) throws -> ProjectPhoto {
        let placement: PrintPlacement
        let paths: [LaserPath]
        if source.mode == .raster {
            guard let url = model.store?.imageURL(for: source) else { throw AppError.noStore }
            let mask = try RasterGenerator.burnMask(from: Data(contentsOf: url), settings: source.settings)
            placement = mask.placement
            paths = TexturePathGenerator.paths(kind: kind, mask: mask)
        } else {
            placement = source.resolvedVectorSettings.placement
            let sourcePaths = source.mode == .text && source.vectorPaths.isEmpty ? TextVectorGenerator.paths(for: source.resolvedTextSettings, placement: source.printPlacement) : source.vectorPaths
            paths = TexturePathGenerator.paths(kind: kind, clippedTo: sourcePaths)
        }
        var vector = model.defaultVectorSettings
        vector.placement = placement
        var settings = RasterSettings(placement: placement)
        settings.widthMM = placement.widthMM
        settings.heightMM = placement.heightMM
        return ProjectPhoto(name: "\(kind.title) Texture", mode: .vector, settingsName: "Texture", settings: settings, vectorSettings: vector, vectorPaths: paths)
    }

    private func toggleSelection(_ id: UUID) {
        if selectedPhotoIDs.contains(id) {
            selectedPhotoIDs.remove(id)
        } else {
            selectedPhotoIDs.insert(id)
        }
    }

    private func removeMissingSelection() {
        selectedPhotoIDs = selectedPhotoIDs.intersection(Set(project.photos.map(\.id)))
    }

    private func deleteObject(id: UUID) {
        guard let index = project.photos.firstIndex(where: { $0.id == id }) else { return }
        project.photos.remove(at: index)
        removeMissingSelection()
        if editingVectorID == id {
            editingVectorID = nil
        }
        schedulePreview(delay: 0)
    }

    private func toggleObjectEnabled(id: UUID) {
        guard let index = project.photos.firstIndex(where: { $0.id == id }) else { return }
        project.photos[index].isEnabled.toggle()
        schedulePreview(delay: 0, clear: true)
    }

    private func duplicateObject(id: UUID) {
        guard let index = project.photos.firstIndex(where: { $0.id == id }) else { return }
        var copy = project.photos[index]
        copy.id = UUID()
        copy.name = "Copy of \(copy.name)"
        copy.printPlacement.xMM += 2
        copy.printPlacement.yMM += 2
        project.photos.insert(copy, at: project.photos.index(after: index))
        selectOnly(copy.id)
        editingVectorID = (copy.mode == .vector || copy.mode == .text) ? copy.id : nil
        schedulePreview(delay: 0)
    }

    private func editObject(_ photo: ProjectPhoto) {
        selectOnly(photo.id)
        if photo.mode == .vector || photo.mode == .text {
            editingVectorID = photo.id
        } else {
            editingPhotoID = photo.id
        }
    }

    private func editPhoto(_ photo: ProjectPhoto) {
        guard photo.mode == .raster else { return }
        selectOnly(photo.id)
        editingPhotoID = photo.id
    }

    private func createOutline(_ outline: VectorOutline, sourcePhotoID: UUID, offsetMM: Double, includeInterior: Bool) {
        guard let sourceIndex = project.photos.firstIndex(where: { $0.id == sourcePhotoID }) else { return }
        var vector = model.defaultVectorSettings
        vector.placement = outline.placement
        var settings = RasterSettings(placement: outline.placement)
        settings.widthMM = outline.placement.widthMM
        settings.heightMM = outline.placement.heightMM
        let sourceName = project.photos[sourceIndex].name
        var object = ProjectPhoto(
            name: "Outline of \(sourceName)",
            mode: .vector,
            settingsName: "Cut",
            settings: settings,
            vectorSettings: vector,
            vectorPaths: outline.paths
        )
        _ = model.store?.syncObjectAsset(for: &object, projectID: project.id, parentAssetID: project.photos[sourceIndex].assetID, editKind: "outline")
        project.photos.insert(object, at: project.photos.index(after: sourceIndex))
        selectOnly(object.id)
        model.saveVectorSettings(vector)
        showActionMessage("Created outline \(String(format: "%.1f", offsetMM)) mm\(includeInterior ? " with interiors" : "")")
        schedulePreview(delay: 0, clear: true)
    }

    private func commitObjectEdit(_ object: ProjectPhoto) -> (canUndo: Bool, canRedo: Bool) {
        flushAutosave()
        guard let index = project.photos.firstIndex(where: { $0.id == object.id }) else { return objectEditHistory(photoID: object.id) }
        var object = object
        let history = model.commitObjectAsset(&object, projectID: project.id)
        project.photos[index] = object
        model.saveVectorSettings(object.resolvedVectorSettings)
        if let saved = model.update(project) {
            project = model.normalized(saved)
            pendingUndoSnapshot = nil
            pendingRedoSnapshot = nil
            lastSavedSnapshot = project.snapshot
        }
        schedulePreview()
        return history
    }

    private func undoObjectEdit(photoID: UUID) -> (photo: ProjectPhoto?, canUndo: Bool, canRedo: Bool) {
        guard let index = project.photos.firstIndex(where: { $0.id == photoID }), let restored = model.undoObjectAsset(for: project.photos[index]) else {
            let history = objectEditHistory(photoID: photoID)
            return (nil, history.canUndo, history.canRedo)
        }
        project.photos[index] = restored
        persistObjectHistoryState(index: index)
        let history = objectEditHistory(photoID: photoID)
        return (project.photos.first { $0.id == photoID }, history.canUndo, history.canRedo)
    }

    private func redoObjectEdit(photoID: UUID) -> (photo: ProjectPhoto?, canUndo: Bool, canRedo: Bool) {
        guard let index = project.photos.firstIndex(where: { $0.id == photoID }), let restored = model.redoObjectAsset(for: project.photos[index]) else {
            let history = objectEditHistory(photoID: photoID)
            return (nil, history.canUndo, history.canRedo)
        }
        project.photos[index] = restored
        persistObjectHistoryState(index: index)
        let history = objectEditHistory(photoID: photoID)
        return (project.photos.first { $0.id == photoID }, history.canUndo, history.canRedo)
    }

    private func persistObjectHistoryState(index: Int) {
        guard project.photos.indices.contains(index) else { return }
        model.saveVectorSettings(project.photos[index].resolvedVectorSettings)
        if let saved = model.update(project) {
            project = model.normalized(saved)
            pendingUndoSnapshot = nil
            pendingRedoSnapshot = nil
            lastSavedSnapshot = project.snapshot
        }
        schedulePreview(delay: 0)
    }

    private func objectEditHistory(photoID: UUID) -> (canUndo: Bool, canRedo: Bool) {
        guard let photo = project.photos.first(where: { $0.id == photoID }) else { return (false, false) }
        return model.objectAssetHistory(for: photo)
    }

    private func commitPhotoEdit(_ data: Data, photoID: UUID, editKind: String, values: [String: Double]) -> (canUndo: Bool, canRedo: Bool) {
        flushAutosave()
        let snapshot = model.snapshot(for: project)
        guard let saved = model.commitPhotoEdit(data, photoID: photoID, in: project, editKind: editKind, values: values, undoFrom: snapshot) else { return photoEditHistory(photoID: photoID) }
        project = model.normalized(saved)
        pendingUndoSnapshot = nil
        pendingRedoSnapshot = nil
        lastSavedSnapshot = project.snapshot
        schedulePreview(delay: 0)
        return photoEditHistory(photoID: photoID)
    }

    private func undoPhotoEdit(photoID: UUID) -> (data: Data?, canUndo: Bool, canRedo: Bool) {
        guard let photo = project.photos.first(where: { $0.id == photoID }), let data = model.undoAsset(for: photo) else {
            let history = photoEditHistory(photoID: photoID)
            return (nil, history.canUndo, history.canRedo)
        }
        schedulePreview(delay: 0)
        let history = photoEditHistory(photoID: photoID)
        return (data, history.canUndo, history.canRedo)
    }

    private func redoPhotoEdit(photoID: UUID) -> (data: Data?, canUndo: Bool, canRedo: Bool) {
        guard let photo = project.photos.first(where: { $0.id == photoID }), let data = model.redoAsset(for: photo) else {
            let history = photoEditHistory(photoID: photoID)
            return (nil, history.canUndo, history.canRedo)
        }
        schedulePreview(delay: 0)
        let history = photoEditHistory(photoID: photoID)
        return (data, history.canUndo, history.canRedo)
    }

    private func photoEditHistory(photoID: UUID) -> (canUndo: Bool, canRedo: Bool) {
        guard let photo = project.photos.first(where: { $0.id == photoID }), let asset = model.store?.asset(for: photo) else { return (false, false) }
        return (!asset.undoHistory.isEmpty, !asset.redoHistory.isEmpty)
    }

    private func schedulePreview(delay: UInt64 = 180_000_000, clear: Bool = false) {
        previewTask?.cancel()
        previewLoading = true
        if clear {
            preview = nil
        }
        guard let root = model.store?.root else {
            preview = nil
            previewLoading = false
            return
        }
        let photos = project.photos
        let assets = model.libraryAssets
        let mode = project.gcodeMode
        previewTask = Task {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            let next = await Task.detached(priority: .utility) {
                AppModel.printPreview(for: photos, root: root, assets: assets, mode: mode)
            }.value
            guard !Task.isCancelled else { return }
            preview = next
            previewLoading = false
        }
    }

    private func editChanged() {
        let normalized = model.normalized(project)
        if normalized.snapshot != project.snapshot {
            project = normalized
            return
        }
        guard normalized.snapshot != lastSavedSnapshot else {
            pendingUndoSnapshot = nil
            return
        }
        if pendingUndoSnapshot == nil {
            pendingUndoSnapshot = lastSavedSnapshot ?? normalized.snapshot
        }
        pendingRedoSnapshot = nil
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            flushAutosave()
        }
    }

    private func flushAutosave() {
        saveTask?.cancel()
        saveTask = nil
        let normalized = model.normalized(project)
        let savedSnapshot = lastSavedSnapshot ?? normalized.snapshot
        guard normalized.snapshot != savedSnapshot else {
            project = normalized
            pendingUndoSnapshot = nil
            lastSavedSnapshot = savedSnapshot
            return
        }
        guard let saved = model.update(normalized, undoFrom: pendingUndoSnapshot ?? savedSnapshot) else { return }
        project = saved
        pendingUndoSnapshot = nil
        pendingRedoSnapshot = nil
        lastSavedSnapshot = saved.snapshot
    }

    private func undo() {
        saveTask?.cancel()
        saveTask = nil
        if let snapshot = pendingUndoSnapshot {
            pendingRedoSnapshot = project.snapshot
            snapshot.restore(on: &project)
            project = model.normalized(project)
            removeMissingSelection()
            pendingUndoSnapshot = nil
            schedulePreview(delay: 0)
            return
        }
        guard let saved = model.undo(project) else { return }
        project = saved
        removeMissingSelection()
        lastSavedSnapshot = saved.snapshot
        schedulePreview(delay: 0)
    }

    private func redo() {
        saveTask?.cancel()
        saveTask = nil
        if let snapshot = pendingRedoSnapshot {
            pendingUndoSnapshot = project.snapshot
            snapshot.restore(on: &project)
            project = model.normalized(project)
            removeMissingSelection()
            pendingRedoSnapshot = nil
            scheduleAutosave()
            schedulePreview(delay: 0)
            return
        }
        guard let saved = model.redo(project) else { return }
        project = saved
        removeMissingSelection()
        lastSavedSnapshot = saved.snapshot
        schedulePreview(delay: 0)
    }
}

struct SectionCard<Content: View>: View {
    var title: String
    var accessory: AnyView
    @ViewBuilder var content: Content

    init(_ title: String, accessory: AnyView = AnyView(EmptyView()), @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                accessory
            }
            content
        }
        .padding(16)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SettingRow<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            content
        }
    }
}

struct SettingSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var suffix: String
    var onCommit: () -> Void
    var onDraftChange: (Double, Bool) -> Void
    @State private var draftValue: Double
    @State private var editing = false

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String, onDraftChange: @escaping (Double, Bool) -> Void = { _, _ in }, onCommit: @escaping () -> Void = {}) {
        self.title = title
        self._value = value
        self.range = range
        self.suffix = suffix
        self.onCommit = onCommit
        self.onDraftChange = onDraftChange
        self._draftValue = State(initialValue: min(range.upperBound, max(range.lowerBound, value.wrappedValue)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(draftValue, specifier: "%.0f") \(suffix)")
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding {
                draftValue
            } set: {
                draftValue = clamped($0)
                onDraftChange(draftValue, editing)
            }, in: range, onEditingChanged: { active in
                editing = active
                onDraftChange(draftValue, active)
                if !active {
                    commit()
                }
            })
        }
        .onAppear {
            draftValue = clamped(value)
        }
        .onChange(of: value) { next in
            if !editing {
                draftValue = clamped(next)
            }
        }
        .onDisappear {
            commit()
        }
    }

    private func clamped(_ value: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    private func commit() {
        let next = clamped(draftValue)
        draftValue = next
        guard value != next else { return }
        value = next
        onCommit()
    }
}

struct PassStepper: View {
    @Binding var passes: Int

    var body: some View {
        Stepper("Passes \(passes)", value: Binding {
            passes
        } set: {
            passes = min(ProjectPhoto.maximumPasses, max(1, $0))
        }, in: 1...ProjectPhoto.maximumPasses)
    }
}

private enum PhotoEditTool: String, CaseIterable {
    case magic = "Magic"
    case color = "Color"
    case eraser = "Erase"
    case levels = "Levels"
    case outline = "Outline"
}

private enum BackdropShadeMode: CaseIterable, Hashable {
    case automatic
    case normal
    case inverted
}

private enum BackdropShadeTransitionStyle {
    case forward
    case backward
    case blend
}

private struct BackdropShadeTransition {
    var startedAt: Date
    var duration: TimeInterval
    var from: (space: Double, edge: Double)
    var to: (space: Double, edge: Double)
    var style: BackdropShadeTransitionStyle
    var affectsToggle = true
}

private extension View {
    @ViewBuilder func photoEditorCover<Item: Identifiable, Content: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, content: content)
        #elseif os(macOS)
        sheet(item: item, content: content)
        #endif
    }
}

@MainActor
private final class PhotoEditDraftModel: ObservableObject {
    private(set) var bitmap: PhotoBitmap?
    private(set) var previewBase: PhotoBitmap?
    private(set) var previewPoint: CGPoint?
    private(set) var revision = 0

    var displayBitmap: PhotoBitmap? {
        bitmap
    }

    func clear() {
        bitmap = nil
        previewBase = nil
        previewPoint = nil
        changed()
    }

    func load(_ bitmap: PhotoBitmap) {
        previewBase = nil
        previewPoint = nil
        replaceBitmap(bitmap)
    }

    func replaceBitmap(_ bitmap: PhotoBitmap) {
        self.bitmap = bitmap
        changed()
    }

    func previewMagic(at point: CGPoint, fuzziness: Double, minimumBridgePixels: Int) {
        if previewBase == nil { previewBase = bitmap }
        previewPoint = point
        previewMagic(fuzziness: fuzziness, minimumBridgePixels: minimumBridgePixels)
    }

    func previewMagic(fuzziness: Double, minimumBridgePixels: Int) {
        guard let base = previewBase, let previewPoint else { return }
        replaceBitmap(PhotoEditor.magicErase(base, x: Int(previewPoint.x.rounded()), y: Int(previewPoint.y.rounded()), fuzziness: Int(fuzziness.rounded()), minimumBridgePixels: minimumBridgePixels))
    }

    func previewColor(at point: CGPoint, fuzziness: Double) {
        if previewBase == nil { previewBase = bitmap }
        previewPoint = point
        previewColor(fuzziness: fuzziness)
    }

    func previewColor(fuzziness: Double) {
        guard let base = previewBase, let previewPoint else { return }
        replaceBitmap(PhotoEditor.colorErase(base, x: Int(previewPoint.x.rounded()), y: Int(previewPoint.y.rounded()), fuzziness: Int(fuzziness.rounded())))
    }

    func previewLevels(boundaries: [UInt8]) {
        if previewBase == nil { previewBase = bitmap }
        guard let base = previewBase else { return }
        replaceBitmap(PhotoEditor.levels(base, boundaries: boundaries))
    }

    func cancelPreview() {
        if let base = previewBase {
            replaceBitmap(base)
        }
        previewBase = nil
        previewPoint = nil
        objectWillChange.send()
    }

    func finishPreview() {
        previewBase = nil
        previewPoint = nil
        objectWillChange.send()
    }

    func pngData() -> Data? {
        bitmap.flatMap(PhotoEditor.pngData)
    }

    func loadHistory(_ data: Data) -> Bool {
        guard let bitmap = try? PhotoEditor.bitmap(from: data) else { return false }
        load(bitmap)
        return true
    }

    private func changed() {
        revision += 1
        objectWillChange.send()
    }
}

private struct PhotoEditScreen: View {
    @Environment(\.dismiss) private var dismiss
    var photo: ProjectPhoto
    var sourcePath: String?
    var canUndo: Bool
    var canRedo: Bool
    var onCommit: (Data, String, [String: Double]) -> (canUndo: Bool, canRedo: Bool)
    var onUndo: () -> (data: Data?, canUndo: Bool, canRedo: Bool)
    var onRedo: () -> (data: Data?, canUndo: Bool, canRedo: Bool)
    var onCreateOutline: (VectorOutline, Double, Bool) -> Void = { _, _, _ in }
    var testMagicTap: CGPoint?
    var testUndoAfterMagic = false
    var onBitmapChange: (PhotoBitmap) -> Void = { _ in }
    @State private var tool = PhotoEditTool.magic
    @State private var fuzziness = 24.0
    @State private var magicMinimumBridgePixels = 0.0
    @State private var eraseRadiusPercent = 3.0
    @State private var erasePreviewRadiusPercent: Double?
    @State private var outlineOffsetMM = 2.0
    @State private var outlineIncludesInterior = false
    @State private var outlinePreview: VectorOutline?
    @State private var levelCount = 3
    @State private var boundaries: [Double] = [85, 170]
    @State private var levelPreviewBase: (count: Int, boundaries: [Double])?
    @State private var undoAvailable = false
    @State private var redoAvailable = false
    @StateObject private var draft = PhotoEditDraftModel()
    @State private var didRunTestMagicTap = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                PhotoEditSurface(bitmap: draft.displayBitmap, bitmapRevision: draft.revision, tool: tool, eraseRadiusPixels: eraseRadiusPixels, erasePreviewRadiusPixels: erasePreviewRadiusPixels, outlinePaths: editorOutlinePaths) { x, y in
                    tapImage(x: x, y: y)
                } onErase: { points in
                    erase(points: points)
                }
                .accessibilityIdentifier("photo.editor.surface")

                VStack(alignment: .leading, spacing: 10) {
                    Picker("Tool", selection: $tool) {
                        ForEach(PhotoEditTool.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch tool {
                    case .magic:
                        magicControls
                    case .color:
                        colorControls
                    case .eraser:
                        SettingSlider("Radius", value: $eraseRadiusPercent, range: 0.5...(100.0 / 3.0), suffix: "%", onDraftChange: { value, editing in
                            erasePreviewRadiusPercent = editing ? value : nil
                        })
                    case .levels:
                        levelsControls
                    case .outline:
                        outlineControls
                    }
                }
                .padding(12)
                .background(cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12)
            }
            .background(screenBackground)
            .navigationTitle(photo.name)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        undoEdit()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!undoAvailable)

                    Button {
                        redoEdit()
                    } label: {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                    .disabled(!redoAvailable)
                }
            }
        }
        .onAppear {
            undoAvailable = canUndo
            redoAvailable = canRedo
            loadImage()
            publishBitmapChange()
            runTestMagicTap()
        }
        .onChange(of: photo.id) { _ in
            loadImage()
            publishBitmapChange()
            runTestMagicTap()
        }
        .onChange(of: draft.revision) { _ in publishBitmapChange() }
        .onChange(of: tool) { _ in
            erasePreviewRadiusPercent = nil
            if let levelPreviewBase {
                levelCount = levelPreviewBase.count
                boundaries = levelPreviewBase.boundaries
                self.levelPreviewBase = nil
            }
            draft.cancelPreview()
            outlinePreview = nil
            if tool == .outline {
                refreshOutlinePreview()
            }
        }
    }

    private var editorOutlinePaths: [LaserPath] {
        guard let outlinePreview else { return [] }
        let placement = photo.settings.placement
        return outlinePreview.paths.map { path in
            LaserPath(closed: path.closed, points: path.points.map { point in
                let x = outlinePreview.placement.xMM + point.x * outlinePreview.placement.widthMM
                let y = outlinePreview.placement.yMM + point.y * outlinePreview.placement.heightMM
                return Point(x: (x - placement.xMM) / placement.widthMM, y: (y - placement.yMM) / placement.heightMM)
            })
        }
    }

    private var eraseRadiusPixels: Double {
        eraseRadiusPixels(percent: eraseRadiusPercent)
    }

    private var magicBridgePixels: Int {
        max(0, Int(magicMinimumBridgePixels.rounded()))
    }

    private var erasePreviewRadiusPixels: Double? {
        erasePreviewRadiusPercent.map(eraseRadiusPixels(percent:))
    }

    private func eraseRadiusPixels(percent: Double) -> Double {
        guard let bitmap = draft.displayBitmap ?? draft.bitmap else { return 1 }
        return max(0.5, Double(min(bitmap.width, bitmap.height)) * percent / 100)
    }

    private var colorControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingSlider("Fuzziness", value: $fuzziness, range: 0...255, suffix: "")
                .onChange(of: fuzziness) { _ in previewColorSelection() }
            if draft.previewPoint != nil {
                previewActions(cancel: cancelColorSelection, apply: applyColorSelection)
            }
        }
    }

    private var magicControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingSlider("Fuzziness", value: $fuzziness, range: 0...255, suffix: "")
                .onChange(of: fuzziness) { _ in previewMagicSelection() }
            SettingSlider("Min Bridge", value: $magicMinimumBridgePixels, range: 0...20, suffix: "px")
                .onChange(of: magicMinimumBridgePixels) { _ in previewMagicSelection() }
            if draft.previewPoint != nil {
                previewActions(cancel: cancelMagicSelection, apply: applyMagicSelection)
            }
        }
    }

    private func previewActions(cancel: @escaping () -> Void, apply: @escaping () -> Void) -> some View {
        HStack {
            Button {
                cancel()
            } label: {
                Label("Cancel", systemImage: "xmark")
            }
            Spacer()
            Button {
                apply()
            } label: {
                Label("Apply", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var levelsControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper("Levels \(levelCount)", value: levelCountBinding, in: 2...8)
            ForEach(boundaries.indices, id: \.self) { index in
                SettingSlider("Boundary \(index + 1)", value: boundaryBinding(index), range: 0...255, suffix: "")
            }
            if levelPreviewBase != nil {
                previewActions(cancel: cancelLevels, apply: applyLevels)
            }
        }
    }

    private var outlineControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingSlider("Offset", value: $outlineOffsetMM, range: 0...10, suffix: "mm")
                .onChange(of: outlineOffsetMM) { _ in refreshOutlinePreview() }
            Toggle("Interior Traces", isOn: $outlineIncludesInterior)
                .onChange(of: outlineIncludesInterior) { _ in refreshOutlinePreview() }
            if outlinePreview != nil {
                previewActions(cancel: cancelOutline, apply: applyOutline)
            } else {
                Button {
                    refreshOutlinePreview()
                } label: {
                    Label("Preview", systemImage: "eye")
                }
            }
        }
    }

    private func loadImage() {
        levelPreviewBase = nil
        guard let sourcePath, let data = try? Data(contentsOf: URL(fileURLWithPath: sourcePath)), let bitmap = try? PhotoEditor.bitmap(from: data) else {
            draft.clear()
            return
        }
        draft.load(bitmap)
        resetBoundaries()
    }

    private func publishBitmapChange() {
        guard let bitmap = draft.displayBitmap else { return }
        onBitmapChange(bitmap)
    }

    private func runTestMagicTap() {
        guard let testMagicTap, !didRunTestMagicTap else { return }
        didRunTestMagicTap = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            tapImage(x: Double(testMagicTap.x), y: Double(testMagicTap.y))
            guard testUndoAfterMagic else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            applyMagicSelection()
            try? await Task.sleep(nanoseconds: 900_000_000)
            undoEdit()
        }
    }

    private func tapImage(x: Double, y: Double) {
        switch tool {
        case .magic:
            previewMagic(x: x, y: y)
        case .color:
            selectColor(x: x, y: y)
        case .eraser, .levels, .outline:
            break
        }
    }

    private func previewMagic(x: Double, y: Double) {
        draft.cancelPreview()
        draft.previewMagic(at: CGPoint(x: x, y: y), fuzziness: fuzziness, minimumBridgePixels: magicBridgePixels)
        publishBitmapChange()
    }

    private func previewMagicSelection() {
        draft.previewMagic(fuzziness: fuzziness, minimumBridgePixels: magicBridgePixels)
        publishBitmapChange()
    }

    private func applyMagicSelection() {
        guard let point = draft.previewPoint, let bitmap = draft.bitmap else { return }
        commitBitmap(bitmap, kind: "magicEraser", values: ["x": Double(point.x), "y": Double(point.y), "fuzziness": fuzziness, "minimumBridgePixels": Double(magicBridgePixels)])
    }

    private func cancelMagicSelection() {
        draft.cancelPreview()
    }

    private func selectColor(x: Double, y: Double) {
        draft.previewColor(at: CGPoint(x: x, y: y), fuzziness: fuzziness)
        publishBitmapChange()
    }

    private func previewColorSelection() {
        draft.previewColor(fuzziness: fuzziness)
        publishBitmapChange()
    }

    private func applyColorSelection() {
        guard let point = draft.previewPoint, let bitmap = draft.bitmap else { return }
        commitBitmap(bitmap, kind: "colorEraser", values: ["x": Double(point.x), "y": Double(point.y), "fuzziness": fuzziness])
    }

    private func cancelColorSelection() {
        draft.cancelPreview()
    }

    private func erase(points: [CGPoint]) {
        draft.cancelPreview()
        guard let first = points.first, let bitmap = draft.bitmap else { return }
        var edited = PhotoEditor.erase(bitmap, x: first.x, y: first.y, radius: eraseRadiusPixels)
        for (start, end) in zip(points, points.dropFirst()) {
            edited = PhotoEditor.eraseStroke(edited, from: start, to: end, radius: eraseRadiusPixels)
        }
        draft.replaceBitmap(edited)
        publishBitmapChange()
        commitBitmap(edited, kind: "manualEraser", values: ["radiusPercent": eraseRadiusPercent, "radiusPixels": eraseRadiusPixels])
    }

    private func previewLevels() {
        draft.previewLevels(boundaries: boundaries.map { UInt8(min(255, max(0, Int($0.rounded())))) })
        publishBitmapChange()
    }

    private func applyLevels() {
        guard let bitmap = draft.bitmap else { return }
        levelPreviewBase = nil
        commitBitmap(bitmap, kind: "levels", values: levelValues)
    }

    private func cancelLevels() {
        draft.cancelPreview()
        if let restore = levelPreviewBase {
            levelCount = restore.count
            boundaries = restore.boundaries
            levelPreviewBase = nil
        }
    }

    private func refreshOutlinePreview() {
        guard tool == .outline, let bitmap = draft.bitmap else { return }
        outlinePreview = VectorOutlineGenerator.outline(bitmap: bitmap, settings: photo.settings, offsetMM: outlineOffsetMM, includeInterior: outlineIncludesInterior)
    }

    private func applyOutline() {
        guard let outlinePreview else { return }
        onCreateOutline(outlinePreview, outlineOffsetMM, outlineIncludesInterior)
        self.outlinePreview = nil
        dismiss()
    }

    private func cancelOutline() {
        outlinePreview = nil
    }

    private func commitBitmap(_ bitmap: PhotoBitmap, kind: String, values: [String: Double]) {
        guard let data = PhotoEditor.pngData(from: bitmap) else { return }
        let history = onCommit(data, kind, values)
        undoAvailable = history.canUndo
        redoAvailable = history.canRedo
        draft.finishPreview()
    }

    private func loadHistory(_ data: Data?) {
        guard let data else { return }
        _ = draft.loadHistory(data)
        levelPreviewBase = nil
        resetBoundaries()
        if tool == .outline {
            refreshOutlinePreview()
        }
        publishBitmapChange()
    }

    private func undoEdit() {
        let result = onUndo()
        undoAvailable = result.canUndo
        redoAvailable = result.canRedo
        loadHistory(result.data)
    }

    private func redoEdit() {
        let result = onRedo()
        undoAvailable = result.canUndo
        redoAvailable = result.canRedo
        loadHistory(result.data)
    }

    private var levelValues: [String: Double] {
        var values = ["levels": Double(levelCount)]
        for index in boundaries.indices {
            values["boundary\(index + 1)"] = boundaries[index]
        }
        return values
    }

    private var levelCountBinding: Binding<Int> {
        Binding {
            levelCount
        } set: { value in
            beginLevelPreview()
            levelCount = value
            resetBoundaries()
            previewLevels()
        }
    }

    private func resetBoundaries() {
        boundaries = (1..<levelCount).map { Double($0) * 255 / Double(levelCount) }
    }

    private func beginLevelPreview() {
        if levelPreviewBase == nil {
            levelPreviewBase = (levelCount, boundaries)
        }
    }

    private func boundaryBinding(_ index: Int) -> Binding<Double> {
        Binding {
            boundaries[index]
        } set: { value in
            beginLevelPreview()
            let low = index == 0 ? 0 : boundaries[index - 1] + 1
            let high = index == boundaries.count - 1 ? 255 : boundaries[index + 1] - 1
            boundaries[index] = min(high, max(low, value))
            previewLevels()
        }
    }
}

private struct ObjectEditScreen: View {
    var photo: ProjectPhoto
    var photos: [ProjectPhoto]
    var store: FileAppStore?
    var canUndo: Bool
    var canRedo: Bool
    var onUpdate: (ProjectPhoto) -> (canUndo: Bool, canRedo: Bool)
    var onUndo: () -> (photo: ProjectPhoto?, canUndo: Bool, canRedo: Bool)
    var onRedo: () -> (photo: ProjectPhoto?, canUndo: Bool, canRedo: Bool)
    var onDuplicate: () -> Void
    var onDelete: () -> Void

    var body: some View {
        if photo.mode == .text {
            TextEditScreen(photo: photo, photos: photos, store: store, canUndo: canUndo, canRedo: canRedo, onUpdate: onUpdate, onUndo: onUndo, onRedo: onRedo, onDuplicate: onDuplicate, onDelete: onDelete)
        } else {
            VectorEditScreen(photo: photo, canUndo: canUndo, canRedo: canRedo, onUpdate: onUpdate, onUndo: onUndo, onRedo: onRedo, onDuplicate: onDuplicate, onDelete: onDelete)
        }
    }
}

private struct TextEditScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProjectPhoto
    @State private var textSettings: TextSettings
    var photos: [ProjectPhoto]
    var store: FileAppStore?
    var canUndo: Bool
    var canRedo: Bool
    var onUpdate: (ProjectPhoto) -> (canUndo: Bool, canRedo: Bool)
    var onUndo: () -> (photo: ProjectPhoto?, canUndo: Bool, canRedo: Bool)
    var onRedo: () -> (photo: ProjectPhoto?, canUndo: Bool, canRedo: Bool)
    var onDuplicate: () -> Void
    var onDelete: () -> Void
    @State private var undoAvailable: Bool
    @State private var redoAvailable: Bool
    @State private var suppressUpdate = false
    @State private var textRenderRevision = 0
    @State private var textRenderTask: Task<Void, Never>?
    @FocusState private var textFocus: TextEditFocus?

    init(photo: ProjectPhoto, photos: [ProjectPhoto], store: FileAppStore?, canUndo: Bool, canRedo: Bool, onUpdate: @escaping (ProjectPhoto) -> (canUndo: Bool, canRedo: Bool), onUndo: @escaping () -> (photo: ProjectPhoto?, canUndo: Bool, canRedo: Bool), onRedo: @escaping () -> (photo: ProjectPhoto?, canUndo: Bool, canRedo: Bool), onDuplicate: @escaping () -> Void, onDelete: @escaping () -> Void) {
        _draft = State(initialValue: photo)
        _textSettings = State(initialValue: photo.resolvedTextSettings)
        _undoAvailable = State(initialValue: canUndo)
        _redoAvailable = State(initialValue: canRedo)
        self.photos = photos
        self.store = store
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.onUpdate = onUpdate
        self.onUndo = onUndo
        self.onRedo = onRedo
        self.onDuplicate = onDuplicate
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextPlacementSurface(draft: $draft, photos: photos, store: store, onTap: dismissTextEntry)
                    .frame(maxWidth: .infinity)
                    .frame(height: 360)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionCard("Text") {
                            TextEditor(text: textValueBinding)
                                .font(.system(size: 22))
                                .focused($textFocus, equals: .body)
                                .frame(minHeight: 116)
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .background(Color.secondary.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            TextFontPicker(selection: textFontBinding, fonts: fontOptions, onOpen: dismissTextEntry)
                            SettingSlider("Size", value: textDoubleBinding(\.fontSize), range: 4...96, suffix: "pt")
                            SettingSlider("Letter Spacing", value: textDoubleBinding(\.letterSpacing), range: -5...20, suffix: "pt")
                            SettingSlider("Line Spacing", value: textDoubleBinding(\.leading), range: 0...40, suffix: "pt")
                            Picker("Align", selection: textAlignmentBinding) {
                                Text("Left").tag(LaserTextAlignment.left)
                                Text("Center").tag(LaserTextAlignment.center)
                                Text("Right").tag(LaserTextAlignment.right)
                            }
                            .pickerStyle(.segmented)
                        }

                        SectionCard("Placement") {
                            HStack(spacing: 8) {
                                CompactNumberField("X", value: placementBinding(\.xMM))
                                CompactNumberField("Y", value: placementBinding(\.yMM))
                                CompactNumberField("W", value: placementBinding(\.widthMM))
                                CompactNumberField("H", value: placementBinding(\.heightMM))
                            }
                            CompactNumberField("Rotation", value: placementBinding(\.rotationDegrees))
                        }

                        vectorSettings
                    }
                    .padding(16)
                }
                .dismissesKeyboardOnScroll()
            }
            .background(screenBackground)
            .navigationTitle(draft.name)
            .inlineNavigationTitle()
            .toolbar {
                editorToolbar
            }
        }
        .onChange(of: draft) { _ in
            guard !suppressUpdate else {
                suppressUpdate = false
                return
            }
            let history = onUpdate(draft)
            undoAvailable = history.canUndo
            redoAvailable = history.canRedo
        }
        .onAppear {
            undoAvailable = canUndo
            redoAvailable = canRedo
            let before = draft
            suppressUpdate = true
            textSettings = draft.resolvedTextSettings
            flushTextRender()
            if draft == before {
                suppressUpdate = false
            }
        }
        .onDisappear {
            textRenderTask?.cancel()
        }
    }

    private var vectorSettings: some View {
        SectionCard("Vector") {
            PassStepper(passes: passBinding)
            Picker("Laser", selection: laserBinding) {
                Text("Blue").tag(Laser.blue)
                Text("IR").tag(Laser.infrared)
            }
            .pickerStyle(.segmented)
            SettingSlider("Speed", value: vectorBinding(\.speedMMPerSecond), range: 1...400, suffix: "mm/s")
            SettingSlider("Power", value: vectorBinding(\.powerPercent), range: 0...100, suffix: "%")
        }
    }

    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") {
                commitTextRenderNow()
                dismiss()
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                undoEdit()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!undoAvailable)

            Button {
                redoEdit()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!redoAvailable)

            Button {
                commitTextRenderNow()
                onDuplicate()
                dismiss()
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) {
                onDelete()
                dismiss()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func undoEdit() {
        applyHistory(onUndo())
    }

    private func redoEdit() {
        applyHistory(onRedo())
    }

    private func applyHistory(_ result: (photo: ProjectPhoto?, canUndo: Bool, canRedo: Bool)) {
        undoAvailable = result.canUndo
        redoAvailable = result.canRedo
        guard let photo = result.photo else { return }
        if draft != photo {
            textRenderTask?.cancel()
            textRenderRevision += 1
            textSettings = photo.resolvedTextSettings
            suppressUpdate = true
            draft = photo
        }
        dismissTextEntry()
    }

    private func dismissTextEntry() {
        textFocus = nil
        dismissKeyboard()
    }

    private var textValueBinding: Binding<String> {
        Binding {
            textSettings.text
        } set: { value in
            updateTextSettings { $0.text = value }
        }
    }

    private var fontOptions: [String] {
        let current = textSettings.fontFamily
        return TextFontCatalog.names.contains(current) ? TextFontCatalog.names : [current] + TextFontCatalog.names
    }

    private var textFontBinding: Binding<String> {
        Binding {
            textSettings.fontFamily
        } set: { value in
            updateTextSettings { $0.fontFamily = value }
        }
    }

    private func textDoubleBinding(_ keyPath: WritableKeyPath<TextSettings, Double>) -> Binding<Double> {
        Binding {
            textSettings[keyPath: keyPath]
        } set: { value in
            updateTextSettings { $0[keyPath: keyPath] = value }
        }
    }

    private var textAlignmentBinding: Binding<LaserTextAlignment> {
        Binding {
            textSettings.alignment
        } set: { value in
            updateTextSettings { $0.alignment = value }
        }
    }

    private func placementBinding(_ keyPath: WritableKeyPath<PrintPlacement, Double>) -> Binding<Double> {
        Binding {
            let value = draft.printPlacement[keyPath: keyPath]
            return keyPath == \.rotationDegrees ? normalizedRotationDegrees(value) : value
        } set: { value in
            if keyPath == \.rotationDegrees {
                draft.printPlacement = RasterGenerator.sizeConstrained(rotatedPlacement(draft.printPlacement, object: draft, degrees: value))
            } else {
                draft.printPlacement[keyPath: keyPath] = value
            }
            scheduleTextRender()
        }
    }

    private func updateTextSettings(_ edit: (inout TextSettings) -> Void) {
        edit(&textSettings)
        scheduleTextRender()
    }

    private func scheduleTextRender() {
        guard draft.mode == .text else { return }
        textRenderRevision += 1
        let revision = textRenderRevision
        let settings = textSettings
        let placement = draft.printPlacement
        textRenderTask?.cancel()
        textRenderTask = Task {
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            let paths = await Task.detached(priority: .userInitiated) {
                TextVectorGenerator.paths(for: settings, placement: placement)
            }.value
            await MainActor.run {
                guard textRenderRevision == revision else { return }
                applyTextRender(settings: settings, paths: paths)
            }
        }
    }

    private func flushTextRender() {
        guard draft.mode == .text else { return }
        textRenderTask?.cancel()
        textRenderRevision += 1
        applyTextRender(settings: textSettings, paths: TextVectorGenerator.paths(for: textSettings, placement: draft.printPlacement))
    }

    private func commitTextRenderNow() {
        let before = draft
        suppressUpdate = true
        flushTextRender()
        guard draft != before else {
            suppressUpdate = false
            return
        }
        let history = onUpdate(draft)
        undoAvailable = history.canUndo
        redoAvailable = history.canRedo
    }

    private func applyTextRender(settings: TextSettings, paths: [LaserPath]) {
        guard draft.mode == .text else { return }
        let name = settings.text.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.name = name.isEmpty ? "Text" : name
        draft.textSettings = settings
        draft.vectorPaths = paths
    }

    private func vectorBinding(_ keyPath: WritableKeyPath<VectorSettings, Double>) -> Binding<Double> {
        Binding {
            draft.resolvedVectorSettings[keyPath: keyPath]
        } set: { value in
            var vector = draft.resolvedVectorSettings
            vector[keyPath: keyPath] = value
            draft.vectorSettings = vector
            draft.settings.placement = vector.placement
        }
    }

    private var passBinding: Binding<Int> {
        Binding {
            draft.passes
        } set: {
            draft.passes = min(ProjectPhoto.maximumPasses, max(1, $0))
        }
    }

    private var laserBinding: Binding<Laser> {
        Binding {
            draft.resolvedVectorSettings.laser
        } set: { laser in
            var vector = draft.resolvedVectorSettings
            vector.laser = laser
            draft.vectorSettings = vector
            draft.settings.placement = vector.placement
        }
    }
}

private enum TextEditFocus: Hashable {
    case body
}

private enum TextFontCatalog {
    static let names: [String] = {
        let preferred = ["Helvetica", "Arial", "Avenir Next", "Futura", "Georgia", "Gill Sans", "Menlo", "Times New Roman"]
        #if os(iOS)
        let available = UIFont.familyNames.sorted()
        #elseif os(macOS)
        let available = NSFontManager.shared.availableFontFamilies.sorted()
        #else
        let available: [String] = []
        #endif
        return preferred + available.filter { !preferred.contains($0) }
    }()
}

private struct TextFontPicker: View {
    @Binding var selection: String
    var fonts: [String]
    var onOpen: () -> Void = {}
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 6) {
            Button {
                onOpen()
                withAnimation(.easeInOut(duration: 0.15)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Text("Font")
                        .foregroundStyle(.secondary)
                    Text(selection)
                        .lineLimit(1)
                    Spacer()
                    Text("Sample")
                        .font(.custom(selection, size: 18))
                        .lineLimit(1)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(fonts, id: \.self) { font in
                            Button {
                                selection = font
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    expanded = false
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Text(font)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("Sample")
                                        .font(.custom(font, size: 20))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(selection == font ? Color.accentColor.opacity(0.14) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 240)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct TextPlacementSurface: View {
    @Binding var draft: ProjectPhoto
    var photos: [ProjectPhoto]
    var store: FileAppStore?
    var onTap: () -> Void = {}

    var body: some View {
        GeometryReader { proxy in
            let scale = Double(min(proxy.size.width, proxy.size.height) - 24) / RasterGenerator.workAreaMM
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let placement = draft.printPlacement
            let origin = CGPoint(
                x: center.x - CGFloat((placement.xMM + placement.widthMM / 2) * scale),
                y: center.y - CGFloat((placement.yMM + placement.heightMM / 2) * scale)
            )
            ZStack {
                Color.secondary.opacity(0.035)
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.045))
                        .overlay(Rectangle().stroke(Color.secondary.opacity(0.18), lineWidth: 1))
                    Canvas { context, size in
                        var grid = Path()
                        let pitch = size.width / 11.5
                        for step in 0...11 {
                            let p = CGFloat(step) * pitch
                            grid.move(to: CGPoint(x: p, y: 0))
                            grid.addLine(to: CGPoint(x: p, y: size.height))
                            grid.move(to: CGPoint(x: 0, y: p))
                            grid.addLine(to: CGPoint(x: size.width, y: p))
                        }
                        context.stroke(grid, with: .color(Color.secondary.opacity(0.10)), lineWidth: 0.5)
                    }
                    ForEach(photos.filter { $0.id != draft.id }) { photo in
                        backgroundObject(photo, scale: scale)
                    }
                }
                .frame(width: CGFloat(RasterGenerator.workAreaMM * scale), height: CGFloat(RasterGenerator.workAreaMM * scale))
                .offset(x: origin.x, y: origin.y)
                .opacity(0.45)

                currentText(width: CGFloat(placement.widthMM * scale), height: CGFloat(placement.heightMM * scale))
                    .position(center)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
            #if os(iOS)
            .overlay {
                TextPlacementGestureLayer(placement: placementBinding, scale: scale, onTap: onTap)
            }
            #endif
        }
    }

    private var placementBinding: Binding<PrintPlacement> {
        Binding {
            draft.printPlacement
        } set: { placement in
            draft.printPlacement = RasterGenerator.sizeConstrained(placement)
            draft.vectorPaths = TextVectorGenerator.paths(for: draft.resolvedTextSettings, placement: draft.printPlacement)
        }
    }

    private func currentText(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.purple.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                .frame(width: max(20, width), height: max(20, height))
            VectorPathShape(paths: draft.vectorPaths)
                .stroke(Color.purple, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                .frame(width: max(20, width), height: max(20, height))
        }
    }

    private func backgroundObject(_ photo: ProjectPhoto, scale: Double) -> some View {
        let placement = photo.printPlacement
        return Group {
            if photo.mode == .vector || photo.mode == .text {
                VectorPathShape(paths: photo.vectorPaths)
                    .stroke(photo.mode == .text ? Color.purple : Color.blue, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            } else {
                StoredImage(path: store?.imageURL(for: photo)?.path, stretch: true)
                    .clipped()
            }
        }
        .frame(width: CGFloat(placement.widthMM * scale), height: CGFloat(placement.heightMM * scale))
        .rotationEffect(.degrees(placement.rotationDegrees), anchor: .topLeading)
        .offset(x: CGFloat(placement.xMM * scale), y: CGFloat(placement.yMM * scale))
    }
}

#if os(iOS)
private struct TextPlacementGestureLayer: UIViewRepresentable {
    @Binding var placement: PrintPlacement
    var scale: Double
    var onTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        pinch.delegate = context.coordinator
        tap.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TextPlacementGestureLayer
        private var start = PrintPlacement()

        init(_ parent: TextPlacementGestureLayer) {
            self.parent = parent
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began {
                start = parent.placement
            }
            let translation = recognizer.translation(in: recognizer.view)
            var next = start
            next.xMM -= translation.x / max(1, parent.scale)
            next.yMM -= translation.y / max(1, parent.scale)
            parent.placement = RasterGenerator.sizeConstrained(next)
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            if recognizer.state == .began {
                start = parent.placement
            }
            let center = Point(x: start.xMM + start.widthMM / 2, y: start.yMM + start.heightMM / 2)
            var next = start
            next.widthMM = max(1, min(RasterGenerator.workAreaMM, start.widthMM * recognizer.scale))
            next.heightMM = max(1, min(RasterGenerator.workAreaMM, start.heightMM * recognizer.scale))
            next.xMM = center.x - next.widthMM / 2
            next.yMM = center.y - next.heightMM / 2
            parent.placement = RasterGenerator.sizeConstrained(next)
        }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            if recognizer.state == .ended {
                parent.onTap()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif

private struct VectorEditScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProjectPhoto
    @State private var drawing: EditableVectorDrawing
    @State private var mode = VectorEditMode.draw
    @State private var eraseStyle = VectorEraseStyle.brush
    @State private var eraseRadiusPercent = 3.0
    @State private var smoothnessPercent: Double
    @State private var accuracyPercent: Double
    @State private var selected: [EditableVectorSelection] = []
    @State private var fitTask: Task<Void, Never>?
    @State private var fitRevision = 0
    var canUndo: Bool
    var canRedo: Bool
    var onUpdate: (ProjectPhoto) -> (canUndo: Bool, canRedo: Bool)
    var onUndo: () -> (photo: ProjectPhoto?, canUndo: Bool, canRedo: Bool)
    var onRedo: () -> (photo: ProjectPhoto?, canUndo: Bool, canRedo: Bool)
    var onDuplicate: () -> Void
    var onDelete: () -> Void
    @State private var undoAvailable: Bool
    @State private var redoAvailable: Bool
    @State private var suppressUpdate = false

    init(photo: ProjectPhoto, canUndo: Bool, canRedo: Bool, onUpdate: @escaping (ProjectPhoto) -> (canUndo: Bool, canRedo: Bool), onUndo: @escaping () -> (photo: ProjectPhoto?, canUndo: Bool, canRedo: Bool), onRedo: @escaping () -> (photo: ProjectPhoto?, canUndo: Bool, canRedo: Bool), onDuplicate: @escaping () -> Void, onDelete: @escaping () -> Void) {
        _draft = State(initialValue: photo)
        let drawing = photo.vectorDrawing ?? VectorDrawingGenerator.drawing(paths: photo.vectorPaths)
        _drawing = State(initialValue: drawing)
        _smoothnessPercent = State(initialValue: drawing.smoothness * 100)
        _accuracyPercent = State(initialValue: drawing.accuracy * 100)
        _undoAvailable = State(initialValue: canUndo)
        _redoAvailable = State(initialValue: canRedo)
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.onUpdate = onUpdate
        self.onUndo = onUndo
        self.onRedo = onRedo
        self.onDuplicate = onDuplicate
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionCard(mode == .erase ? "Erase" : mode == .points ? "Points" : "Draw") {
                        EditableVectorPad(drawing: drawing, mode: mode, eraseRadius: eraseRadius, selected: $selected) { segment in
                            setDrawing(VectorDrawingGenerator.appending(segment, to: drawing))
                        } onErase: { stroke in
                            setDrawing(VectorDrawingGenerator.erasing(drawing, stroke: stroke, radius: eraseRadius))
                        } onMoveNode: { selection, point in
                            moveNode(selection, to: point)
                        } onMoveTangent: { selection, tangent in
                            moveTangent(selection, to: tangent)
                        }
                        .frame(height: 340)
                        HStack {
                            Picker("Mode", selection: $mode) {
                                Label("Draw", systemImage: "pencil.tip").tag(VectorEditMode.draw)
                                Label("Erase", systemImage: "eraser").tag(VectorEditMode.erase)
                                Label("Points", systemImage: "point.3.connected.trianglepath.dotted").tag(VectorEditMode.points)
                            }
                            .pickerStyle(.segmented)
                            Button {
                                selected = []
                                setDrawing(EditableVectorDrawing(smoothness: drawing.smoothness, accuracy: drawing.accuracy))
                            } label: {
                                Label("Clear", systemImage: "trash")
                            }
                        }
                        if mode == .erase {
                            Divider()
                            Picker("Erase", selection: $eraseStyle) {
                                Text("Line").tag(VectorEraseStyle.line)
                                Text("Brush").tag(VectorEraseStyle.brush)
                            }
                            .pickerStyle(.segmented)
                            if eraseStyle == .brush {
                                SettingSlider("Radius", value: $eraseRadiusPercent, range: 0.5...12, suffix: "%")
                            }
                        }
                    }

                    Text("\(draft.vectorPaths.count) path\(draft.vectorPaths.count == 1 ? "" : "s") · \(pointCount) points · \(lengthMM, specifier: "%.1f") mm")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    SectionCard("Vector") {
                        PassStepper(passes: passBinding)
                        SettingSlider("Smoothness", value: smoothnessBinding, range: 0...100, suffix: "%")
                        SettingSlider("Accuracy", value: accuracyBinding, range: 0...100, suffix: "%")
                        HStack {
                            Button {
                                connectSelected()
                            } label: {
                                Label("Connect", systemImage: "link")
                            }
                            .disabled(selected.count != 2)
                            Button {
                                disconnectSelected()
                            } label: {
                                Label("Disconnect", systemImage: "link.badge.plus")
                            }
                            .disabled(selected.count != 1)
                        }
                        Picker("Laser", selection: laserBinding) {
                            Text("Blue").tag(Laser.blue)
                            Text("IR").tag(Laser.infrared)
                        }
                        .pickerStyle(.segmented)
                        SettingSlider("Speed", value: vectorBinding(\.speedMMPerSecond), range: 1...400, suffix: "mm/s")
                        SettingSlider("Power", value: vectorBinding(\.powerPercent), range: 0...100, suffix: "%")
                        Button {
                            setDrawing(VectorDrawingGenerator.drawing(rawSegments: drawing.rawSegments.map { Array($0.reversed()) }, smoothness: drawing.smoothness, accuracy: drawing.accuracy))
                        } label: {
                            Label("Reverse Path", systemImage: "arrow.left.arrow.right")
                        }
                    }
                }
                .padding(16)
            }
            .background(screenBackground)
            .navigationTitle(draft.name)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        undoEdit()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!undoAvailable)

                    Button {
                        redoEdit()
                    } label: {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                    .disabled(!redoAvailable)

                    Button {
                        onDuplicate()
                        dismiss()
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .onChange(of: draft) { _ in
            guard !suppressUpdate else {
                suppressUpdate = false
                return
            }
            let history = onUpdate(draft)
            undoAvailable = history.canUndo
            redoAvailable = history.canRedo
        }
        .onAppear {
            undoAvailable = canUndo
            redoAvailable = canRedo
            let before = draft
            suppressUpdate = true
            setDrawing(drawing)
            if draft == before {
                suppressUpdate = false
            }
        }
    }

    private var pointCount: Int {
        draft.vectorPaths.reduce(0) { $0 + $1.points.count }
    }

    private var lengthMM: Double {
        VectorGCodeGenerator.length(paths: draft.vectorPaths, settings: draft.resolvedVectorSettings)
    }

    private var eraseRadius: Double {
        eraseStyle == .line ? 0 : eraseRadiusPercent / 100
    }

    private func undoEdit() {
        applyHistory(onUndo())
    }

    private func redoEdit() {
        applyHistory(onRedo())
    }

    private func applyHistory(_ result: (photo: ProjectPhoto?, canUndo: Bool, canRedo: Bool)) {
        undoAvailable = result.canUndo
        redoAvailable = result.canRedo
        guard let photo = result.photo else { return }
        if draft != photo {
            suppressUpdate = true
            draft = photo
        }
        drawing = photo.vectorDrawing ?? VectorDrawingGenerator.drawing(paths: photo.vectorPaths)
        smoothnessPercent = drawing.smoothness * 100
        accuracyPercent = drawing.accuracy * 100
        selected = []
        fitRevision += 1
        fitTask?.cancel()
    }

    private var smoothnessBinding: Binding<Double> {
        Binding {
            smoothnessPercent
        } set: { value in
            smoothnessPercent = value
            scheduleFit()
        }
    }

    private var accuracyBinding: Binding<Double> {
        Binding {
            accuracyPercent
        } set: { value in
            accuracyPercent = value
            scheduleFit()
        }
    }

    private func vectorBinding(_ keyPath: WritableKeyPath<VectorSettings, Double>) -> Binding<Double> {
        Binding {
            draft.resolvedVectorSettings[keyPath: keyPath]
        } set: { value in
            var vector = draft.resolvedVectorSettings
            vector[keyPath: keyPath] = value
            draft.vectorSettings = vector
            draft.settings.placement = vector.placement
        }
    }

    private var passBinding: Binding<Int> {
        Binding {
            draft.passes
        } set: {
            draft.passes = min(ProjectPhoto.maximumPasses, max(1, $0))
        }
    }

    private var laserBinding: Binding<Laser> {
        Binding {
            draft.resolvedVectorSettings.laser
        } set: { laser in
            var vector = draft.resolvedVectorSettings
            vector.laser = laser
            draft.vectorSettings = vector
            draft.settings.placement = vector.placement
        }
    }

    private func setDrawing(_ next: EditableVectorDrawing) {
        fitRevision += 1
        fitTask?.cancel()
        let fitted = VectorDrawingGenerator.fitted(next)
        smoothnessPercent = fitted.smoothness * 100
        accuracyPercent = fitted.accuracy * 100
        applyFittedDrawing(fitted, paths: VectorDrawingGenerator.paths(for: fitted))
    }

    private func scheduleFit() {
        fitRevision += 1
        let revision = fitRevision
        let raw = drawing.rawSegments
        let smoothness = smoothnessPercent / 100
        let accuracy = accuracyPercent / 100
        fitTask?.cancel()
        fitTask = Task {
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                let drawing = VectorDrawingGenerator.drawing(rawSegments: raw, smoothness: smoothness, accuracy: accuracy)
                return (drawing, VectorDrawingGenerator.paths(for: drawing))
            }.value
            await MainActor.run {
                guard fitRevision == revision else { return }
                applyFittedDrawing(result.0, paths: result.1)
            }
        }
    }

    private func applyFittedDrawing(_ fitted: EditableVectorDrawing, paths: [LaserPath]) {
        drawing = fitted
        draft.vectorDrawing = fitted
        draft.vectorPaths = paths
    }

    private func moveNode(_ selection: EditableVectorSelection, to point: Point) {
        var next = VectorDrawingGenerator.fitted(drawing)
        guard next.nodes.indices.contains(selection.segmentIndex), next.nodes[selection.segmentIndex].indices.contains(selection.nodeIndex) else { return }
        next.nodes[selection.segmentIndex][selection.nodeIndex].point = point
        next.rawSegments = next.nodes.map { $0.map(\.point) }
        setDrawing(next)
    }

    private func moveTangent(_ selection: EditableVectorSelection, to tangent: Point) {
        var next = VectorDrawingGenerator.fitted(drawing)
        guard next.nodes.indices.contains(selection.segmentIndex), next.nodes[selection.segmentIndex].indices.contains(selection.nodeIndex) else { return }
        next.nodes[selection.segmentIndex][selection.nodeIndex].tangent = tangent
        setDrawing(next)
    }

    private func connectSelected() {
        guard selected.count == 2 else { return }
        setDrawing(VectorDrawingGenerator.connect(drawing, selected[0], selected[1]))
        selected = []
    }

    private func disconnectSelected() {
        guard let first = selected.first else { return }
        setDrawing(VectorDrawingGenerator.disconnect(drawing, at: first))
        selected = []
    }
}

private enum VectorEditMode: Hashable {
    case draw
    case erase
    case points
}

private enum VectorEraseStyle: Hashable {
    case line
    case brush
}

private struct EditableVectorPad: View {
    var drawing: EditableVectorDrawing
    var mode: VectorEditMode
    var eraseRadius: Double
    @Binding var selected: [EditableVectorSelection]
    var onDraw: ([Point]) -> Void
    var onErase: ([Point]) -> Void
    var onMoveNode: (EditableVectorSelection, Point) -> Void
    var onMoveTangent: (EditableVectorSelection, Point) -> Void
    @State private var currentPoints: [Point] = []

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.06))
                VectorPathShape(paths: VectorDrawingGenerator.paths(for: drawing))
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .padding(8)
                if mode == .draw {
                    VectorPathShape(paths: currentPath)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .padding(8)
                } else if mode == .erase {
                    VectorPathShape(paths: currentPath)
                        .stroke(Color.red.opacity(0.65), style: StrokeStyle(lineWidth: eraserWidth(size: proxy.size), lineCap: .round, lineJoin: .round))
                        .padding(8)
                }
                if mode == .points {
                    nodeOverlay(size: inset(proxy.size))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard mode == .draw || mode == .erase else { return }
                    let point = normalized(value.location, size: proxy.size)
                    if shouldAppend(point, to: currentPoints) {
                        currentPoints.append(point)
                    }
                }
                .onEnded { _ in
                    if mode == .draw {
                        onDraw(currentPoints)
                    } else if mode == .erase {
                        onErase(currentPoints)
                    }
                    currentPoints = []
                }
            )
        }
    }

    private var currentPath: [LaserPath] {
        currentPoints.count > 1 ? [LaserPath(closed: false, points: currentPoints)] : []
    }

    private func nodeOverlay(size: CGSize) -> some View {
        ZStack {
            ForEach(Array(drawing.nodes.enumerated()), id: \.offset) { segmentIndex, nodes in
                ForEach(Array(nodes.enumerated()), id: \.offset) { nodeIndex, node in
                    let selection = EditableVectorSelection(segmentIndex: segmentIndex, nodeIndex: nodeIndex)
                    nodeView(selection: selection, node: node, size: size)
                }
            }
            if selected.count == 1, let selection = selected.first, let node = node(selection) {
                tangentView(selection: selection, node: node, size: size)
            }
        }
        .padding(8)
    }

    private func nodeView(selection: EditableVectorSelection, node: EditableVectorNode, size: CGSize) -> some View {
        Circle()
            .fill(selected.contains(selection) ? Color.accentColor : Color.white)
            .overlay(Circle().stroke(Color.blue, lineWidth: 2))
            .frame(width: 18, height: 18)
            .position(cg(node.point, size: size))
            .highPriorityGesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    select(selection)
                    onMoveNode(selection, normalized(value.location, size: size))
                }
            )
            .onTapGesture {
                select(selection)
            }
    }

    private func tangentView(selection: EditableVectorSelection, node: EditableVectorNode, size: CGSize) -> some View {
        let tangent = node.tangent ?? Point(x: 0.12, y: 0)
        let handle = Point(x: node.point.x + tangent.x, y: node.point.y + tangent.y)
        return ZStack {
            Path { path in
                path.move(to: cg(node.point, size: size))
                path.addLine(to: cg(handle, size: size))
            }
            .stroke(Color.accentColor.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            Circle()
                .fill(Color.accentColor)
                .frame(width: 16, height: 16)
                .position(cg(handle, size: size))
                .highPriorityGesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let point = normalized(value.location, size: size)
                        onMoveTangent(selection, Point(x: point.x - node.point.x, y: point.y - node.point.y))
                    }
                )
        }
    }

    private func select(_ selection: EditableVectorSelection) {
        if selected.contains(selection) {
            selected.removeAll { $0 == selection }
        } else {
            selected.append(selection)
            if selected.count > 2 {
                selected.removeFirst(selected.count - 2)
            }
        }
    }

    private func node(_ selection: EditableVectorSelection) -> EditableVectorNode? {
        guard drawing.nodes.indices.contains(selection.segmentIndex), drawing.nodes[selection.segmentIndex].indices.contains(selection.nodeIndex) else { return nil }
        return drawing.nodes[selection.segmentIndex][selection.nodeIndex]
    }

    private func normalized(_ point: CGPoint, size: CGSize) -> Point {
        Point(x: min(1, max(0, (point.x - 8) / max(1, size.width - 16))), y: min(1, max(0, (point.y - 8) / max(1, size.height - 16))))
    }

    private func shouldAppend(_ point: Point, to points: [Point]) -> Bool {
        guard let last = points.last else { return true }
        return hypot(point.x - last.x, point.y - last.y) > 0.0015
    }

    private func inset(_ size: CGSize) -> CGSize {
        CGSize(width: max(1, size.width - 16), height: max(1, size.height - 16))
    }

    private func eraserWidth(size: CGSize) -> CGFloat {
        max(2, CGFloat(eraseRadius * 2) * min(inset(size).width, inset(size).height))
    }

    private func cg(_ point: Point, size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }
}

private struct PhotoEditSurface: View {
    var bitmap: PhotoBitmap?
    var bitmapRevision: Int
    var tool: PhotoEditTool
    var eraseRadiusPixels: Double
    var erasePreviewRadiusPixels: Double?
    var outlinePaths: [LaserPath] = []
    var rendersGestureLayer = true
    var onTap: (Double, Double) -> Void
    var onErase: ([CGPoint]) -> Void
    @State private var zoom = 1.0
    @State private var zoomStart = 1.0
    @State private var pan = CGSize.zero
    @State private var panStart = CGSize.zero
    @State private var backdropMode = BackdropShadeMode.automatic
    @State private var lockedBackdropInverted = false
    @State private var autoCycleStartedAt = Date()
    @State private var autoCycleStartsInverted = false
    @State private var backdropTransition: BackdropShadeTransition?
    @State private var loupePoint: CGPoint?
    @State private var loupeLocation: CGPoint?
    @State private var erasePoints: [CGPoint] = []

    var body: some View {
        GeometryReader { proxy in
            let surface = ZStack {
                let rect = bitmap.map { imageRect(in: proxy.size, bitmap: $0) }
                TransparencyBackdrop(imageRect: rect, mode: backdropMode, lockedInverted: lockedBackdropInverted, autoCycleStartedAt: autoCycleStartedAt, autoCycleStartsInverted: autoCycleStartsInverted, transition: backdropTransition)
                if let bitmap {
                    let rect = imageRect(in: proxy.size, bitmap: bitmap)
                    PhotoDataImage(bitmap: bitmap)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .id(bitmapRevision)
                    if !outlinePaths.isEmpty {
                        EditorOutlinePreview(paths: outlinePaths, imageRect: rect)
                    }
                    if tool == .eraser {
                        PhotoEraserOverlay(points: erasePoints, radiusPixels: eraseRadiusPixels, bitmap: bitmap, imageRect: rect)
                        if let erasePreviewRadiusPixels {
                            PhotoEraserSizePreview(radiusPixels: erasePreviewRadiusPixels, bitmap: bitmap, imageRect: rect)
                        }
                    }
                    if tool == .color, let loupePoint, let loupeLocation {
                        ColorLoupe(bitmap: bitmap, point: loupePoint)
                            .position(x: min(proxy.size.width - 56, max(56, loupeLocation.x)), y: max(64, loupeLocation.y - 82))
                    }
                }
                #if os(iOS)
                if rendersGestureLayer, let bitmap {
                    PhotoEditGestureLayer(bitmap: bitmap, tool: tool, zoom: $zoom, pan: $pan, erasePoints: $erasePoints, loupePoint: $loupePoint, loupeLocation: $loupeLocation, onTap: onTap, onErase: onErase)
                }
                #endif
            }
            #if os(iOS)
            surface
                .clipped()
                .contentShape(Rectangle())
            #else
            surface
                .clipped()
                .contentShape(Rectangle())
                .gesture(dragGesture(in: proxy.size))
                .simultaneousGesture(zoomGesture)
            #endif
        }
        .overlay(alignment: .topLeading) {
            BackdropModeToggle(mode: backdropMode, lockedInverted: lockedBackdropInverted, autoCycleStartedAt: autoCycleStartedAt, autoCycleStartsInverted: autoCycleStartsInverted, transition: backdropTransition) {
                cycleBackdropMode()
            }
            .padding(12)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                zoom = 1
                zoomStart = 1
                pan = .zero
                panStart = .zero
            } label: {
                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                    .frame(width: 34, height: 34)
                    .background(.thinMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cycleBackdropMode() {
        let now = Date()
        let current = TransparencyBackdrop.shade(for: backdropMode, lockedInverted: lockedBackdropInverted, autoCycleStartedAt: autoCycleStartedAt, autoCycleStartsInverted: autoCycleStartsInverted, transition: backdropTransition, at: now)
        let nextMode: BackdropShadeMode
        switch backdropMode {
        case .automatic:
            lockedBackdropInverted = current.space >= 0.5
            nextMode = .normal
        case .normal:
            nextMode = .inverted
        case .inverted:
            autoCycleStartsInverted = current.space < 0.5
            autoCycleStartedAt = now.addingTimeInterval(TransparencyBackdrop.transitionDuration)
            nextMode = .automatic
        }
        let duration = TransparencyBackdrop.transitionDuration(from: current, to: nextMode, lockedInverted: lockedBackdropInverted, at: now)
        let target = TransparencyBackdrop.shade(for: nextMode, lockedInverted: lockedBackdropInverted, autoCycleStartedAt: autoCycleStartedAt, autoCycleStartsInverted: autoCycleStartsInverted, transition: nil, at: now.addingTimeInterval(duration))
        if abs(target.space - current.space) + abs(target.edge - current.edge) > 0.02 {
            let style: BackdropShadeTransitionStyle = current.space < 0.05 && target.space > 0.95 ? .forward : (current.space > 0.95 && target.space < 0.05 ? .backward : .blend)
            backdropTransition = BackdropShadeTransition(startedAt: now, duration: duration, from: current, to: target, style: style, affectsToggle: nextMode != .automatic)
        }
        backdropMode = nextMode
    }

    private func imageRect(in size: CGSize, bitmap: PhotoBitmap) -> CGRect {
        PhotoEditGeometry.imageRect(in: size, bitmap: bitmap, zoom: zoom, pan: pan)
    }

    private func pixelPoint(_ location: CGPoint, in size: CGSize, bitmap: PhotoBitmap) -> (x: Double, y: Double)? {
        PhotoEditGeometry.pixelPoint(location, in: size, bitmap: bitmap, zoom: zoom, pan: pan)
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if tool == .eraser {
                    guard let bitmap, let point = pixelPoint(value.location, in: size, bitmap: bitmap) else { return }
                    appendErasePoint(CGPoint(x: point.x, y: point.y))
                } else {
                    pan = CGSize(width: panStart.width + value.translation.width, height: panStart.height + value.translation.height)
                }
            }
            .onEnded { value in
                if tool == .eraser {
                    if let bitmap, let point = pixelPoint(value.location, in: size, bitmap: bitmap) {
                        appendErasePoint(CGPoint(x: point.x, y: point.y))
                    }
                    finishErase()
                } else {
                    panStart = pan
                    if (tool == .magic || tool == .color), hypot(value.translation.width, value.translation.height) < 6, let bitmap, let point = pixelPoint(value.location, in: size, bitmap: bitmap) {
                        onTap(point.x, point.y)
                    }
                }
            }
    }

    private func appendErasePoint(_ point: CGPoint) {
        guard shouldAppend(point, to: erasePoints) else { return }
        erasePoints.append(point)
    }

    private func finishErase() {
        let points = erasePoints
        erasePoints = []
        if !points.isEmpty {
            onErase(points)
        }
    }

    private func shouldAppend(_ point: CGPoint, to points: [CGPoint]) -> Bool {
        guard let last = points.last else { return true }
        return hypot(point.x - last.x, point.y - last.y) > 0.75
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = min(12, max(1, zoomStart * value))
            }
            .onEnded { _ in
                zoomStart = zoom
            }
    }
}

private enum PhotoEditGeometry {
    static func imageRect(in size: CGSize, bitmap: PhotoBitmap, zoom: Double, pan: CGSize) -> CGRect {
        let scale = min(size.width / CGFloat(bitmap.width), size.height / CGFloat(bitmap.height)) * zoom
        let width = CGFloat(bitmap.width) * scale
        let height = CGFloat(bitmap.height) * scale
        return CGRect(x: (size.width - width) / 2 + pan.width, y: (size.height - height) / 2 + pan.height, width: width, height: height)
    }

    static func pixelPoint(_ location: CGPoint, in size: CGSize, bitmap: PhotoBitmap, zoom: Double, pan: CGSize) -> (x: Double, y: Double)? {
        let rect = imageRect(in: size, bitmap: bitmap, zoom: zoom, pan: pan)
        guard rect.contains(location) else { return nil }
        return (Double((location.x - rect.minX) / rect.width) * Double(bitmap.width - 1), Double((location.y - rect.minY) / rect.height) * Double(bitmap.height - 1))
    }
}

private struct EditorOutlinePreview: View {
    var paths: [LaserPath]
    var imageRect: CGRect

    var body: some View {
        Canvas { context, _ in
            var path = Path()
            for outline in paths {
                guard let first = outline.points.first else { continue }
                path.move(to: point(first))
                for point in outline.points.dropFirst() {
                    path.addLine(to: self.point(point))
                }
                if outline.closed {
                    path.closeSubpath()
                }
            }
            context.stroke(path, with: .color(.blue), style: StrokeStyle(lineWidth: 2, lineJoin: .round, dash: [6, 3]))
        }
    }

    private func point(_ point: Point) -> CGPoint {
        CGPoint(x: imageRect.minX + CGFloat(point.x) * imageRect.width, y: imageRect.minY + CGFloat(point.y) * imageRect.height)
    }
}

private struct PhotoEraserOverlay: View {
    var points: [CGPoint]
    var radiusPixels: Double
    var bitmap: PhotoBitmap
    var imageRect: CGRect

    var body: some View {
        Canvas { context, _ in
            guard let first = points.first else { return }
            let width = max(2, CGFloat(radiusPixels) * 2 * scale)
            var path = Path()
            path.move(to: screen(first))
            for point in points.dropFirst() {
                path.addLine(to: screen(point))
            }
            if points.count == 1 {
                let center = screen(first)
                context.fill(Path(ellipseIn: CGRect(x: center.x - width / 2, y: center.y - width / 2, width: width, height: width)), with: .color(.red.opacity(0.18)))
            } else {
                context.stroke(path, with: .color(.red.opacity(0.65)), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
        }
        .allowsHitTesting(false)
    }

    private var scale: CGFloat {
        imageRect.width / CGFloat(max(1, bitmap.width - 1))
    }

    private func screen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + point.x * scale, y: imageRect.minY + point.y * scale)
    }
}

private struct PhotoEraserSizePreview: View {
    var radiusPixels: Double
    var bitmap: PhotoBitmap
    var imageRect: CGRect

    var body: some View {
        let radius = CGFloat(radiusPixels) * imageRect.width / CGFloat(max(1, bitmap.width - 1))
        Circle()
            .fill(Color.red.opacity(0.10))
            .overlay(Circle().stroke(Color.red.opacity(0.75), lineWidth: 2))
            .frame(width: radius * 2, height: radius * 2)
            .position(x: imageRect.midX, y: imageRect.midY)
            .allowsHitTesting(false)
    }
}

private struct ColorLoupe: View {
    var bitmap: PhotoBitmap
    var point: CGPoint

    var body: some View {
        let scale: CGFloat = 6.0
        let width = CGFloat(bitmap.width) * scale
        let height = CGFloat(bitmap.height) * scale
        ZStack {
            PhotoDataImage(bitmap: bitmap)
                .frame(width: width, height: height)
                .offset(x: width / 2 - point.x * scale, y: height / 2 - point.y * scale)
            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
                .frame(width: 14, height: 14)
            Circle()
                .fill(sampleColor)
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(.white, lineWidth: 1))
                .offset(x: 31, y: 31)
        }
        .frame(width: 96, height: 96)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white, lineWidth: 2))
        .shadow(radius: 5)
    }

    private var sampleColor: Color {
        let x = min(bitmap.width - 1, max(0, Int(point.x.rounded())))
        let y = min(bitmap.height - 1, max(0, Int(point.y.rounded())))
        let i = bitmap.offset(x: x, y: y)
        return Color(.sRGB, red: Double(bitmap.pixels[i]) / 255, green: Double(bitmap.pixels[i + 1]) / 255, blue: Double(bitmap.pixels[i + 2]) / 255, opacity: 1)
    }
}

#if os(iOS)
private struct PhotoEditGestureLayer: UIViewRepresentable {
    var bitmap: PhotoBitmap
    var tool: PhotoEditTool
    @Binding var zoom: Double
    @Binding var pan: CGSize
    @Binding var erasePoints: [CGPoint]
    @Binding var loupePoint: CGPoint?
    @Binding var loupeLocation: CGPoint?
    var onTap: (Double, Double) -> Void
    var onErase: ([CGPoint]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.numberOfTouchesRequired = 1
        let oneFingerPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.oneFingerPan(_:)))
        oneFingerPan.minimumNumberOfTouches = 1
        oneFingerPan.maximumNumberOfTouches = 1
        let twoFingerPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.twoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPress(_:)))
        longPress.minimumPressDuration = 0.25
        tap.require(toFail: longPress)

        for recognizer in [tap, oneFingerPan, twoFingerPan, pinch, longPress] {
            recognizer.delegate = context.coordinator
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PhotoEditGestureLayer
        private var startPan = CGSize.zero
        private var startZoom = 1.0

        init(_ parent: PhotoEditGestureLayer) {
            self.parent = parent
        }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard let point = pixelPoint(recognizer.location(in: recognizer.view), in: recognizer.view) else { return }
            if parent.tool == .eraser {
                parent.onErase([CGPoint(x: point.x, y: point.y)])
                parent.erasePoints = []
            } else if parent.tool == .magic || parent.tool == .color {
                parent.onTap(point.x, point.y)
            }
        }

        @objc func oneFingerPan(_ recognizer: UIPanGestureRecognizer) {
            if parent.tool == .eraser {
                if recognizer.state == .began {
                    parent.erasePoints = []
                }
                if let point = pixelPoint(recognizer.location(in: recognizer.view), in: recognizer.view) {
                    appendErasePoint(CGPoint(x: point.x, y: point.y))
                }
                if recognizer.state == .ended {
                    let points = parent.erasePoints
                    parent.erasePoints = []
                    if !points.isEmpty {
                        parent.onErase(points)
                    }
                } else if recognizer.state == .cancelled || recognizer.state == .failed {
                    parent.erasePoints = []
                }
            } else {
                pan(recognizer)
                if (parent.tool == .magic || parent.tool == .color), recognizer.state == .ended, nearTap(recognizer), let point = pixelPoint(recognizer.location(in: recognizer.view), in: recognizer.view) {
                    parent.onTap(point.x, point.y)
                }
            }
        }

        @objc func twoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            pan(recognizer)
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            if recognizer.state == .began {
                startZoom = parent.zoom
            }
            parent.zoom = min(12, max(1, startZoom * recognizer.scale))
        }

        @objc func longPress(_ recognizer: UILongPressGestureRecognizer) {
            guard parent.tool == .color else { return }
            let location = recognizer.location(in: recognizer.view)
            guard let point = pixelPoint(location, in: recognizer.view) else {
                parent.loupePoint = nil
                parent.loupeLocation = nil
                return
            }
            if recognizer.state == .began || recognizer.state == .changed {
                parent.loupePoint = CGPoint(x: point.x, y: point.y)
                parent.loupeLocation = location
            } else if recognizer.state == .ended {
                parent.loupePoint = nil
                parent.loupeLocation = nil
                parent.onTap(point.x, point.y)
            } else if recognizer.state == .cancelled || recognizer.state == .failed {
                parent.loupePoint = nil
                parent.loupeLocation = nil
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
        }

        private func pan(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began {
                startPan = parent.pan
            }
            let translation = recognizer.translation(in: recognizer.view)
            parent.pan = CGSize(width: startPan.width + translation.x, height: startPan.height + translation.y)
        }

        private func nearTap(_ recognizer: UIPanGestureRecognizer) -> Bool {
            let translation = recognizer.translation(in: recognizer.view)
            return hypot(translation.x, translation.y) < 6
        }

        private func appendErasePoint(_ point: CGPoint) {
            guard shouldAppend(point, to: parent.erasePoints) else { return }
            parent.erasePoints.append(point)
        }

        private func shouldAppend(_ point: CGPoint, to points: [CGPoint]) -> Bool {
            guard let last = points.last else { return true }
            return hypot(point.x - last.x, point.y - last.y) > 0.75
        }

        private func pixelPoint(_ location: CGPoint, in view: UIView?) -> (x: Double, y: Double)? {
            guard let view else { return nil }
            return PhotoEditGeometry.pixelPoint(location, in: view.bounds.size, bitmap: parent.bitmap, zoom: parent.zoom, pan: parent.pan)
        }
    }
}
#endif

private struct BackdropModeToggle: View {
    var mode: BackdropShadeMode
    var lockedInverted: Bool
    var autoCycleStartedAt: Date
    var autoCycleStartsInverted: Bool
    var transition: BackdropShadeTransition?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { tick in
                let iconTransition = transition?.affectsToggle == true ? transition : nil
                let shade = mode == .automatic ? TransparencyBackdrop.shade(for: mode, lockedInverted: lockedInverted, autoCycleStartedAt: autoCycleStartedAt, autoCycleStartsInverted: autoCycleStartsInverted, transition: iconTransition, at: tick.date) : (lockedInverted ? (space: 1.0, edge: 1.0) : (space: 0.0, edge: 0.0))
                HStack(spacing: 3) {
                    ForEach(BackdropShadeMode.allCases, id: \.self) { option in
                        BackdropModeIcon(mode: option, selected: option == mode, shade: shade, date: tick.date)
                    }
                }
            }
            .padding(4)
            .background(.thinMaterial)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Transparency background")
    }
}

private struct BackdropModeIcon: View {
    var mode: BackdropShadeMode
    var selected: Bool
    var shade: (space: Double, edge: Double)
    var date: Date

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let selectedPath = Path(ellipseIn: CGRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2))
            if selected {
                context.fill(selectedPath, with: .color(Color.primary.opacity(0.14)))
            }

            let r = size.width * 0.22
            let light = Color.white
            let dark = Color.black
            let iconShade = resolvedShade
            let circle = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            let right = CGRect(x: center.x, y: circle.minY, width: r, height: r * 2)
            let rayRotation = mode == .automatic && selected ? date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 24) / 24 * Double.pi * 2 : 0

            for angle in stride(from: 0.0, to: Double.pi * 2, by: Double.pi / 4) {
                var ray = Path()
                let a = angle + rayRotation
                ray.move(to: CGPoint(x: center.x + cos(a) * r * 1.45, y: center.y + sin(a) * r * 1.45))
                ray.addLine(to: CGPoint(x: center.x + cos(a) * r * 1.85, y: center.y + sin(a) * r * 1.85))
                context.stroke(ray, with: .color(mode != .automatic && iconShade.darkAmount < 0.5 ? light : (mode == .automatic ? light : iconShade.line)), lineWidth: 1)
            }

            context.fill(Path(ellipseIn: circle), with: .color(mode == .automatic ? light : iconShade.fill))
            if mode == .automatic {
                var rightContext = context
                rightContext.clip(to: Path(right))
                rightContext.fill(Path(ellipseIn: circle), with: .color(dark))
            }
            context.stroke(Path(ellipseIn: circle), with: .color(mode == .automatic ? light : iconShade.line), lineWidth: 0.8)
        }
        .frame(width: 28, height: 28)
    }

    private var resolvedShade: (fill: Color, line: Color, darkAmount: Double) {
        let darkAmount: Double
        switch mode {
        case .automatic:
            darkAmount = 0
        case .normal:
            darkAmount = shade.space
        case .inverted:
            darkAmount = 1 - shade.space
        }
        return (iconColor(from: (0.925, 0.915, 0.885), to: (0.10, 0.105, 0.11), progress: darkAmount), iconColor(from: (0.10, 0.105, 0.11), to: (0.925, 0.915, 0.885), progress: darkAmount), darkAmount)
    }

    private func iconColor(from a: (Double, Double, Double), to b: (Double, Double, Double), progress: Double) -> Color {
        let p = min(1, max(0, progress))
        return Color(.sRGB, red: a.0 + (b.0 - a.0) * p, green: a.1 + (b.1 - a.1) * p, blue: a.2 + (b.2 - a.2) * p, opacity: 1)
    }
}

private struct TransparencyBackdrop: View {
    var imageRect: CGRect?
    var mode: BackdropShadeMode
    var lockedInverted: Bool
    var autoCycleStartedAt: Date
    var autoCycleStartsInverted: Bool
    var transition: BackdropShadeTransition?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { tick in
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(.sRGB, white: 0.055, opacity: 1)))
                guard let rect = imageRect else { return }

                let radius: CGFloat = 25
                let width = sqrt(3) * radius
                let rowHeight = radius * 1.5
                let progress = tick.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 120) / 120
                let movement = CGSize(width: width * 1.5 * progress, height: rowHeight * progress)
                let inversion = Self.shade(for: mode, lockedInverted: lockedInverted, autoCycleStartedAt: autoCycleStartedAt, autoCycleStartsInverted: autoCycleStartsInverted, transition: transition, at: tick.date)
                let space = color(from: (0.925, 0.915, 0.885), to: (0.10, 0.105, 0.11), progress: inversion.space)
                let edge = color(from: (0.10, 0.105, 0.11), to: (0.925, 0.915, 0.885), progress: inversion.edge)
                var imageContext = context
                imageContext.clip(to: Path(rect))

                imageContext.fill(Path(rect), with: .color(Color(.sRGB, red: space.0, green: space.1, blue: space.2, opacity: 1)))
                let line = GraphicsContext.Shading.color(Color(.sRGB, red: edge.0, green: edge.1, blue: edge.2, opacity: 0.28))
                let rows = Int(size.height / rowHeight) + 6
                let columns = Int(size.width / width) + 7

                for row in -3...rows {
                    let y = CGFloat(row) * rowHeight + movement.height
                    let xOffset = row.isMultiple(of: 2) ? 0 : width / 2
                    for column in -4...columns {
                        drawHexCube(in: &imageContext, center: CGPoint(x: CGFloat(column) * width + xOffset + movement.width, y: y), radius: radius, line: line)
                    }
                }
            }
        }
    }

    static func shade(for mode: BackdropShadeMode, lockedInverted: Bool, autoCycleStartedAt: Date, autoCycleStartsInverted: Bool, transition: BackdropShadeTransition?, at date: Date) -> (space: Double, edge: Double) {
        if let transition {
            let p = (date.timeIntervalSinceReferenceDate - transition.startedAt.timeIntervalSinceReferenceDate) / transition.duration
            if p < 1 {
                switch transition.style {
                case .forward:
                    return forwardShade(min(1, max(0, p)))
                case .backward:
                    return backwardShade(min(1, max(0, p)))
                case .blend:
                    return mix(transition.from, transition.to, smooth(min(1, max(0, p))))
                }
            }
        }
        switch mode {
        case .automatic:
            return colorInversion(at: date, startedAt: autoCycleStartedAt, startsInverted: autoCycleStartsInverted)
        case .normal:
            return lockedInverted ? (1, 1) : (0, 0)
        case .inverted:
            return lockedInverted ? (0, 0) : (1, 1)
        }
    }

    static var transitionDuration: TimeInterval {
        transition
    }

    static func transitionDuration(from: (space: Double, edge: Double), to mode: BackdropShadeMode, lockedInverted: Bool, at date: Date) -> TimeInterval {
        transitionDuration
    }

    private static let transition = 0.8

    private static func colorInversion(at date: Date, startedAt: Date, startsInverted: Bool) -> (space: Double, edge: Double) {
        let elapsed = max(0, date.timeIntervalSinceReferenceDate - startedAt.timeIntervalSinceReferenceDate)
        let segment = Int(elapsed / 8)
        let t = elapsed - Double(segment) * 8
        let shade: (space: Double, edge: Double)
        if segment > 0 && t < transition {
            shade = segment.isMultiple(of: 2) ? backwardShade(t / transition) : forwardShade(t / transition)
        } else {
            shade = segment.isMultiple(of: 2) ? (0, 0) : (1, 1)
        }
        return startsInverted ? (1 - shade.space, 1 - shade.edge) : shade
    }

    private static func forwardShade(_ p: Double) -> (space: Double, edge: Double) {
        (smooth(min(1, p / 0.65)), smooth(max(0, (p - 0.35) / 0.65)))
    }

    private static func backwardShade(_ p: Double) -> (space: Double, edge: Double) {
        forwardShade(1 - p)
    }

    private static func mix(_ a: (space: Double, edge: Double), _ b: (space: Double, edge: Double), _ p: Double) -> (space: Double, edge: Double) {
        (a.space + (b.space - a.space) * p, a.edge + (b.edge - a.edge) * p)
    }

    private static func smooth(_ x: Double) -> Double {
        x * x * (3 - 2 * x)
    }

    private func color(from a: (Double, Double, Double), to b: (Double, Double, Double), progress: Double) -> (Double, Double, Double) {
        (a.0 + (b.0 - a.0) * progress, a.1 + (b.1 - a.1) * progress, a.2 + (b.2 - a.2) * progress)
    }

    private func drawHexCube(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat, line: GraphicsContext.Shading) {
        let points = [
            CGPoint(x: center.x, y: center.y - radius),
            CGPoint(x: center.x + sqrt(3) * radius / 2, y: center.y - radius / 2),
            CGPoint(x: center.x + sqrt(3) * radius / 2, y: center.y + radius / 2),
            CGPoint(x: center.x, y: center.y + radius),
            CGPoint(x: center.x - sqrt(3) * radius / 2, y: center.y + radius / 2),
            CGPoint(x: center.x - sqrt(3) * radius / 2, y: center.y - radius / 2)
        ]

        var path = Path()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        for index in [1, 3, 5] {
            path.move(to: center)
            path.addLine(to: points[index])
        }
        context.stroke(path, with: line, lineWidth: 0.7)
    }
}

private struct PhotoDataImage: View {
    var bitmap: PhotoBitmap

    var body: some View {
        if let image = Self.cgImage(from: bitmap) {
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .interpolation(.none)
        }
    }

    private static func cgImage(from bitmap: PhotoBitmap) -> CGImage? {
        guard bitmap.pixels.count == bitmap.width * bitmap.height * 4,
              let provider = CGDataProvider(data: Data(bitmap.pixels) as CFData)
        else { return nil }
        return CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bitmap.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

private enum LibraryAssetTab: String, CaseIterable, Identifiable {
    case inUse = "Active"
    case unused = "Unused"

    var id: Self { self }
}

private struct LibraryAssetSection: Identifiable {
    var id: String
    var title: String
    var assets: [LibraryAsset]
}

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = LibraryAssetTab.inUse
    @State private var selecting = false
    @State private var selectedAssetIDs: Set<UUID> = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Library", selection: $tab) {
                    ForEach(LibraryAssetTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top], 16)

                List {
                    if sections.isEmpty {
                        Text(emptyTitle)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.assets) { asset in
                                row(for: asset)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if tab == .unused {
                        if selecting {
                            Button(allUnusedSelected ? "Clear All" : "Select All") {
                                toggleAllUnused()
                            }
                            .disabled(unusedAssets.isEmpty)
                            Button(role: .destructive) {
                                deleteSelected()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .disabled(selectedAssetIDs.isEmpty)
                        }
                        Button(selecting ? "Done" : "Select") {
                            selecting.toggle()
                            if !selecting {
                                selectedAssetIDs.removeAll()
                            }
                        }
                        .disabled(unusedAssets.isEmpty && !selecting)
                    }
                }
            }
            .onChange(of: tab) { _ in
                selecting = false
                selectedAssetIDs.removeAll()
            }
            .onChange(of: model.libraryAssets) { _ in
                selectedAssetIDs = selectedAssetIDs.intersection(unusedAssetIDs)
                if selectedAssetIDs.isEmpty {
                    selecting = false
                }
            }
        }
    }

    private var useCounts: [UUID: Int] {
        model.store?.assetUseCounts() ?? [:]
    }

    private var activeAssets: [LibraryAsset] {
        model.libraryAssets.filter { useCounts[$0.id, default: 0] > 0 }
    }

    private var unusedAssets: [LibraryAsset] {
        model.libraryAssets.filter { useCounts[$0.id, default: 0] == 0 }
    }

    private var sections: [LibraryAssetSection] {
        tab == .inUse ? activeSections : unusedSections
    }

    private var activeSections: [LibraryAssetSection] {
        var remaining = Set(activeAssets.map(\.id))
        var output: [LibraryAssetSection] = []
        for project in model.projects {
            let ids = Set(project.photos.compactMap(\.assetID)).intersection(remaining)
            let assets = ordered(activeAssets.filter { ids.contains($0.id) })
            if !assets.isEmpty {
                output.append(LibraryAssetSection(id: project.id.uuidString, title: project.name, assets: assets))
                remaining.subtract(ids)
            }
        }
        let other = ordered(activeAssets.filter { remaining.contains($0.id) })
        if !other.isEmpty {
            output.append(LibraryAssetSection(id: "other", title: "Other", assets: other))
        }
        return output
    }

    private var unusedSections: [LibraryAssetSection] {
        var output: [LibraryAssetSection] = []
        for project in model.projects {
            let assets = ordered(unusedAssets.filter { $0.mutation?.projectID == project.id })
            if !assets.isEmpty {
                output.append(LibraryAssetSection(id: project.id.uuidString, title: project.name, assets: assets))
            }
        }
        let projectIDs = Set(model.projects.map(\.id))
        let other = ordered(unusedAssets.filter { asset in
            asset.mutation?.projectID.map { !projectIDs.contains($0) } ?? true
        })
        if !other.isEmpty {
            output.append(LibraryAssetSection(id: "unused", title: "No Project", assets: other))
        }
        return output
    }

    private var unusedAssetIDs: Set<UUID> {
        Set(unusedAssets.map(\.id))
    }

    private var allUnusedSelected: Bool {
        let ids = unusedAssetIDs
        return !ids.isEmpty && selectedAssetIDs.isSuperset(of: ids)
    }

    private var emptyTitle: String {
        tab == .inUse ? "No active assets" : "No unused assets"
    }

    @ViewBuilder private func row(for asset: LibraryAsset) -> some View {
        let usage = tab == .unused ? [] : usages(for: asset)
        if selecting && tab == .unused {
            HStack(spacing: 10) {
                Image(systemName: selectedAssetIDs.contains(asset.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedAssetIDs.contains(asset.id) ? Color.accentColor : Color.secondary)
                assetBody(asset, usages: [])
            }
            .contentShape(Rectangle())
            .onTapGesture {
                toggle(asset.id)
            }
        } else {
            assetBody(asset, usages: usage)
                .swipeActions {
                    if usage.isEmpty {
                        Button("Delete", role: .destructive) {
                            model.deleteUnusedAsset(asset)
                        }
                    }
                }
        }
    }

    private func assetBody(_ asset: LibraryAsset, usages: [(project: StoredProject, photo: ProjectPhoto)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                LibraryAssetThumbnail(asset: asset, path: asset.kind == .raster ? model.store?.absoluteURL(for: asset.imagePath).path : nil, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.originalName)
                        .lineLimit(1)
                    Text("\(usages.count) use\(usages.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(usages, id: \.photo.id) { usage in
                Button {
                    model.selectedProjectID = usage.project.id
                } label: {
                    HStack {
                        Text(usage.project.name)
                            .lineLimit(1)
                        Spacer()
                        Text(summary(for: usage.photo))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func usages(for asset: LibraryAsset) -> [(project: StoredProject, photo: ProjectPhoto)] {
        model.projects.flatMap { project in
            project.photos.filter { $0.assetID == asset.id }.map { (project, $0) }
        }
    }

    private func ordered(_ assets: [LibraryAsset]) -> [LibraryAsset] {
        let ids = Set(assets.map(\.id))
        let rank = Dictionary(uniqueKeysWithValues: model.libraryAssets.enumerated().map { ($0.element.id, $0.offset) })
        var children: [UUID: [LibraryAsset]] = [:]
        var roots: [LibraryAsset] = []
        for asset in assets {
            if let parent = asset.mutation?.parentAssetID, ids.contains(parent) {
                children[parent, default: []].append(asset)
            } else {
                roots.append(asset)
            }
        }

        func sorted(_ assets: [LibraryAsset]) -> [LibraryAsset] {
            assets.sorted { rank[$0.id, default: Int.max] < rank[$1.id, default: Int.max] }
        }

        var output: [LibraryAsset] = []
        var seen: Set<UUID> = []
        func append(_ asset: LibraryAsset) {
            guard seen.insert(asset.id).inserted else { return }
            output.append(asset)
            for child in sorted(children[asset.id] ?? []) {
                append(child)
            }
        }

        for asset in sorted(roots) {
            append(asset)
        }
        for asset in sorted(assets) where !seen.contains(asset.id) {
            append(asset)
        }
        return output
    }

    private func toggle(_ id: UUID) {
        if selectedAssetIDs.contains(id) {
            selectedAssetIDs.remove(id)
        } else {
            selectedAssetIDs.insert(id)
        }
    }

    private func toggleAllUnused() {
        let ids = unusedAssetIDs
        selectedAssetIDs = allUnusedSelected ? [] : ids
    }

    private func deleteSelected() {
        model.deleteUnusedAssets(ids: selectedAssetIDs)
        selectedAssetIDs.removeAll()
        selecting = false
    }

    private func summary(for photo: ProjectPhoto) -> String {
        if photo.mode == .vector || photo.mode == .text {
            return "\(photo.mode == .text ? "Text" : "Vector") · \(Int(photo.resolvedVectorSettings.powerPercent))%"
        }
        return "\(photo.settingsName) · \(Int(photo.settings.dpi)) DPI · \(Int(photo.settings.maxPowerPercent))%"
    }
}

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("History")
                    .font(.largeTitle.weight(.bold))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                List(model.history) { record in
                    VStack(alignment: .leading) {
                        Text(record.projectName)
                        Text("\(record.printedAt.formatted()) · \(record.photoCount) photo\(record.photoCount == 1 ? "" : "s") · \(record.generatedLines) lines · \(record.generatedBytes) bytes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(screenBackground)
            .navigationTitle("")
            .inlineNavigationTitle()
        }
    }
}

struct DebugLogView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Log")
                        .font(.largeTitle.weight(.bold))
                    Spacer()
                    Button("Copy") {
                        copy(model.debugLog.map { "\($0.date.formatted()) [\($0.level.rawValue)] \($0.message)" }.joined(separator: "\n"))
                    }
                    Button("Clear") { model.clearLog() }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                List(model.debugLog) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.message)
                        Text("\(entry.date.formatted()) · \(entry.level.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(screenBackground)
            .navigationTitle("")
            .inlineNavigationTitle()
        }
    }
}

#if os(iOS)
private typealias CachedPlatformImage = UIImage
#elseif os(macOS)
private typealias CachedPlatformImage = NSImage
#endif

@MainActor private final class StoredImageCache {
    static let shared = StoredImageCache()
    private let cache = NSCache<NSString, CachedPlatformImage>()
    private var alphaBounds: [String: CGRect] = [:]

    func image(path: String) -> CachedPlatformImage? {
        let key = path as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let image = CachedPlatformImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    func visibleAlphaBounds(path: String) -> CGRect? {
        if let cached = alphaBounds[path] { return cached.isNull ? nil : cached }
        let bounds = Self.visibleAlphaBounds(path: path)
        alphaBounds[path] = bounds ?? .null
        return bounds
    }

    private static func visibleAlphaBounds(path: String) -> CGRect? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let image = orientedImage(from: source) else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width where bytes[y * rowBytes + x * 4 + 3] > 0 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: Double(minX) / Double(width), y: Double(minY) / Double(height), width: Double(maxX - minX + 1) / Double(width), height: Double(maxY - minY + 1) / Double(height))
    }

    private static func orientedImage(from source: CGImageSource) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let pixelHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let maxPixel = min(max(pixelWidth, pixelHeight), 1024)
        if maxPixel > 0 {
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ] as CFDictionary
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) { return image }
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

struct StoredImage: View {
    var path: String?
    var fill = false
    var stretch = false

    var body: some View {
        #if os(iOS)
        if let path, let image = StoredImageCache.shared.image(path: path) {
            let image = Image(uiImage: image).resizable()
            if stretch {
                image
            } else {
                image.aspectRatio(contentMode: fill ? .fill : .fit)
            }
        }
        #elseif os(macOS)
        if let path, let image = StoredImageCache.shared.image(path: path) {
            let image = Image(nsImage: image).resizable()
            if stretch {
                image
            } else {
                image.aspectRatio(contentMode: fill ? .fill : .fit)
            }
        }
        #endif
    }
}

struct AssetThumbnail: View {
    var path: String?
    var size: CGFloat
    var selected: Bool

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.08)
            StoredImage(path: path, fill: true)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
    }
}

struct ObjectThumbnail: View {
    var photo: ProjectPhoto
    var path: String?
    var size: CGFloat
    var selected: Bool

    var body: some View {
        Group {
            if photo.mode == .vector || photo.mode == .text {
                ZStack {
                    VectorPathShape(paths: photo.vectorPaths)
                        .stroke((photo.mode == .text ? Color.purple : Color.blue).opacity(0.95), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                        .padding(7)
                    if photo.vectorPaths.isEmpty {
                        Rectangle()
                            .stroke((photo.mode == .text ? Color.purple : Color.blue).opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .padding(7)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
            } else {
                AssetThumbnail(path: path, size: size, selected: selected)
            }
        }
        .opacity(photo.isEnabled ? 1 : 0.35)
        .overlay(alignment: .topTrailing) {
            if !photo.isEnabled {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(2)
            }
        }
    }
}

struct LibraryAssetThumbnail: View {
    var asset: LibraryAsset
    var path: String?
    var size: CGFloat

    var body: some View {
        if asset.kind == .raster {
            AssetThumbnail(path: path, size: size, selected: false)
        } else {
            ZStack {
                Color.secondary.opacity(0.08)
                VectorPathShape(paths: asset.vectorPaths)
                    .stroke((asset.kind == .text ? Color.purple : Color.blue).opacity(0.95), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    .padding(8)
                if asset.vectorPaths.isEmpty {
                    Rectangle()
                        .stroke((asset.kind == .text ? Color.purple : Color.blue).opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .padding(8)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
        }
    }
}

private struct VectorPathShape: Shape {
    var paths: [LaserPath]

    func path(in rect: CGRect) -> Path {
        var output = Path()
        for path in paths {
            guard let first = path.points.first else { continue }
            output.move(to: point(first, in: rect))
            for point in path.points.dropFirst() {
                output.addLine(to: self.point(point, in: rect))
            }
            if path.closed {
                output.closeSubpath()
            }
        }
        return output
    }

    private func point(_ point: Point, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + CGFloat(point.x) * rect.width, y: rect.minY + CGFloat(point.y) * rect.height)
    }
}

private struct LaserCanvasMetric {
    var side: CGFloat
    var drawableX: Double
    var drawableY: Double
    var drawableSize: Double
    var plateX: Double
    var plateY: Double
    var plateWidth: Double
    var plateHeight: Double
    var dotsX: Double
    var dotsY: Double
    var dotsWidth: Double
    var dotsHeight: Double
    var innerX: Double
    var innerY: Double
    var innerWidth: Double
    var innerHeight: Double

    var drawable: CGRect {
        rect(x: drawableX, y: drawableY, width: drawableSize, height: drawableSize)
    }

    var plate: CGRect {
        rect(x: plateX, y: plateY, width: plateWidth, height: plateHeight)
    }

    var dots: CGRect {
        rect(x: dotsX, y: dotsY, width: dotsWidth, height: dotsHeight)
    }

    var inner: CGRect {
        rect(x: innerX, y: innerY, width: innerWidth, height: innerHeight)
    }

    var scale: CGFloat {
        drawable.width / CGFloat(RasterGenerator.workAreaMM)
    }

    private func rect(x: Double, y: Double, width: Double, height: Double) -> CGRect {
        CGRect(x: side * x, y: side * y, width: side * width, height: side * height)
    }
}

private enum CanvasControlLocal {
    static let delete = Point(x: 0, y: 0)
    static let resize = Point(x: 1, y: 1)
    static let rotation = Point(x: 0.5, y: -0.35)
}

@MainActor private enum CanvasGeometry {
    static let unitBoundsPoints = [Point(x: 0, y: 0), Point(x: 1, y: 0), Point(x: 1, y: 1), Point(x: 0, y: 1)]

    static func rotatedPlacement(_ start: PrintPlacement, object: ProjectPhoto, degrees: Double, rasterPath: (ProjectPhoto) -> String? = { _ in nil }) -> PrintPlacement {
        rotatedPlacement(start, object: object, degrees: degrees, fixedCenter: start.absolute(rotationCenter(for: object, rasterPath: rasterPath)), rasterPath: rasterPath)
    }

    static func rotatedGroupPlacement(_ start: PrintPlacement, object: ProjectPhoto, degrees: Double, groupCenter: Point, delta: Double, rasterPath: (ProjectPhoto) -> String? = { _ in nil }) -> PrintPlacement {
        let center = start.absolute(rotationCenter(for: object, rasterPath: rasterPath))
        return rotatedPlacement(start, object: object, degrees: degrees, fixedCenter: rotatedPoint(center, around: groupCenter, degrees: delta), rasterPath: rasterPath)
    }

    static func rotatedPlacement(_ start: PrintPlacement, object: ProjectPhoto, degrees: Double, fixedCenter: Point, rasterPath: (ProjectPhoto) -> String? = { _ in nil }) -> PrintPlacement {
        let local = rotationCenter(for: object, rasterPath: rasterPath)
        let x = local.x * start.widthMM
        let y = local.y * start.heightMM
        let radians = degrees * .pi / 180
        return PrintPlacement(
            xMM: fixedCenter.x - x * cos(radians) + y * sin(radians),
            yMM: fixedCenter.y - x * sin(radians) - y * cos(radians),
            widthMM: start.widthMM,
            heightMM: start.heightMM,
            rotationDegrees: normalizedRotationDegrees(degrees)
        )
    }

    static func rotatedPoint(_ point: Point, around center: Point, degrees: Double) -> Point {
        let radians = degrees * .pi / 180
        let x = point.x - center.x
        let y = point.y - center.y
        return Point(x: center.x + x * cos(radians) - y * sin(radians), y: center.y + x * sin(radians) + y * cos(radians))
    }

    static func resizeFactor(groupStart: PrintPlacement, translationMM: Point, minimum: Double) -> Double {
        let width = max(0.001, groupStart.widthMM)
        let height = max(0.001, groupStart.heightMM)
        let factor = ((width + translationMM.x) * width + (height + translationMM.y) * height) / (width * width + height * height)
        return max(minimum, factor)
    }

    static func selectionPoints(for objects: [ProjectPhoto], placements: [UUID: PrintPlacement] = [:], rasterPath: (ProjectPhoto) -> String? = { _ in nil }) -> [Point] {
        objects.flatMap { object in
            let placement = placements[object.id] ?? object.printPlacement
            return localContentPoints(for: object, rasterPath: rasterPath).map { placement.absolute($0) }
        }
    }

    static func selectionBounds(for objects: [ProjectPhoto], placements: [UUID: PrintPlacement] = [:], rasterPath: (ProjectPhoto) -> String? = { _ in nil }) -> PrintPlacement? {
        boundsOfPoints(selectionPoints(for: objects, placements: placements, rasterPath: rasterPath))
    }

    static func boundsOfPoints(_ points: [Point]) -> PrintPlacement? {
        guard let first = points.first else { return nil }
        let minX = points.reduce(first.x) { min($0, $1.x) }
        let minY = points.reduce(first.y) { min($0, $1.y) }
        let maxX = points.reduce(first.x) { max($0, $1.x) }
        let maxY = points.reduce(first.y) { max($0, $1.y) }
        return PrintPlacement(xMM: minX, yMM: minY, widthMM: maxX - minX, heightMM: maxY - minY)
    }

    static func selectionCenter(for objects: [ProjectPhoto], placements: [UUID: PrintPlacement] = [:], rasterPath: (ProjectPhoto) -> String? = { _ in nil }) -> Point? {
        convexHullCenter(selectionPoints(for: objects, placements: placements, rasterPath: rasterPath))
    }

    static func rotationCenter(for object: ProjectPhoto, rasterPath: (ProjectPhoto) -> String? = { _ in nil }) -> Point {
        convexHullCenter(localContentPoints(for: object, rasterPath: rasterPath)) ?? Point(x: 0.5, y: 0.5)
    }

    static func localContentPoints(for object: ProjectPhoto, rasterPath: (ProjectPhoto) -> String? = { _ in nil }) -> [Point] {
        if object.mode == .vector || object.mode == .text {
            let points = object.vectorPaths.flatMap(\.points)
            if !points.isEmpty { return points }
        } else if let path = rasterPath(object), let bounds = StoredImageCache.shared.visibleAlphaBounds(path: path), bounds.width > 0, bounds.height > 0 {
            return [
                Point(x: Double(bounds.minX), y: Double(bounds.minY)),
                Point(x: Double(bounds.maxX), y: Double(bounds.minY)),
                Point(x: Double(bounds.maxX), y: Double(bounds.maxY)),
                Point(x: Double(bounds.minX), y: Double(bounds.maxY))
            ]
        }
        return unitBoundsPoints
    }

    static func convexHullCenter(_ points: [Point]) -> Point? {
        let points = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard points.count > 1 else { return points.first }
        let hull = convexHull(points)
        guard hull.count > 2 else {
            return Point(x: hull.reduce(0) { $0 + $1.x } / Double(hull.count), y: hull.reduce(0) { $0 + $1.y } / Double(hull.count))
        }
        var area = 0.0
        var x = 0.0
        var y = 0.0
        for index in hull.indices {
            let a = hull[index]
            let b = hull[(index + 1) % hull.count]
            let cross = a.x * b.y - b.x * a.y
            area += cross
            x += (a.x + b.x) * cross
            y += (a.y + b.y) * cross
        }
        guard abs(area) > 0.000001 else { return Point(x: 0.5, y: 0.5) }
        return Point(x: x / (3 * area), y: y / (3 * area))
    }

    static func restingObjectControlPoint(for object: ProjectPhoto, local: Point, placements: [UUID: PrintPlacement] = [:], rasterPath: (ProjectPhoto) -> String? = { _ in nil }) -> Point {
        (selectionBounds(for: [object], placements: placements, rasterPath: rasterPath) ?? placements[object.id] ?? object.printPlacement).absolute(local)
    }

    static func rotatingObjectControlPoint(for object: ProjectPhoto, local: Point, starts: [UUID: PrintPlacement], groupCenter: Point, delta: Double, rasterPath: (ProjectPhoto) -> String? = { _ in nil }) -> Point {
        guard let start = starts[object.id] else { return restingObjectControlPoint(for: object, local: local, rasterPath: rasterPath) }
        let pivot = starts.count > 1 ? groupCenter : start.absolute(rotationCenter(for: object, rasterPath: rasterPath))
        return rotatedPoint(restingObjectControlPoint(for: object, local: local, placements: starts, rasterPath: rasterPath), around: pivot, degrees: delta)
    }

    private static func convexHull(_ points: [Point]) -> [Point] {
        func cross(_ a: Point, _ b: Point, _ c: Point) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        var lower: [Point] = []
        for point in points {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [Point] = []
        for point in points.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}

@MainActor private func rotatedPlacement(_ start: PrintPlacement, object: ProjectPhoto, degrees: Double) -> PrintPlacement {
    CanvasGeometry.rotatedPlacement(start, object: object, degrees: degrees)
}

@MainActor private func rotatedGroupPlacement(_ start: PrintPlacement, object: ProjectPhoto, degrees: Double, groupCenter: Point, delta: Double) -> PrintPlacement {
    CanvasGeometry.rotatedGroupPlacement(start, object: object, degrees: degrees, groupCenter: groupCenter, delta: delta)
}

private func normalizedRotationDegrees(_ degrees: Double) -> Double {
    let value = degrees.truncatingRemainder(dividingBy: 360)
    return value < 0 ? value + 360 : value
}

private func normalizedRotationReadoutDegrees(_ degrees: Double) -> Int {
    let value = Int(round(degrees)) % 360
    return value < 0 ? value + 360 : value
}

@MainActor private func rotatedPoint(_ point: Point, around center: Point, degrees: Double) -> Point {
    CanvasGeometry.rotatedPoint(point, around: center, degrees: degrees)
}

@MainActor private func selectionBounds(for objects: [ProjectPhoto], placements: [UUID: PrintPlacement] = [:]) -> PrintPlacement? {
    CanvasGeometry.selectionBounds(for: objects, placements: placements)
}

@MainActor private func boundsOfPoints(_ points: [Point]) -> PrintPlacement? {
    CanvasGeometry.boundsOfPoints(points)
}

@MainActor private func selectionCenter(for objects: [ProjectPhoto], placements: [UUID: PrintPlacement] = [:]) -> Point? {
    CanvasGeometry.selectionCenter(for: objects, placements: placements)
}

@MainActor private func convexHullCenter(_ points: [Point]) -> Point? {
    CanvasGeometry.convexHullCenter(points)
}

@MainActor private func rotationCenter(for object: ProjectPhoto) -> Point {
    CanvasGeometry.rotationCenter(for: object)
}

private func canvasControlPoint(for placement: PrintPlacement, local: Point) -> Point {
    placement.absolute(local)
}

@MainActor private func groupRotationKnobPoint(groupStart: PrintPlacement, groupCenter: Point, delta: Double) -> Point {
    rotatedPoint(groupStart.absolute(CanvasControlLocal.rotation), around: groupCenter, degrees: delta)
}

@MainActor private func restingObjectControlPoint(for object: ProjectPhoto, local: Point, placements: [UUID: PrintPlacement] = [:]) -> Point {
    CanvasGeometry.restingObjectControlPoint(for: object, local: local, placements: placements)
}

@MainActor private func rotatingObjectControlPoint(for object: ProjectPhoto, local: Point, starts: [UUID: PrintPlacement], groupCenter: Point, delta: Double) -> Point {
    CanvasGeometry.rotatingObjectControlPoint(for: object, local: local, starts: starts, groupCenter: groupCenter, delta: delta)
}

struct ProjectCanvasView: View {
    private enum EditKind { case move, resize, rotate }
    private struct ActiveEdit {
        var id: UUID
        var kind: EditKind
        var starts: [UUID: PrintPlacement]
        var groupStart: PrintPlacement
        var groupCenter: Point
    }

    var store: FileAppStore?
    @Binding var photos: [ProjectPhoto]
    @Binding var selectedPhotoIDs: Set<UUID>
    @Binding var isEditing: Bool
    var onEdit: (ProjectPhoto) -> Void = { _ in }
    var onDelete: (UUID) -> Void = { _ in }
    var onViewportGestureChanged: (Bool) -> Void = { _ in }
    var onEditingEnded: () -> Void = {}
    private let drawableX = 0.22
    private let drawableY = 0.26
    private let drawableSize = 0.56
    @AppStorage("laserBed.v3.plateX") private var plateX = 0.105333
    @AppStorage("laserBed.v3.plateY") private var plateY = 0.084444
    @AppStorage("laserBed.v3.plateWidth") private var plateWidth = 0.800111
    @AppStorage("laserBed.v3.plateHeight") private var plateHeight = 0.842111
    @AppStorage("laserBed.v3.dotsX") private var dotsX = 0.177333
    @AppStorage("laserBed.v3.dotsY") private var dotsY = 0.201111
    @AppStorage("laserBed.v3.dotsWidth") private var dotsWidth = 0.651222
    @AppStorage("laserBed.v3.dotsHeight") private var dotsHeight = 0.546556
    @AppStorage("laserBed.v3.innerX") private var innerX = 0.199222
    @AppStorage("laserBed.v3.innerY") private var innerY = 0.242222
    @AppStorage("laserBed.v3.innerWidth") private var innerWidth = 0.602222
    @AppStorage("laserBed.v3.innerHeight") private var innerHeight = 0.600000
    @State private var calibratingBed = false
    @State private var calibrationField = "Plate L"
    @State private var pan = CGSize.zero
    @State private var panStart = CGSize.zero
    @State private var zoom = 1.0
    @State private var zoomStart = 1.0
    @State private var activeEdit: ActiveEdit?
    @State private var rotationDraftDegrees: [UUID: Double] = [:]
    @State private var rotationDraftDelta = 0.0
    @State private var snapGuides = CanvasSnapResult(placement: PrintPlacement())
    @State private var selectionRect: CGRect?

    private var drawIndexes: [Int] {
        photos.indices.sorted { left, right in
            let leftSelected = selectedPhotoIDs.contains(photos[left].id)
            let rightSelected = selectedPhotoIDs.contains(photos[right].id)
            return leftSelected == rightSelected ? left < right : !leftSelected && rightSelected
        }
    }

    private var drawObjects: [ProjectPhoto] {
        drawIndexes.compactMap { photos.indices.contains($0) ? photos[$0] : nil }
    }

    private var selectedIDs: Set<UUID> {
        selectedPhotoIDs.intersection(Set(photos.map(\.id)))
    }

    private var selectedObjects: [ProjectPhoto] {
        photos.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                let viewport = proxy.size.width
                let world = viewport
                let metric = LaserCanvasMetric(side: world, drawableX: drawableX, drawableY: drawableY, drawableSize: drawableSize, plateX: plateX, plateY: plateY, plateWidth: plateWidth, plateHeight: plateHeight, dotsX: dotsX, dotsY: dotsY, dotsWidth: dotsWidth, dotsHeight: dotsHeight, innerX: innerX, innerY: innerY, innerWidth: innerWidth, innerHeight: innerHeight)
                let contentOffset = pan
                let center = CGPoint(x: world / 2, y: world / 2)
                ZStack(alignment: .topLeading) {
                    Color.secondary.opacity(0.045)
                    InfiniteGrid(metric: metric, zoom: zoom, pan: contentOffset)
                        .stroke(Color.secondary.opacity(0.10), lineWidth: 0.5)
                    DrawableShade(metric: metric, zoom: zoom, pan: contentOffset)
                        .fill(Color.secondary.opacity(activeEdit != nil ? 0.12 : 0.055), style: FillStyle(eoFill: true))
                    ZStack(alignment: .topLeading) {
                        LaserBedBackground(metric: metric)
                            .frame(width: world, height: world)

                        ForEach(drawObjects) { photo in
                            photoView(photo: photo, metric: metric)
                        }

                        SnapGuideLines(result: snapGuides, metric: metric)
                            .stroke(Color.accentColor.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        if let selectionRect {
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.12))
                                .overlay(Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                                .frame(width: selectionRect.width, height: selectionRect.height)
                                .offset(x: selectionRect.minX, y: selectionRect.minY)
                        }
                        rotationKnob(metric: metric)
                    }
                    .frame(width: world, height: world)
                    .coordinateSpace(name: "canvas")
                    .scaleEffect(zoom, anchor: .center)
                    .offset(contentOffset)
                    Button {
                        calibratingBed.toggle()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption.weight(.semibold))
                            .frame(width: 30, height: 30)
                            .background(.thinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .frame(width: viewport, height: viewport, alignment: .topTrailing)
                }
                .frame(width: viewport, height: viewport)
                .clipped()
                .transaction { $0.animation = nil }
                .contentShape(Rectangle())
                .gesture(editOrSelectGesture(metric: metric, center: center, contentOffset: contentOffset), including: isFullyVisible(proxy) ? .all : .subviews)
                #if os(iOS)
                .simultaneousGesture(tapGesture(metric: metric, center: center, contentOffset: contentOffset))
                .overlay {
                    ProjectCanvasGestureLayer(zoom: $zoom, pan: $pan, onActiveChanged: onViewportGestureChanged)
                }
                #else
                .simultaneousGesture(zoomGesture)
                .simultaneousGesture(tapGesture(metric: metric, center: center, contentOffset: contentOffset))
                #endif
            }
            .aspectRatio(1, contentMode: .fit)

            if calibratingBed {
                BedCalibrationPanel(
                    field: $calibrationField,
                    plateX: $plateX,
                    plateY: $plateY,
                    plateWidth: $plateWidth,
                    plateHeight: $plateHeight,
                    dotsX: $dotsX,
                    dotsY: $dotsY,
                    dotsWidth: $dotsWidth,
                    dotsHeight: $dotsHeight,
                    innerX: $innerX,
                    innerY: $innerY,
                    innerWidth: $innerWidth,
                    innerHeight: $innerHeight
                )
            }
        }
    }

    @ViewBuilder private func rotationKnob(metric: LaserCanvasMetric) -> some View {
        let objects = selectedObjects
        if let point = rotationKnobPoint(metric: metric, objects: objects), let degrees = rotationReadoutDegrees(objects: objects) {
            let size = rotationKnobSize
            ZStack {
                Circle()
                    .fill(.thinMaterial)
                    .overlay(Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: max(8, 13 / CGFloat(zoom)), weight: .semibold)).foregroundStyle(Color.accentColor))
                    .overlay(Circle().stroke(Color.accentColor.opacity(0.7), lineWidth: 1 / CGFloat(zoom)))
                Text("\(normalizedRotationReadoutDegrees(degrees))°")
                    .font(.system(size: max(8, 12 / CGFloat(zoom)), weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 5 / CGFloat(zoom))
                    .padding(.vertical, 2 / CGFloat(zoom))
                    .background(.thinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.accentColor.opacity(0.45), lineWidth: 1 / CGFloat(zoom)))
                    .fixedSize()
                    .offset(x: size * 0.85)
            }
            .frame(width: size, height: size)
            .offset(x: point.x - size / 2, y: point.y - size / 2)
            .highPriorityGesture(rotationGesture(metric: metric))
        }
    }

    @ViewBuilder private func photoView(photo: ProjectPhoto, metric: LaserCanvasMetric) -> some View {
        let rect = rect(for: photo.printPlacement, metric: metric)
        let selected = selectedPhotoIDs.contains(photo.id)
        let handleSize = max(4, 22 / CGFloat(zoom))
        let handleIconSize = max(2, 10 / CGFloat(zoom))
        let deletePoint = objectHandlePoint(for: photo, local: CanvasControlLocal.delete, metric: metric)
        let resizePoint = objectHandlePoint(for: photo, local: CanvasControlLocal.resize, metric: metric)

        if selected {
            ZStack(alignment: .topLeading) {
                objectView(photo: photo, selected: true)
                    .frame(width: rect.width, height: rect.height)
                    .rotationEffect(.degrees(photo.printPlacement.rotationDegrees), anchor: .topLeading)
                    .contentShape(Rectangle())
                    .contextMenu { objectMenu(photo: photo) }
                    .offset(x: rect.minX, y: rect.minY)

                if photo.mode == .raster {
                    let objectRect = canvasObjectRect(for: photo, metric: metric)
                    Rectangle()
                        .stroke(Color.accentColor, lineWidth: max(0.75, 1.5 / CGFloat(zoom)))
                        .frame(width: objectRect.width, height: objectRect.height)
                        .offset(x: objectRect.minX, y: objectRect.minY)
                }

                Button {
                    requestDelete(id: photo.id)
                } label: {
                    Circle()
                        .fill(Color.red)
                        .frame(width: handleSize, height: handleSize)
                        .overlay(Image(systemName: "minus").font(.system(size: handleIconSize, weight: .bold)).foregroundStyle(.white))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("canvas.delete")
                .offset(x: deletePoint.x - handleSize / 2, y: deletePoint.y - handleSize / 2)

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: handleSize, height: handleSize)
                    .overlay(Image(systemName: "arrow.down.right").font(.system(size: handleIconSize, weight: .semibold)).foregroundStyle(.white))
                    .offset(x: resizePoint.x - handleSize / 2, y: resizePoint.y - handleSize / 2)
                    .highPriorityGesture(resizeGesture(id: photo.id, scale: metric.scale))
            }
        } else {
            objectView(photo: photo, selected: false)
                .frame(width: rect.width, height: rect.height)
                .rotationEffect(.degrees(photo.printPlacement.rotationDegrees), anchor: .topLeading)
                .contentShape(Rectangle())
                .contextMenu { objectMenu(photo: photo) }
                .offset(x: rect.minX, y: rect.minY)
        }
    }

    @ViewBuilder private func objectMenu(photo: ProjectPhoto) -> some View {
        Button {
            onEdit(photo)
        } label: {
            Label("Edit", systemImage: "pencil")
        }
        Button {
            toggleEnabled(photo.id)
        } label: {
            Label(photo.isEnabled ? "Disable" : "Enable", systemImage: photo.isEnabled ? "eye.slash" : "eye")
        }
        Button(role: .destructive) {
            requestDelete(id: photo.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func requestDelete(id: UUID) {
        selectedPhotoIDs.remove(id)
        activeEdit = nil
        rotationDraftDegrees.removeAll()
        rotationDraftDelta = 0
        isEditing = false
        snapGuides = CanvasSnapResult(placement: PrintPlacement())
        DispatchQueue.main.async {
            onDelete(id)
        }
    }

    @ViewBuilder private func objectView(photo: ProjectPhoto, selected: Bool) -> some View {
        let lineWidth = CGFloat(selected ? 2.0 : 1.5) / CGFloat(zoom)
        Group {
            if photo.mode == .vector || photo.mode == .text {
                VectorPathShape(paths: photo.vectorPaths)
                    .stroke(selected ? Color.accentColor : (photo.mode == .text ? Color.purple : Color.blue).opacity(0.95), style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
                    .overlay {
                        if photo.vectorPaths.isEmpty {
                            Rectangle().stroke(selected ? Color.accentColor : (photo.mode == .text ? Color.purple : Color.blue).opacity(0.9), style: StrokeStyle(lineWidth: lineWidth, dash: [6, 4]))
                        }
                    }
            } else {
                StoredImage(path: path(for: photo), stretch: true)
                    .clipped()
                    .shadow(color: Color.black.opacity(selected ? 0.18 : 0.08), radius: selected ? 4 : 2)
            }
        }
        .opacity(photo.isEnabled ? 1 : 0.28)
        .overlay(alignment: .topTrailing) {
            if !photo.isEnabled {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: max(6, 12 / CGFloat(zoom)), weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(3 / CGFloat(zoom))
            }
        }
    }

    private func toggleEnabled(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].isEnabled.toggle()
        onEditingEnded()
    }

    private func resizeGesture(id: UUID, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
            .onChanged { value in
                guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
                beginEdit(index: index, kind: .resize)
                guard let activeEdit, activeEdit.id == id else { return }
                let factor = CanvasGeometry.resizeFactor(
                    groupStart: activeEdit.groupStart,
                    translationMM: Point(x: value.translation.width / (Double(scale) * zoom), y: value.translation.height / (Double(scale) * zoom)),
                    minimum: minScaleFactor(activeEdit.starts)
                )
                apply(activeEdit.starts) { start in
                    PrintPlacement(
                        xMM: activeEdit.groupStart.xMM + (start.xMM - activeEdit.groupStart.xMM) * factor,
                        yMM: activeEdit.groupStart.yMM + (start.yMM - activeEdit.groupStart.yMM) * factor,
                        widthMM: start.widthMM * factor,
                        heightMM: start.heightMM * factor,
                        rotationDegrees: start.rotationDegrees
                    )
                }
                snapGuides = CanvasSnapResult(placement: PrintPlacement())
            }
            .onEnded { _ in
                activeEdit = nil
                isEditing = false
                snapGuides = CanvasSnapResult(placement: PrintPlacement())
                onEditingEnded()
            }
    }

    private func beginEdit(index: Int, kind: EditKind) {
        guard activeEdit == nil, photos.indices.contains(index) else { return }
        let id = photos[index].id
        let ids = selectedPhotoIDs.contains(id) ? selectedIDs : [id]
        let objects = photos.filter { ids.contains($0.id) }
        let starts = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0.printPlacement) })
        guard let placementBounds = bounds(for: Array(starts.values)) else { return }
        let groupStart = canvasSelectionBounds(for: objects, placements: starts) ?? placementBounds
        let groupCenter = canvasSelectionCenter(for: objects, placements: starts) ?? Point(x: groupStart.xMM + groupStart.widthMM / 2, y: groupStart.yMM + groupStart.heightMM / 2)
        if kind == .rotate {
            rotationDraftDegrees.removeAll()
            rotationDraftDelta = 0
        }
        activeEdit = ActiveEdit(id: id, kind: kind, starts: starts, groupStart: groupStart, groupCenter: groupCenter)
        isEditing = true
    }

    private func editOrSelectGesture(metric: LaserCanvasMetric, center: CGPoint, contentOffset: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if activeEdit == nil {
                    let start = canvasPoint(from: value.startLocation, center: center, contentOffset: contentOffset)
                    if selectedObjects.contains(where: { isResizeHandle(start, object: $0, metric: metric) }) || isRotationHandle(start, metric: metric) {
                        return
                    }
                    if let index = photos.firstIndex(where: { selectedIDs.contains($0.id) }) {
                        beginEdit(index: index, kind: .move)
                    } else {
                        let current = canvasPoint(from: value.location, center: center, contentOffset: contentOffset)
                        selectionRect = CGRect(
                            x: min(start.x, current.x),
                            y: min(start.y, current.y),
                            width: abs(current.x - start.x),
                            height: abs(current.y - start.y)
                        )
                    }
                }

                if let activeEdit, activeEdit.kind == .move {
                    var next = activeEdit.groupStart
                    next.xMM += value.translation.width / (Double(metric.scale) * zoom)
                    next.yMM += value.translation.height / (Double(metric.scale) * zoom)
                    let result = CanvasSnapper.snap(next, to: photos.filter { activeEdit.starts[$0.id] == nil }.compactMap { canvasSelectionBounds(for: [$0]) })
                    snapGuides = result
                    let dx = result.placement.xMM - activeEdit.groupStart.xMM
                    let dy = result.placement.yMM - activeEdit.groupStart.yMM
                    apply(activeEdit.starts) { start in
                        PrintPlacement(xMM: start.xMM + dx, yMM: start.yMM + dy, widthMM: start.widthMM, heightMM: start.heightMM, rotationDegrees: start.rotationDegrees)
                    }
                }
            }
            .onEnded { _ in
                if activeEdit?.kind == .move {
                    activeEdit = nil
                    isEditing = false
                    snapGuides = CanvasSnapResult(placement: PrintPlacement())
                    onEditingEnded()
                } else if activeEdit == nil {
                    applySelection(metric: metric)
                }
                selectionRect = nil
            }
    }

    private func rotationGesture(metric: LaserCanvasMetric) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
            .onChanged { value in
                if activeEdit == nil, let index = photos.firstIndex(where: { selectedIDs.contains($0.id) }) {
                    beginEdit(index: index, kind: .rotate)
                }
                guard let activeEdit, activeEdit.kind == .rotate else { return }
                guard let center = rotationPivot(metric: metric, edit: activeEdit) else { return }
                let start = atan2(value.startLocation.y - center.y, value.startLocation.x - center.x) * 180 / .pi
                let current = atan2(value.location.y - center.y, value.location.x - center.x) * 180 / .pi
                applyRotation(activeEdit, delta: snappedRotationDelta(shortestAngleDelta(from: start, to: current), edit: activeEdit))
            }
            .onEnded { _ in
                if let activeEdit, activeEdit.kind == .rotate {
                    applyRotation(activeEdit, delta: currentRotationDelta(edit: activeEdit))
                }
                rotationDraftDegrees.removeAll()
                rotationDraftDelta = 0
                activeEdit = nil
                isEditing = false
                onEditingEnded()
            }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = min(5, max(0.5, zoomStart * value))
            }
            .onEnded { _ in
                zoomStart = zoom
            }
    }

    private func tapGesture(metric: LaserCanvasMetric, center: CGPoint, contentOffset: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                if let index = hitTest(canvasPoint(from: value.location, center: center, contentOffset: contentOffset), metric: metric) {
                    toggleSelection(photos[index].id)
                } else {
                    selectedPhotoIDs.removeAll()
                }
            }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedPhotoIDs.contains(id) {
            selectedPhotoIDs.remove(id)
        } else {
            selectedPhotoIDs.insert(id)
        }
    }

    private func apply(_ starts: [UUID: PrintPlacement], transform: (PrintPlacement) -> PrintPlacement) {
        for index in photos.indices {
            if let start = starts[photos[index].id] {
                photos[index].printPlacement = RasterGenerator.minimumSizeConstrained(transform(start))
            }
        }
    }

    private func applySelection(metric: LaserCanvasMetric) {
        guard let selectionRect, selectionRect.width > 3, selectionRect.height > 3 else { return }
        selectedPhotoIDs = Set(photos.filter { selectionRect.intersects(canvasObjectRect(for: $0, metric: metric)) }.map(\.id))
    }

    private func canvasSelectionBounds(for objects: [ProjectPhoto], placements: [UUID: PrintPlacement] = [:]) -> PrintPlacement? {
        CanvasGeometry.selectionBounds(for: objects, placements: placements, rasterPath: { path(for: $0) })
    }

    private func canvasSelectionCenter(for objects: [ProjectPhoto], placements: [UUID: PrintPlacement] = [:]) -> Point? {
        CanvasGeometry.selectionCenter(for: objects, placements: placements, rasterPath: { path(for: $0) })
    }

    private func canvasRotationCenter(for object: ProjectPhoto) -> Point {
        CanvasGeometry.rotationCenter(for: object, rasterPath: { path(for: $0) })
    }

    private func canvasObjectRect(for object: ProjectPhoto, metric: LaserCanvasMetric) -> CGRect {
        rect(for: canvasSelectionBounds(for: [object]) ?? object.printPlacement, metric: metric)
    }

    private func canvasRestingObjectControlPoint(for object: ProjectPhoto, local: Point, placements: [UUID: PrintPlacement] = [:]) -> Point {
        CanvasGeometry.restingObjectControlPoint(for: object, local: local, placements: placements, rasterPath: { path(for: $0) })
    }

    private func canvasRotatingObjectControlPoint(for object: ProjectPhoto, local: Point, starts: [UUID: PrintPlacement], groupCenter: Point, delta: Double) -> Point {
        CanvasGeometry.rotatingObjectControlPoint(for: object, local: local, starts: starts, groupCenter: groupCenter, delta: delta, rasterPath: { path(for: $0) })
    }

    private func canvasRotatedPlacement(_ start: PrintPlacement, object: ProjectPhoto, degrees: Double) -> PrintPlacement {
        CanvasGeometry.rotatedPlacement(start, object: object, degrees: degrees, rasterPath: { path(for: $0) })
    }

    private func canvasRotatedGroupPlacement(_ start: PrintPlacement, object: ProjectPhoto, degrees: Double, groupCenter: Point, delta: Double) -> PrintPlacement {
        CanvasGeometry.rotatedGroupPlacement(start, object: object, degrees: degrees, groupCenter: groupCenter, delta: delta, rasterPath: { path(for: $0) })
    }

    private func bounds(for placements: [PrintPlacement]) -> PrintPlacement? {
        guard let first = placements.first else { return nil }
        let minX = placements.reduce(first.xMM) { min($0, $1.xMM) }
        let minY = placements.reduce(first.yMM) { min($0, $1.yMM) }
        let maxX = placements.reduce(first.xMM + first.widthMM) { max($0, $1.xMM + $1.widthMM) }
        let maxY = placements.reduce(first.yMM + first.heightMM) { max($0, $1.yMM + $1.heightMM) }
        return PrintPlacement(xMM: minX, yMM: minY, widthMM: maxX - minX, heightMM: maxY - minY)
    }

    private func minScaleFactor(_ starts: [UUID: PrintPlacement]) -> Double {
        starts.values.reduce(0.001) { max($0, 1 / max(0.001, min($1.widthMM, $1.heightMM))) }
    }

    private func applyRotation(_ edit: ActiveEdit, delta: Double) {
        rotationDraftDelta = delta
        for index in photos.indices {
            guard let start = edit.starts[photos[index].id] else { continue }
            let degrees = start.rotationDegrees + delta
            let placement = edit.starts.count > 1
                ? canvasRotatedGroupPlacement(start, object: photos[index], degrees: degrees, groupCenter: edit.groupCenter, delta: delta)
                : canvasRotatedPlacement(start, object: photos[index], degrees: degrees)
            rotationDraftDegrees[photos[index].id] = placement.rotationDegrees
            photos[index].printPlacement = RasterGenerator.minimumSizeConstrained(placement)
        }
    }

    private func snappedRotationDelta(_ delta: Double, edit: ActiveEdit) -> Double {
        guard let start = edit.starts[edit.id] ?? edit.starts.first?.value else { return delta }
        return CanvasRotationSnapper.snap(start.rotationDegrees + delta) - start.rotationDegrees
    }

    private func currentRotationDelta(edit: ActiveEdit) -> Double {
        rotationDraftDelta
    }

    private var rotationKnobSize: CGFloat {
        max(18, 28 / CGFloat(zoom))
    }

    private func rotationKnobPoint(metric: LaserCanvasMetric, objects: [ProjectPhoto]) -> CGPoint? {
        guard !objects.isEmpty else { return nil }
        if let activeEdit, activeEdit.kind == .rotate {
            return canvasRotationKnobPoint(groupStart: activeEdit.groupStart, groupCenter: activeEdit.groupCenter, delta: currentRotationDelta(edit: activeEdit), metric: metric)
        }
        guard let bounds = canvasSelectionBounds(for: objects), let center = canvasSelectionCenter(for: objects) else { return nil }
        return canvasRotationKnobPoint(groupStart: bounds, groupCenter: center, delta: 0, metric: metric)
    }

    private func canvasRotationKnobPoint(groupStart: PrintPlacement, groupCenter: Point, delta: Double, metric: LaserCanvasMetric) -> CGPoint {
        let gapMM = Double(rotationKnobSize / 2 + 4 / CGFloat(zoom)) / Double(metric.scale)
        let point = Point(x: groupStart.xMM + groupStart.widthMM / 2, y: groupStart.yMM - gapMM)
        return canvasPoint(for: rotatedPoint(point, around: groupCenter, degrees: delta), metric: metric)
    }

    private func rotationReadoutDegrees(objects: [ProjectPhoto]) -> Double? {
        guard let first = objects.first else { return nil }
        return normalizedRotationDegrees(rotationDraftDegrees[first.id] ?? first.printPlacement.rotationDegrees)
    }

    private func rotationPivot(metric: LaserCanvasMetric, edit: ActiveEdit) -> CGPoint? {
        let objects = photos.filter { edit.starts[$0.id] != nil }
        guard let first = objects.first else { return nil }
        if objects.count == 1, let placement = edit.starts[first.id] {
            return canvasPoint(for: placement.absolute(canvasRotationCenter(for: first)), metric: metric)
        }
        return canvasPoint(for: edit.groupCenter, metric: metric)
    }

    private func shortestAngleDelta(from start: Double, to current: Double) -> Double {
        var delta = current - start
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return delta
    }

    private func isFullyVisible(_ proxy: GeometryProxy) -> Bool {
        #if os(iOS)
        let frame = proxy.frame(in: .global)
        let screen = UIScreen.main.bounds
        return frame.minY >= screen.minY && frame.maxY <= screen.maxY
        #else
        true
        #endif
    }

    private func canvasPoint(from point: CGPoint, center: CGPoint, contentOffset: CGSize) -> CGPoint {
        CGPoint(
            x: center.x + (point.x - contentOffset.width - center.x) / zoom,
            y: center.y + (point.y - contentOffset.height - center.y) / zoom
        )
    }

    private func hitTest(_ point: CGPoint, metric: LaserCanvasMetric) -> Int? {
        for index in drawIndexes.reversed() {
            if canvasObjectRect(for: photos[index], metric: metric).contains(point) {
                return index
            }
        }
        return nil
    }

    private func isResizeHandle(_ point: CGPoint, object: ProjectPhoto, metric: LaserCanvasMetric) -> Bool {
        let handle = objectHandlePoint(for: object, local: CanvasControlLocal.resize, metric: metric)
        return hypot(point.x - handle.x, point.y - handle.y) <= 28 / zoom
    }

    private func isRotationHandle(_ point: CGPoint, metric: LaserCanvasMetric) -> Bool {
        guard let handle = rotationKnobPoint(metric: metric, objects: selectedObjects) else { return false }
        return hypot(point.x - handle.x, point.y - handle.y) <= 34 / zoom
    }

    private func objectHandlePoint(for object: ProjectPhoto, local: Point, metric: LaserCanvasMetric) -> CGPoint {
        if let activeEdit, activeEdit.kind == .rotate, activeEdit.starts[object.id] != nil {
            return canvasPoint(for: canvasRotatingObjectControlPoint(for: object, local: local, starts: activeEdit.starts, groupCenter: activeEdit.groupCenter, delta: currentRotationDelta(edit: activeEdit)), metric: metric)
        }
        return canvasPoint(for: canvasRestingObjectControlPoint(for: object, local: local), metric: metric)
    }

    private func canvasPoint(for placement: PrintPlacement, local: Point, metric: LaserCanvasMetric) -> CGPoint {
        let point = canvasControlPoint(for: placement, local: local)
        return canvasPoint(for: point, metric: metric)
    }

    private func canvasPoint(for point: Point, metric: LaserCanvasMetric) -> CGPoint {
        return CGPoint(x: metric.drawable.minX + CGFloat(point.x) * metric.scale, y: metric.drawable.minY + CGFloat(point.y) * metric.scale)
    }

    private func rect(for placement: PrintPlacement, metric: LaserCanvasMetric) -> CGRect {
        CGRect(
            x: metric.drawable.minX + CGFloat(placement.xMM) * metric.scale,
            y: metric.drawable.minY + CGFloat(placement.yMM) * metric.scale,
            width: CGFloat(placement.widthMM) * metric.scale,
            height: CGFloat(placement.heightMM) * metric.scale
        )
    }

    private func path(for photo: ProjectPhoto) -> String? {
        store?.imageURL(for: photo)?.path
    }

}

#if os(iOS)
private struct ProjectCanvasGestureLayer: UIViewRepresentable {
    @Binding var zoom: Double
    @Binding var pan: CGSize
    var onActiveChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = CanvasGestureAttachmentView()
        view.backgroundColor = .clear
        view.onHostChanged = { [coordinator = context.coordinator] host in
            coordinator.install(in: host)
        }
        context.coordinator.attachmentView = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attachmentView = view
        context.coordinator.install(in: view.window)
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.install(in: nil)
        (view as? CanvasGestureAttachmentView)?.onHostChanged = nil
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ProjectCanvasGestureLayer
        weak var attachmentView: UIView?
        private weak var gestureView: UIView?
        private let twoFingerPan: UIPanGestureRecognizer
        private let pinch: UIPinchGestureRecognizer
        private var startPan = CGSize.zero
        private var suppressPanUntil = 0.0
        private var ignoredPan: ObjectIdentifier?
        private var pinchState = PreviewPinchStateMachine()

        init(_ parent: ProjectCanvasGestureLayer) {
            self.parent = parent
            twoFingerPan = UIPanGestureRecognizer()
            pinch = UIPinchGestureRecognizer()
            super.init()
            twoFingerPan.addTarget(self, action: #selector(pan(_:)))
            twoFingerPan.minimumNumberOfTouches = 2
            twoFingerPan.maximumNumberOfTouches = 2
            pinch.addTarget(self, action: #selector(pinch(_:)))
            for recognizer in [twoFingerPan, pinch] {
                recognizer.delegate = self
                recognizer.cancelsTouchesInView = true
            }
        }

        func install(in view: UIView?) {
            guard gestureView !== view else { return }
            if let gestureView {
                gestureView.removeGestureRecognizer(twoFingerPan)
                gestureView.removeGestureRecognizer(pinch)
            }
            gestureView = view
            guard let view else { return }
            view.isMultipleTouchEnabled = true
            view.addGestureRecognizer(twoFingerPan)
            view.addGestureRecognizer(pinch)
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            let id = ObjectIdentifier(recognizer)
            if ignoredPan == id {
                if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
                    ignoredPan = nil
                    setActive(false, for: recognizer)
                }
                return
            }
            guard ProcessInfo.processInfo.systemUptime >= suppressPanUntil else {
                ignoredPan = id
                return
            }
            updateActive(for: recognizer)
            if recognizer.state == .began {
                startPan = parent.pan
            }
            let translation = recognizer.translation(in: attachmentView ?? recognizer.view)
            parent.pan = CGSize(width: startPan.width + translation.x, height: startPan.height + translation.y)
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let view = attachmentView ?? recognizer.view else { return }
            updateActive(for: recognizer)
            let location = recognizer.location(in: view)
            let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            suppressPanUntil = ProcessInfo.processInfo.systemUptime + 0.15
            let phase: PreviewGesturePhase
            switch recognizer.state {
            case .began:
                pinchState = PreviewPinchStateMachine(zoom: parent.zoom, panX: parent.pan.width, panY: parent.pan.height)
                phase = .began
            case .changed:
                phase = .changed
            case .ended:
                phase = .ended
            case .cancelled:
                phase = .cancelled
            case .failed:
                phase = .failed
            default:
                return
            }
            let next = pinchState.update(phase: phase, touches: recognizer.numberOfTouches, scale: recognizer.scale, locationX: location.x, locationY: location.y, centerX: center.x, centerY: center.y, minZoom: 0.5, maxZoom: 5)
            if phase == .changed {
                parent.zoom = next.zoom
                parent.pan = CGSize(width: next.panX, height: next.panY)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer === twoFingerPan || otherGestureRecognizer === pinch
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let attachmentView else { return false }
            return attachmentView.bounds.contains(touch.location(in: attachmentView))
        }

        private var activeRecognizers: Set<ObjectIdentifier> = []

        private func updateActive(for recognizer: UIGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                setActive(true, for: recognizer)
            case .ended, .cancelled, .failed:
                setActive(false, for: recognizer)
            default:
                break
            }
        }

        private func setActive(_ active: Bool, for recognizer: UIGestureRecognizer) {
            let wasActive = !activeRecognizers.isEmpty
            let id = ObjectIdentifier(recognizer)
            if active {
                activeRecognizers.insert(id)
            } else {
                activeRecognizers.remove(id)
            }
            let isActive = !activeRecognizers.isEmpty
            if wasActive != isActive {
                parent.onActiveChanged(isActive)
            }
        }
    }
}

private final class CanvasGestureAttachmentView: UIView {
    var onHostChanged: ((UIView?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onHostChanged?(window)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        false
    }
}
#endif

private struct LaserBedBackground: View {
    var metric: LaserCanvasMetric

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let dotXs = (0..<6).map { metric.dots.minX + CGFloat($0) * metric.dots.width / 5 }
            let dotYs = (0..<5).map { metric.dots.minY + CGFloat($0) * metric.dots.height / 4 }
            ZStack {
                BottomRoundedRectangle(radius: side * 0.075)
                    .fill(Color.secondary.opacity(0.05))
                    .frame(width: metric.plate.width, height: metric.plate.height)
                    .position(x: metric.plate.midX, y: metric.plate.midY)
                RoundedRectangle(cornerRadius: side * 0.025)
                    .stroke(Color.secondary.opacity(0.45), lineWidth: 1)
                    .frame(width: metric.inner.width, height: metric.inner.height)
                    .position(x: metric.inner.midX, y: metric.inner.midY)
                ForEach(0..<30, id: \.self) { index in
                    dot(x: dotXs[index % 6], y: dotYs[index / 6], side: side)
                }
                BottomRoundedRectangle(radius: side * 0.075)
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1.2)
                    .frame(width: metric.plate.width, height: metric.plate.height)
                    .position(x: metric.plate.midX, y: metric.plate.midY)
            }
        }
    }

    private func dot(x: CGFloat, y: CGFloat, side: CGFloat) -> some View {
        Circle()
            .fill(Color.secondary.opacity(0.58))
            .frame(width: max(2.2, side * 0.012), height: max(2.2, side * 0.012))
            .position(x: x, y: y)
    }
}

private struct InfiniteGrid: Shape {
    var metric: LaserCanvasMetric
    var zoom: Double
    var pan: CGSize

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = metric.side / 2
        let step = max(4, metric.scale * 10 * zoom)
        var x = center + (metric.drawable.minX - center) * zoom + pan.width
        while x > rect.minX { x -= step }
        while x <= rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += step
        }
        var y = center + (metric.drawable.minY - center) * zoom + pan.height
        while y > rect.minY { y -= step }
        while y <= rect.maxY {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += step
        }
        return path
    }
}

private struct DrawableShade: Shape {
    var metric: LaserCanvasMetric
    var zoom: Double
    var pan: CGSize

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = metric.side / 2
        let drawable = CGRect(
            x: center + (metric.drawable.minX - center) * zoom + pan.width,
            y: center + (metric.drawable.minY - center) * zoom + pan.height,
            width: metric.drawable.width * zoom,
            height: metric.drawable.height * zoom
        )
        path.addRect(rect)
        path.addRoundedRect(in: drawable, cornerSize: CGSize(width: metric.side * 0.025 * zoom, height: metric.side * 0.025 * zoom))
        return path
    }
}

private struct BottomRoundedRectangle: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(radius, rect.width / 2, rect.height / 2)
        path.move(to: rect.origin)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct BedCalibrationPanel: View {
    @Binding var field: String
    @Binding var plateX: Double
    @Binding var plateY: Double
    @Binding var plateWidth: Double
    @Binding var plateHeight: Double
    @Binding var dotsX: Double
    @Binding var dotsY: Double
    @Binding var dotsWidth: Double
    @Binding var dotsHeight: Double
    @Binding var innerX: Double
    @Binding var innerY: Double
    @Binding var innerWidth: Double
    @Binding var innerHeight: Double

    private let fields = [
        "Plate L", "Plate R", "Plate T", "Plate B",
        "Rounded L", "Rounded R", "Rounded T", "Rounded B",
        "Dots L", "Dots R", "Dots T", "Dots B",
    ]

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $field) {
                ForEach(fields, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 104)
            Slider(value: value, in: range)
            Text(value.wrappedValue, format: .number.precision(.fractionLength(3)))
                .font(.caption.monospacedDigit())
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 64)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var value: Binding<Double> {
        switch field {
        case "Plate L": edge($plateX, $plateWidth, minEdge: true)
        case "Plate R": edge($plateX, $plateWidth, minEdge: false)
        case "Plate T": edge($plateY, $plateHeight, minEdge: true)
        case "Plate B": edge($plateY, $plateHeight, minEdge: false)
        case "Dots L": edge($dotsX, $dotsWidth, minEdge: true)
        case "Dots R": edge($dotsX, $dotsWidth, minEdge: false)
        case "Dots T": edge($dotsY, $dotsHeight, minEdge: true)
        case "Dots B": edge($dotsY, $dotsHeight, minEdge: false)
        case "Rounded L": edge($innerX, $innerWidth, minEdge: true)
        case "Rounded R": edge($innerX, $innerWidth, minEdge: false)
        case "Rounded T": edge($innerY, $innerHeight, minEdge: true)
        case "Rounded B": edge($innerY, $innerHeight, minEdge: false)
        default: $plateX
        }
    }

    private var range: ClosedRange<Double> {
        0.00...1.00
    }

    private func edge(_ origin: Binding<Double>, _ size: Binding<Double>, minEdge: Bool) -> Binding<Double> {
        Binding {
            minEdge ? origin.wrappedValue : origin.wrappedValue + size.wrappedValue
        } set: { next in
            let other = minEdge ? origin.wrappedValue + size.wrappedValue : origin.wrappedValue
            if minEdge {
                origin.wrappedValue = min(next, other - 0.05)
                size.wrappedValue = other - origin.wrappedValue
            } else {
                size.wrappedValue = max(0.05, next - other)
            }
        }
    }
}

private struct SnapGuideLines: Shape {
    var result: CanvasSnapResult
    var metric: LaserCanvasMetric

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for x in result.verticalGuidesMM {
            let px = metric.drawable.minX + CGFloat(x) * metric.scale
            path.move(to: CGPoint(x: px, y: 0))
            path.addLine(to: CGPoint(x: px, y: rect.height))
        }
        for y in result.horizontalGuidesMM {
            let py = metric.drawable.minY + CGFloat(y) * metric.scale
            path.move(to: CGPoint(x: 0, y: py))
            path.addLine(to: CGPoint(x: rect.width, y: py))
        }
        return path
    }
}

struct ProjectPrintPreviewView: View {
    var preview: GCodePreview?
    var isLoading = false
    var darkBackground = false
    @State private var playing = true
    @State private var cycleStart = Date()
    @State private var pausedProgress = 0.0
    @State private var rendered: RenderedPrintPreview?
    @State private var rasterTextures: [PrintPreviewRasterTexture] = []
    @State private var zoom = 1.0
    @State private var zoomStart = 1.0
    @State private var pan = CGSize.zero
    @State private var panStart = CGSize.zero
    private var playbackDuration: Double { max(0.1, preview?.playbackDurationSeconds ?? 3) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 24.0)) { timeline in
            VStack(spacing: 8) {
                GeometryReader { proxy in
                    let side = min(proxy.size.width, proxy.size.height)
                    let duration = playbackDuration
                    let progress = progress(at: timeline.date, duration: duration)
                    let timeSeconds = progress * duration
                    ZStack {
                        Color.secondary.opacity(0.045)
                        ZStack {
                            darkBackground ? Color.black : Color.white
                            PrintPreviewBedGrid(darkBackground: darkBackground)
                            if let preview {
                                if preview.rasterLayers.isEmpty == false {
                                    PrintPreviewRasterLayer(layers: preview.rasterLayers, textures: rasterTextures, progress: progress, timeSeconds: timeSeconds, zoom: zoom, pan: pan, darkBackground: darkBackground)
                                        .frame(width: side, height: side)
                                } else if let rendered, rendered.id == preview.id {
                                    let frameIndex = rendered.frameIndex(at: progress)
                                    imageView(rendered.image(at: frameIndex))
                                        .frame(width: side, height: side)
                                        .clipped()
                                } else if preview.allPointsRetained, preview.points.isEmpty == false {
                                    PrintPreviewPointLayer(points: preview.points, visibleCount: visiblePointCount(progress: progress, total: preview.points.count), darkBackground: darkBackground)
                                        .frame(width: side, height: side)
                                }
                                if !preview.segments.isEmpty {
                                    PrintPreviewVectorLayer(segments: preview.segments, timeSeconds: timeSeconds, darkBackground: darkBackground)
                                        .frame(width: side, height: side)
                                }
                                if let sweep = currentSweep(in: preview, rendered: rendered, progress: progress, timeSeconds: timeSeconds), progress < 1 {
                                    PrintPreviewSweepOverlay(sweep: sweep, darkBackground: darkBackground)
                                        .frame(width: side, height: side)
                                }
                            }
                        }
                        .frame(width: side, height: side)
                        .scaleEffect(zoom, anchor: .center)
                        .offset(pan)
                        if isLoading {
                            ProgressView()
                                .controlSize(.regular)
                                .padding(12)
                                .background(.thinMaterial)
                                .clipShape(Circle())
                        }
                    }
                    .frame(width: side, height: side)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .clipped()
                    .contentShape(Rectangle())
                    #if os(iOS)
                    .overlay {
                        PrintPreviewGestureLayer(zoom: $zoom, pan: $pan, allowOneFingerPan: isFullyVisible(proxy))
                    }
                    #else
                    .gesture(panGesture)
                    .simultaneousGesture(zoomGesture)
                    #endif
                    .onTapGesture(count: 2, perform: resetViewport)
                }
                .aspectRatio(1, contentMode: .fit)

                HStack(spacing: 10) {
                    Button {
                        let now = Date()
                        let duration = playbackDuration
                        if playing {
                            pausedProgress = progress(at: now, duration: duration)
                            playing = false
                        } else {
                            cycleStart = now.addingTimeInterval(-pausedProgress * duration)
                            playing = true
                        }
                    } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.caption.weight(.semibold))
                            .frame(width: 30, height: 30)
                            .background(.thinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Slider(value: Binding {
                        progress(at: timeline.date, duration: playbackDuration)
                    } set: { value in
                        pausedProgress = min(1, max(0, value))
                        playing = false
                    }, in: 0...1)
                    .accessibilityIdentifier("print.preview.timeline")
                }
            }
            .frame(height: 356)
        }
        .task(id: preview?.id) {
            cycleStart = Date()
            pausedProgress = 0
            playing = true
            rendered = nil
            rasterTextures = []
            resetViewport()
            guard let preview else { return }
            rasterTextures = preview.rasterLayers.enumerated().compactMap { Self.rasterTexture(index: $0.offset, layer: $0.element) }
            guard let image = preview.imageData.flatMap(Self.platformImage) else { return }
            rendered = RenderedPrintPreview(id: preview.id, image: image, frameImages: preview.frames.compactMap(Self.platformImage), frameSweeps: preview.frameSweeps)
        }
    }

    @ViewBuilder private func imageView(_ image: PlatformImage) -> some View {
        #if os(iOS)
        let image = Image(uiImage: image)
        #elseif os(macOS)
        let image = Image(nsImage: image)
        #endif
        if darkBackground {
            image
                .resizable()
                .interpolation(.none)
                .scaledToFill()
                .colorInvert()
        } else {
            image
                .resizable()
                .interpolation(.none)
                .scaledToFill()
        }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                pan = CGSize(width: panStart.width + value.translation.width, height: panStart.height + value.translation.height)
            }
            .onEnded { _ in
                panStart = pan
            }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = min(16, max(0.5, zoomStart * value))
            }
            .onEnded { _ in
                zoomStart = zoom
            }
    }

    private func resetViewport() {
        zoom = 1
        zoomStart = 1
        pan = .zero
        panStart = .zero
    }

    private func isFullyVisible(_ proxy: GeometryProxy) -> Bool {
        #if os(iOS)
        let frame = proxy.frame(in: .global)
        let screen = UIScreen.main.bounds
        return frame.minY >= screen.minY && frame.maxY <= screen.maxY
        #else
        true
        #endif
    }

    private static func platformImage(from data: Data) -> PlatformImage? {
        #if os(iOS)
        UIImage(data: data)
        #elseif os(macOS)
        NSImage(data: data)
        #endif
    }

    private static func rasterTexture(index: Int, layer: GCodePreviewRaster) -> PrintPreviewRasterTexture? {
        guard let light = rasterImage(from: layer.displayPowers, width: layer.displayWidthPixels, height: layer.displayHeightPixels, dark: false),
              let dark = rasterImage(from: layer.displayPowers, width: layer.displayWidthPixels, height: layer.displayHeightPixels, dark: true) else { return nil }
        return PrintPreviewRasterTexture(index: index, lightImage: light, darkImage: dark)
    }

    private static func rasterImage(from powers: [UInt8], width: Int, height: Int, dark: Bool) -> CGImage? {
        guard width > 0, height > 0, powers.count == width * height else { return nil }
        var rgba = [UInt8](repeating: 0, count: powers.count * 4)
        for (i, alpha) in powers.enumerated() {
            let offset = i * 4
            rgba[offset] = dark ? alpha : 0
            rgba[offset + 1] = dark ? alpha : 0
            rgba[offset + 2] = dark ? alpha : 0
            rgba[offset + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private func progress(at date: Date, duration: Double) -> Double {
        guard playing else { return pausedProgress }
        let duration = max(0.1, duration)
        let time = date.timeIntervalSince(cycleStart).truncatingRemainder(dividingBy: duration * 2)
        return time < duration ? time / duration : 1
    }

    private func visiblePointCount(progress: Double, total: Int) -> Int {
        min(total, max(0, Int((progress * Double(total)).rounded(.down))))
    }

    private func currentSweep(in preview: GCodePreview, rendered: RenderedPrintPreview?, progress: Double, timeSeconds: Double) -> GCodePreviewSweep? {
        if preview.rasterLayers.contains(where: { $0.durationSeconds > 0 }) {
            return timedSweep(in: preview.rasterLayers, timeSeconds: timeSeconds)
        }
        if let rendered, rendered.id == preview.id, rendered.frameImages.isEmpty == false {
            return rendered.sweep(at: rendered.frameIndex(at: progress))
        }
        guard preview.sweeps.isEmpty == false else { return nil }
        let index = min(preview.sweeps.count - 1, max(0, Int(progress * Double(preview.sweeps.count))))
        return preview.sweeps[index]
    }

    private func timedSweep(in layers: [GCodePreviewRaster], timeSeconds: Double) -> GCodePreviewSweep? {
        for layer in layers where layer.durationSeconds > 0 && timeSeconds >= layer.startSecond && timeSeconds < layer.startSecond + layer.durationSeconds {
            guard abs(layer.rotationDegrees).truncatingRemainder(dividingBy: 360) < 0.0001 else { continue }
            let local = min(1, max(0, (timeSeconds - layer.startSecond) / layer.durationSeconds))
            let visibleBurns = Int((local * Double(layer.burnCount)).rounded(.down))
            guard visibleBurns > 0, layer.rowBurnOffsets.count > 1 else { continue }
            var row = 0
            while row + 1 < layer.rowBurnOffsets.count && layer.rowBurnOffsets[row + 1] <= visibleBurns {
                row += 1
            }
            guard row < layer.heightPixels else { continue }
            let rowStart = layer.rowBurnOffsets[row]
            let rowEnd = layer.rowBurnOffsets[min(row + 1, layer.rowBurnOffsets.count - 1)]
            let fraction = rowEnd == rowStart ? 1 : Double(max(0, visibleBurns - rowStart)) / Double(rowEnd - rowStart)
            let reversed = layer.scanDirection == .bidirectional && row.isMultiple(of: 2) == false
            let y = layer.yMM + layer.heightMM * Double(row) / Double(max(1, layer.heightPixels - 1))
            let start = reversed ? layer.xMM + layer.widthMM : layer.xMM
            let end = start + (reversed ? -layer.widthMM : layer.widthMM) * fraction
            return GCodePreviewSweep(startXMM: start, endXMM: end, yMM: y)
        }
        return nil
    }
}

private struct RenderedPrintPreview {
    var id: UUID
    var image: PlatformImage
    var frameImages: [PlatformImage]
    var frameSweeps: [GCodePreviewSweep?]

    func frameIndex(at progress: Double) -> Int {
        guard frameImages.isEmpty == false else { return 0 }
        return min(frameImages.count - 1, max(0, Int(progress * Double(frameImages.count - 1))))
    }

    func image(at index: Int) -> PlatformImage {
        guard frameImages.indices.contains(index) else { return image }
        return frameImages[index]
    }

    func sweep(at index: Int) -> GCodePreviewSweep? {
        frameSweeps.indices.contains(index) ? frameSweeps[index] : nil
    }
}

#if os(iOS)
private struct PrintPreviewGestureLayer: UIViewRepresentable {
    @Binding var zoom: Double
    @Binding var pan: CGSize
    var allowOneFingerPan: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let oneFingerPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.oneFingerPan(_:)))
        oneFingerPan.minimumNumberOfTouches = 1
        oneFingerPan.maximumNumberOfTouches = 1
        let twoFingerPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.twoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))

        for recognizer in [doubleTap, oneFingerPan, twoFingerPan, pinch] {
            recognizer.delegate = context.coordinator
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PrintPreviewGestureLayer
        private var startPan = CGSize.zero
        private var suppressPanUntil = 0.0
        private var ignoredPan: ObjectIdentifier?
        private var pinchState = PreviewPinchStateMachine()

        init(_ parent: PrintPreviewGestureLayer) {
            self.parent = parent
        }

        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            parent.zoom = 1
            parent.pan = .zero
        }

        @objc func oneFingerPan(_ recognizer: UIPanGestureRecognizer) {
            pan(recognizer)
        }

        @objc func twoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            pan(recognizer)
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let location = recognizer.location(in: view)
            let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            suppressPanUntil = ProcessInfo.processInfo.systemUptime + 0.15

            let phase: PreviewGesturePhase
            switch recognizer.state {
            case .began:
                pinchState = PreviewPinchStateMachine(zoom: parent.zoom, panX: parent.pan.width, panY: parent.pan.height)
                phase = .began
            case .changed:
                phase = .changed
            case .ended:
                phase = .ended
            case .cancelled:
                phase = .cancelled
            case .failed:
                phase = .failed
            default:
                return
            }

            let next = pinchState.update(phase: phase, touches: recognizer.numberOfTouches, scale: recognizer.scale, locationX: location.x, locationY: location.y, centerX: center.x, centerY: center.y)
            if phase == .changed {
                parent.zoom = next.zoom
                parent.pan = CGSize(width: next.panX, height: next.panY)
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            if pan.minimumNumberOfTouches >= 2 {
                return parent.zoom > 1.0001
            }
            return parent.allowOneFingerPan && parent.zoom > 1.0001
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        private func pan(_ recognizer: UIPanGestureRecognizer) {
            let id = ObjectIdentifier(recognizer)
            if ignoredPan == id {
                if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
                    ignoredPan = nil
                }
                return
            }
            guard ProcessInfo.processInfo.systemUptime >= suppressPanUntil else {
                ignoredPan = id
                return
            }
            if recognizer.state == .began {
                startPan = parent.pan
            }
            let translation = recognizer.translation(in: recognizer.view)
            parent.pan = CGSize(width: startPan.width + translation.x, height: startPan.height + translation.y)
        }
    }
}
#endif

private struct PrintPreviewBedGrid: View {
    var darkBackground: Bool

    var body: some View {
        Canvas { context, size in
            let line = Color.primary.opacity(darkBackground ? 0.18 : 0.08)
            let rect = CGRect(origin: .zero, size: size)
            context.stroke(Path(rect), with: .color(line), lineWidth: 1)
            for mm in stride(from: 23.0, through: 92.0, by: 23.0) {
                let x = size.width * mm / RasterGenerator.workAreaMM
                let y = size.height * mm / RasterGenerator.workAreaMM
                var vertical = Path()
                vertical.move(to: CGPoint(x: x, y: 0))
                vertical.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(vertical, with: .color(line), lineWidth: 0.5)
                var horizontal = Path()
                horizontal.move(to: CGPoint(x: 0, y: y))
                horizontal.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(horizontal, with: .color(line), lineWidth: 0.5)
            }
        }
    }
}

private struct PrintPreviewPointLayer: View {
    var points: [GCodePreviewPoint]
    var visibleCount: Int
    var darkBackground: Bool
    private let dotRadiusMM = RasterGenerator.maximumBitmapPitchMM / 2

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) * dotRadiusMM / RasterGenerator.workAreaMM
            let color = darkBackground ? Color.white : Color.black
            for point in points.prefix(max(0, min(visibleCount, points.count))) {
                let x = size.width * point.xMM / RasterGenerator.workAreaMM
                let y = size.height * point.yMM / RasterGenerator.workAreaMM
                let opacity = min(1, Double(point.power) / 1000)
                let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(opacity)))
            }
        }
    }
}

private struct PrintPreviewRasterTexture {
    var index: Int
    var lightImage: CGImage
    var darkImage: CGImage
}

private struct PrintPreviewRasterLayer: View {
    var layers: [GCodePreviewRaster]
    var textures: [PrintPreviewRasterTexture]
    var progress: Double
    var timeSeconds: Double
    var zoom: Double
    var pan: CGSize
    var darkBackground: Bool

    private let dotPitchThreshold: CGFloat = 0.75

    var body: some View {
        Canvas { context, size in
            let color = darkBackground ? Color.white : Color.black
            let simultaneous = layers.allSatisfy { $0.startBurnIndex == 0 }
            let totalBurns = max(1, layers.map { $0.startBurnIndex + $0.burnCount }.max() ?? 1)

            for (index, layer) in layers.enumerated() {
                let visible = visibleBurns(layer: layer, simultaneous: simultaneous, totalBurns: totalBurns)
                draw(layer, index: index, visibleBurns: max(0, min(layer.burnCount, visible)), color: color, in: &context, size: size)
            }
        }
    }

    private func visibleBurns(layer: GCodePreviewRaster, simultaneous: Bool, totalBurns: Int) -> Int {
        guard layer.durationSeconds > 0 else {
            return simultaneous
                ? Int((progress * Double(layer.burnCount)).rounded(.down))
                : Int((progress * Double(totalBurns)).rounded(.down)) - layer.startBurnIndex
        }
        let local = min(1, max(0, (timeSeconds - layer.startSecond) / layer.durationSeconds))
        return Int((local * Double(layer.burnCount)).rounded(.down))
    }

    private func draw(_ layer: GCodePreviewRaster, index: Int, visibleBurns: Int, color: Color, in context: inout GraphicsContext, size: CGSize) {
        guard visibleBurns > 0, layer.widthPixels > 0, layer.heightPixels > 0 else { return }
        let width = min(size.width, size.height)
        let pitch = width * layer.widthMM / RasterGenerator.workAreaMM / CGFloat(max(1, layer.widthPixels - 1))
        let screenPitch = max(0.001, pitch * zoom)
        if screenPitch < dotPitchThreshold, let texture = textures.first(where: { $0.index == index }) {
            drawTexture(texture, layer: layer, visibleBurns: visibleBurns, in: &context, width: width)
        } else {
            drawDots(layer, visibleBurns: visibleBurns, color: color, pitch: pitch, width: width, in: &context)
        }
    }

    private func drawTexture(_ texture: PrintPreviewRasterTexture, layer: GCodePreviewRaster, visibleBurns: Int, in context: inout GraphicsContext, width: CGFloat) {
        let origin = CGPoint(
            x: width * layer.xMM / RasterGenerator.workAreaMM,
            y: width * layer.yMM / RasterGenerator.workAreaMM
        )
        let rect = CGRect(
            x: 0,
            y: 0,
            width: width * layer.widthMM / RasterGenerator.workAreaMM,
            height: width * layer.heightMM / RasterGenerator.workAreaMM
        )
        let visible = visibleTextureRect(layer: layer, visibleBurns: visibleBurns, rect: rect)
        let image = Image(decorative: darkBackground ? texture.darkImage : texture.lightImage, scale: 1)
        context.drawLayer { layerContext in
            layerContext.translateBy(x: origin.x, y: origin.y)
            layerContext.rotate(by: .degrees(layer.rotationDegrees))
            layerContext.clip(to: Path(visible))
            layerContext.draw(image, in: rect)
        }
    }

    private func drawDots(_ layer: GCodePreviewRaster, visibleBurns: Int, color: Color, pitch: CGFloat, width: CGFloat, in context: inout GraphicsContext) {
        let visible = visibleSourceRect(layer: layer, width: width)
        let radius = pitch * 0.32

        for y in visible.y {
            let rowStart = layer.rowBurnOffsets[y]
            let rowEnd = layer.rowBurnOffsets[y + 1]
            guard rowStart < visibleBurns else { continue }
            let rowVisible = min(rowEnd - rowStart, visibleBurns - rowStart)
            let reversed = layer.scanDirection == .bidirectional && y.isMultiple(of: 2) == false
            let maxScanX = layer.widthPixels * rowVisible / max(1, rowEnd - rowStart)
            for x in visible.x {
                let scanX = reversed ? layer.widthPixels - 1 - x : x
                guard scanX <= maxScanX else { continue }
                let power = Int(layer.powers[y * layer.widthPixels + x])
                guard power > 0 else { continue }
                let point = point(layer: layer, x: x, y: y, width: width)
                let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(Double(power) / 255)))
            }
        }
    }

    private func point(layer: GCodePreviewRaster, x: Int, y: Int, width: CGFloat) -> CGPoint {
        let localX = width * layer.widthMM * Double(x) / Double(max(1, layer.widthPixels - 1)) / RasterGenerator.workAreaMM
        let localY = width * layer.heightMM * Double(y) / Double(max(1, layer.heightPixels - 1)) / RasterGenerator.workAreaMM
        let originX = width * layer.xMM / RasterGenerator.workAreaMM
        let originY = width * layer.yMM / RasterGenerator.workAreaMM
        let radians = layer.rotationDegrees * .pi / 180
        return CGPoint(
            x: originX + localX * cos(radians) - localY * sin(radians),
            y: originY + localX * sin(radians) + localY * cos(radians)
        )
    }

    private func visibleSourceRect(layer: GCodePreviewRaster, width: CGFloat) -> (x: ClosedRange<Int>, y: ClosedRange<Int>) {
        if abs(layer.rotationDegrees).truncatingRemainder(dividingBy: 360) > 0.0001 {
            return (0...max(0, layer.widthPixels - 1), 0...max(0, layer.heightPixels - 1))
        }
        let center = width / 2
        let minX = center + (0 - pan.width - center) / zoom
        let maxX = center + (width - pan.width - center) / zoom
        let minY = center + (0 - pan.height - center) / zoom
        let maxY = center + (width - pan.height - center) / zoom
        let layerX0 = width * layer.xMM / RasterGenerator.workAreaMM
        let layerY0 = width * layer.yMM / RasterGenerator.workAreaMM
        let layerW = width * layer.widthMM / RasterGenerator.workAreaMM
        let layerH = width * layer.heightMM / RasterGenerator.workAreaMM
        let x0 = Int(((minX - layerX0) / max(0.001, layerW) * Double(layer.widthPixels - 1)).rounded(.down)) - 2
        let x1 = Int(((maxX - layerX0) / max(0.001, layerW) * Double(layer.widthPixels - 1)).rounded(.up)) + 2
        let y0 = Int(((minY - layerY0) / max(0.001, layerH) * Double(layer.heightPixels - 1)).rounded(.down)) - 2
        let y1 = Int(((maxY - layerY0) / max(0.001, layerH) * Double(layer.heightPixels - 1)).rounded(.up)) + 2
        return (
            max(0, min(layer.widthPixels - 1, x0))...max(0, min(layer.widthPixels - 1, x1)),
            max(0, min(layer.heightPixels - 1, y0))...max(0, min(layer.heightPixels - 1, y1))
        )
    }

    private func visibleTextureRect(layer: GCodePreviewRaster, visibleBurns: Int, rect: CGRect) -> CGRect {
        guard layer.displayBurnCount > 0 else { return .null }
        let displayVisible = min(layer.displayBurnCount, Int(Double(visibleBurns) / Double(max(1, layer.burnCount)) * Double(layer.displayBurnCount)))
        var row = 0
        while row + 1 < layer.displayRowBurnOffsets.count, layer.displayRowBurnOffsets[row + 1] <= displayVisible {
            row += 1
        }
        let rowStart = layer.displayRowBurnOffsets[min(row, layer.displayRowBurnOffsets.count - 1)]
        let rowEnd = layer.displayRowBurnOffsets[min(row + 1, layer.displayRowBurnOffsets.count - 1)]
        let partial = rowEnd == rowStart ? 0 : CGFloat(displayVisible - rowStart) / CGFloat(rowEnd - rowStart)
        let visibleRows = min(CGFloat(layer.displayHeightPixels), CGFloat(row) + partial)
        return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * visibleRows / CGFloat(max(1, layer.displayHeightPixels)))
    }
}

private struct PrintPreviewSweepOverlay: View {
    var sweep: GCodePreviewSweep
    var darkBackground: Bool

    var body: some View {
        Canvas { context, size in
            let y = size.height * sweep.yMM / RasterGenerator.workAreaMM
            let start = size.width * sweep.startXMM / RasterGenerator.workAreaMM
            let end = size.width * sweep.endXMM / RasterGenerator.workAreaMM
            let color = darkBackground ? Color.cyan : Color.blue

            var row = Path()
            row.move(to: CGPoint(x: start, y: y))
            row.addLine(to: CGPoint(x: end, y: y))
            context.stroke(row, with: .color(color.opacity(0.9)), lineWidth: 2)
        }
    }
}

private struct PrintPreviewVectorLayer: View {
    var segments: [GCodePreviewSegment]
    var timeSeconds: Double
    var darkBackground: Bool

    var body: some View {
        Canvas { context, size in
            let color = darkBackground ? Color.white : Color.black
            var path = Path()
            for segment in segments {
                let fraction = visibleFraction(segment)
                guard fraction > 0 else { continue }
                let start = point(x: segment.x0MM, y: segment.y0MM, in: size)
                let end = point(
                    x: segment.x0MM + (segment.x1MM - segment.x0MM) * fraction,
                    y: segment.y0MM + (segment.y1MM - segment.y0MM) * fraction,
                    in: size
                )
                path.move(to: start)
                path.addLine(to: end)
            }
            context.stroke(path, with: .color(color.opacity(0.95)), style: StrokeStyle(lineWidth: 1, lineCap: .butt, lineJoin: .round))
        }
    }

    private func visibleFraction(_ segment: GCodePreviewSegment) -> Double {
        guard segment.durationSeconds > 0 else { return 1 }
        return min(1, max(0, (timeSeconds - segment.startSecond) / segment.durationSeconds))
    }

    private func point(x: Double, y: Double, in size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width * x / RasterGenerator.workAreaMM,
            y: size.height * y / RasterGenerator.workAreaMM
        )
    }
}

private struct PrintPreviewBackdropToggle: View {
    var darkBackground: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                BackdropModeIcon(mode: .normal, selected: !darkBackground, shade: (space: 0, edge: 0), date: Date())
                BackdropModeIcon(mode: .inverted, selected: darkBackground, shade: (space: 0, edge: 0), date: Date())
            }
            .padding(4)
            .background(.thinMaterial)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Print preview background")
    }
}

struct NumberField: View {
    @Binding var value: Double
    var suffix: String
    var range: ClosedRange<Double>?

    init(value: Binding<Double>, suffix: String, range: ClosedRange<Double>? = nil) {
        self._value = value
        self.suffix = suffix
        self.range = range
    }

    var body: some View {
        HStack {
            TextField("", value: $value, format: .number)
                .multilineTextAlignment(.trailing)
                .onSubmit(clamp)
            Text(suffix)
                .foregroundStyle(.secondary)
        }
        .frame(width: 120)
        .onChange(of: value) { _ in clamp() }
    }

    private func clamp() {
        guard let range else { return }
        value = min(range.upperBound, max(range.lowerBound, value))
    }
}

struct CompactNumberField: View {
    var label: String
    @Binding var value: Double

    init(_ label: String, value: Binding<Double>) {
        self.label = label
        self._value = value
    }

    var body: some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("", value: $value, format: .number.precision(.fractionLength(1)))
                .multilineTextAlignment(.leading)
                .frame(minWidth: 34)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum AppError: Error {
    case noStore
}

func copy(_ text: String) {
    #if os(iOS)
    UIPasteboard.general.string = text
    #elseif os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

@MainActor func dismissKeyboard() {
    #if os(iOS)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    #endif
}

private var screenBackground: Color {
    #if os(iOS)
    Color(uiColor: .systemGroupedBackground)
    #elseif os(macOS)
    Color(nsColor: .windowBackgroundColor)
    #endif
}

private var cardBackground: Color {
    #if os(iOS)
    Color(uiColor: .secondarySystemGroupedBackground)
    #elseif os(macOS)
    Color(nsColor: .controlBackgroundColor)
    #endif
}

private extension View {
    @ViewBuilder func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder func solidTabBar() -> some View {
        self
    }

    @ViewBuilder func hideTabBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .tabBar)
            .toolbarBackground(.hidden, for: .tabBar)
        #else
        self
        #endif
    }

    @ViewBuilder func dismissesKeyboardOnScroll() -> some View {
        #if os(iOS)
        scrollDismissesKeyboard(.interactively)
        #else
        self
        #endif
    }
}
