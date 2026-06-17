import Foundation
import ImageIO
import CryptoKit

public struct XCSImportSummary: Equatable {
    public var imported: [StoredProject]
    public var skipped: [String]
    public var failures: [String]

    public init(imported: [StoredProject] = [], skipped: [String] = [], failures: [String] = []) {
        self.imported = imported
        self.skipped = skipped
        self.failures = failures
    }
}

public final class FileAppStore {
    public let root: URL
    public var data: AppStoreData
    private let dataURL: URL

    public init(root: URL) throws {
        self.root = root
        self.dataURL = root.appendingPathComponent("store.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        self.data = try Self.load(from: dataURL)
        if try migrateLegacyPhotos() || migrateObjectAssets() {
            try save()
        }
    }

    public var imagesURL: URL {
        root.appendingPathComponent("Images")
    }

    public var projectsURL: URL {
        root.appendingPathComponent("Projects")
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(data).write(to: dataURL, options: .atomic)
    }

    public static func defaultProjectName(for date: Date = Date()) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    public func addImageProject(data imageData: Data, originalName: String? = nil) throws -> StoredProject {
        let createdAt = Date()
        let photo = try makePhoto(data: imageData, name: originalName?.nilIfEmpty ?? "Photo", defaults: defaultSettings())
        let project = StoredProject(name: Self.defaultProjectName(for: createdAt), createdAt: createdAt, updatedAt: createdAt, photos: [photo], frameSpeedMMPerSecond: data.lastFrameSpeedMMPerSecond ?? StoredProject.defaultFrameSpeedMMPerSecond)
        data.projects.insert(project, at: 0)
        try save()
        return project
    }

    public func addPhoto(data imageData: Data, to projectID: UUID, name: String = "Photo") throws -> StoredProject? {
        guard let index = data.projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        data.projects[index].photos.append(try makePhoto(data: imageData, name: name, defaults: defaultSettings(for: data.projects[index])))
        data.projects[index].updatedAt = Date()
        try save()
        return data.projects[index]
    }

    public func replace(projects: [StoredProject], libraryAssets: [LibraryAsset]) throws {
        data = AppStoreData(projects: [], libraryAssets: libraryAssets)
        for project in projects {
            _ = insertUnsaved(project: project, atStart: false)
        }
        try save()
    }

    public func insert(project: StoredProject) throws -> StoredProject {
        let saved = insertUnsaved(project: project)
        try save()
        return saved
    }

    public func importXCSProjects(from urls: [URL]) -> XCSImportSummary {
        var summary = XCSImportSummary()
        for url in urls {
            do {
                if let project = try importXCSProject(from: url) {
                    summary.imported.append(project)
                } else {
                    summary.skipped.append(url.lastPathComponent)
                }
            } catch {
                summary.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return summary
    }

    public func importXCSProject(from url: URL) throws -> StoredProject? {
        let draft = try XCSProjectImporter.makeDraft(data: Data(contentsOf: url), fileName: url.deletingPathExtension().lastPathComponent)
        guard !data.projects.contains(where: { $0.importFingerprint == draft.fingerprint }) else { return nil }
        var photos: [ProjectPhoto] = []
        for object in draft.objects {
            var photo = object.photo
            if let imageData = object.imageData {
                photo.assetID = try makeAsset(data: imageData, originalName: object.name).id
            }
            photos.append(photo)
        }
        var project = StoredProject(
            name: draft.name,
            createdAt: draft.createdAt,
            updatedAt: draft.updatedAt,
            photos: photos,
            frameSpeedMMPerSecond: data.lastFrameSpeedMMPerSecond ?? StoredProject.defaultFrameSpeedMMPerSecond,
            importFingerprint: draft.fingerprint
        )
        syncObjectAssets(in: &project)
        data.projects.insert(project, at: 0)
        try save()
        return project
    }

    public func update(project: StoredProject) throws {
        guard let index = data.projects.firstIndex(where: { $0.id == project.id }) else { return }
        var updated = project
        syncObjectAssets(in: &updated)
        updated.updatedAt = Date()
        data.projects[index] = updated
        try save()
    }

    public func renameProject(id: UUID, to name: String) throws {
        guard let index = data.projects.firstIndex(where: { $0.id == id }) else { return }
        data.projects[index].name = name
        data.projects[index].updatedAt = Date()
        try save()
    }

    public func deleteProject(id: UUID) throws {
        guard let index = data.projects.firstIndex(where: { $0.id == id }) else { return }
        data.projects.remove(at: index)
        try? FileManager.default.removeItem(at: projectsURL.appendingPathComponent(id.uuidString).appendingPathExtension("txt"))
        try? FileManager.default.removeItem(at: projectsURL.appendingPathComponent(id.uuidString).appendingPathExtension("png"))
        try save()
    }

    public func deleteUnusedAsset(id: UUID) throws {
        _ = try deleteUnusedAssets(ids: [id])
    }

    public func deleteUnusedAssets(ids: [UUID]) throws -> Int {
        let requested = Set(ids)
        guard !requested.isEmpty else { return 0 }
        let used = Set(data.projects.flatMap { $0.photos.compactMap(\.assetID) })
        var paths: [String] = []
        let before = data.libraryAssets.count
        data.libraryAssets.removeAll { asset in
            guard requested.contains(asset.id), !used.contains(asset.id) else { return false }
            paths.append(contentsOf: imagePaths(for: asset))
            return true
        }
        for path in Set(paths) {
            try? FileManager.default.removeItem(at: absoluteURL(for: path))
        }
        let deleted = before - data.libraryAssets.count
        if deleted > 0 {
            try save()
        }
        return deleted
    }

    private func imagePaths(for asset: LibraryAsset) -> [String] {
        ([asset.imagePath] + asset.undoHistory.map(\.imagePath) + asset.redoHistory.map(\.imagePath)).filter { !$0.isEmpty }
    }

    public func assetUseCounts() -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for id in data.projects.flatMap({ $0.photos.compactMap(\.assetID) }) {
            counts[id, default: 0] += 1
        }
        return counts
    }

    public func savePreset(name: String, settings: RasterSettings) throws -> SettingPreset {
        let preset = SettingPreset(name: name, settings: settings)
        data.settingPresets.removeAll { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        data.settingPresets.insert(preset, at: 0)
        data.lastPresetID = preset.id
        try save()
        return preset
    }

    public func updatePreset(id: UUID, settings: RasterSettings) throws {
        guard let index = data.settingPresets.firstIndex(where: { $0.id == id }) else { return }
        data.settingPresets[index].settings = settings
        data.settingPresets[index].updatedAt = Date()
        data.lastPresetID = id
        try save()
    }

    public func selectPreset(id: UUID) throws {
        data.lastPresetID = id
        try save()
    }

    public func saveVectorSettings(_ settings: VectorSettings) throws {
        data.lastVectorSettings = settings
        try save()
    }

    public func saveFrameSpeed(_ speedMMPerSecond: Double) throws {
        data.lastFrameSpeedMMPerSecond = min(FrameGCodeGenerator.maximumFrameSpeedMMPerSecond, max(1, speedMMPerSecond))
        try save()
    }

    public func recordMachineHost(_ host: String) throws {
        data.recentMachineHosts.removeAll { $0 == host }
        data.recentMachineHosts.insert(host, at: 0)
        data.recentMachineHosts = Array(data.recentMachineHosts.prefix(5))
        try save()
    }

    public func add(record: PrintRecord) throws {
        data.history.insert(record, at: 0)
        try save()
    }

    public func log(_ message: String, level: DebugLogLevel = .info) throws {
        data.debugLog.insert(DebugLogEntry(level: level, message: message), at: 0)
        try save()
    }

    public func clearLog() throws {
        data.debugLog.removeAll()
        try save()
    }

    public func writeGenerated(projectID: UUID, text: String, preview: Data?) throws {
        let base = projectsURL.appendingPathComponent(projectID.uuidString)
        try text.write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        if let preview {
            try preview.write(to: base.appendingPathExtension("png"), options: .atomic)
        }
    }

    public func absoluteURL(for relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    public func asset(for photo: ProjectPhoto) -> LibraryAsset? {
        photo.assetID.flatMap { id in data.libraryAssets.first { $0.id == id } }
    }

    public func imageURL(for photo: ProjectPhoto) -> URL? {
        if let asset = asset(for: photo), asset.kind == .raster, !asset.imagePath.isEmpty {
            return absoluteURL(for: asset.imagePath)
        }
        return photo.legacySourceImagePath.map(absoluteURL)
    }

    @discardableResult
    public func syncObjectAsset(for photo: inout ProjectPhoto, projectID: UUID, parentAssetID: UUID? = nil, editKind: String = "object", isShared: Bool? = nil) -> LibraryAsset? {
        guard photo.mode == .vector || photo.mode == .text else { return nil }
        let kind: LibraryAssetKind = photo.mode == .text ? .text : .vector
        let hash = Self.objectHash(photo)
        if let id = photo.assetID, let index = data.libraryAssets.firstIndex(where: { $0.id == id }) {
            if isShared ?? (assetUseCounts()[id, default: 0] > 1) {
                if data.libraryAssets[index].sha256 != hash {
                    let asset = objectAsset(from: photo, kind: kind, hash: hash, parentAssetID: id, editKind: editKind, projectID: projectID, undoHistory: [data.libraryAssets[index].state])
                    photo.assetID = asset.id
                    insert(asset, adjacentTo: id)
                    return asset
                }
                return data.libraryAssets[index]
            }
            data.libraryAssets[index].kind = kind
            data.libraryAssets[index].sha256 = hash
            data.libraryAssets[index].originalName = photo.name
            data.libraryAssets[index].vectorPaths = photo.vectorPaths
            data.libraryAssets[index].vectorSettings = photo.resolvedVectorSettings
            data.libraryAssets[index].vectorDrawing = photo.vectorDrawing
            data.libraryAssets[index].textSettings = photo.textSettings
            return data.libraryAssets[index]
        }
        if let asset = data.libraryAssets.first(where: { $0.kind == kind && $0.sha256 == hash }) {
            photo.assetID = asset.id
            return asset
        }
        let asset = objectAsset(from: photo, kind: kind, hash: hash, parentAssetID: parentAssetID, editKind: editKind, projectID: projectID)
        photo.assetID = asset.id
        insert(asset, adjacentTo: parentAssetID)
        return asset
    }

    @discardableResult
    public func commitObjectAsset(for photo: inout ProjectPhoto, projectID: UUID, editKind: String = "object") throws -> LibraryAsset? {
        guard photo.mode == .vector || photo.mode == .text else { return nil }
        if let id = photo.assetID, let index = data.libraryAssets.firstIndex(where: { $0.id == id }) {
            let previous = data.libraryAssets[index].state
            let kind: LibraryAssetKind = photo.mode == .text ? .text : .vector
            let next = LibraryAssetState(kind: kind, sha256: Self.objectHash(photo), originalName: photo.name, imagePath: "", vectorPaths: photo.vectorPaths, vectorSettings: photo.resolvedVectorSettings, vectorDrawing: photo.vectorDrawing, textSettings: photo.textSettings, mutation: PhotoMutation(parentAssetID: data.libraryAssets[index].mutation?.parentAssetID, editKind: editKind, projectID: projectID, photoID: photo.id))
            guard previous != next else { return data.libraryAssets[index] }
            if assetUseCounts()[id, default: 0] > 1 {
                guard previous.sha256 != next.sha256 else { return data.libraryAssets[index] }
                let asset = objectAsset(from: photo, kind: kind, hash: next.sha256, parentAssetID: id, editKind: editKind, projectID: projectID, undoHistory: [previous])
                photo.assetID = asset.id
                insert(asset, adjacentTo: id)
                try save()
                return asset
            }
            data.libraryAssets[index].undoHistory.append(previous)
            data.libraryAssets[index].redoHistory.removeAll()
            data.libraryAssets[index].kind = kind
            data.libraryAssets[index].sha256 = next.sha256
            data.libraryAssets[index].originalName = photo.name
            data.libraryAssets[index].imagePath = ""
            data.libraryAssets[index].vectorPaths = photo.vectorPaths
            data.libraryAssets[index].vectorSettings = photo.resolvedVectorSettings
            data.libraryAssets[index].vectorDrawing = photo.vectorDrawing
            data.libraryAssets[index].textSettings = photo.textSettings
            data.libraryAssets[index].mutation = next.mutation
            try save()
            return data.libraryAssets[index]
        }
        let asset = syncObjectAsset(for: &photo, projectID: projectID, editKind: editKind)
        try save()
        return asset
    }

    public func makeDerivedAsset(data imageData: Data, from photo: ProjectPhoto, projectID: UUID, editKind: String, values: [String: Double] = [:]) throws -> LibraryAsset {
        let hash = Self.sha256(imageData)
        if let assetID = photo.assetID, projectsUsing(assetID: assetID).count <= 1, let index = data.libraryAssets.firstIndex(where: { $0.id == assetID }) {
            let imagePath = "Images/\(hash)-\(assetID.uuidString).png"
            try imageData.write(to: absoluteURL(for: imagePath), options: .atomic)
            data.libraryAssets[index].undoHistory.append(data.libraryAssets[index].state)
            data.libraryAssets[index].redoHistory.removeAll()
            data.libraryAssets[index].sha256 = hash
            data.libraryAssets[index].imagePath = imagePath
            data.libraryAssets[index].mutation = PhotoMutation(parentAssetID: data.libraryAssets[index].mutation?.parentAssetID, editKind: editKind, values: values, projectID: projectID, photoID: photo.id)
            try save()
            return data.libraryAssets[index]
        }

        let id = UUID()
        let imagePath = "Images/\(hash)-\(id.uuidString).png"
        try imageData.write(to: absoluteURL(for: imagePath), options: .atomic)
        let asset = LibraryAsset(
            id: id,
            sha256: hash,
            originalName: asset(for: photo)?.originalName ?? photo.name,
            imagePath: imagePath,
            mutation: PhotoMutation(parentAssetID: photo.assetID, editKind: editKind, values: values, projectID: projectID, photoID: photo.id),
            undoHistory: asset(for: photo).map { [$0.state] } ?? []
        )
        insert(asset, adjacentTo: photo.assetID)
        try save()
        return asset
    }

    public func undoAsset(id: UUID) throws -> LibraryAsset? {
        guard let index = data.libraryAssets.firstIndex(where: { $0.id == id }),
              let state = data.libraryAssets[index].undoHistory.popLast() else { return nil }
        data.libraryAssets[index].redoHistory.append(data.libraryAssets[index].state)
        restore(state, on: &data.libraryAssets[index])
        try save()
        return data.libraryAssets[index]
    }

    public func redoAsset(id: UUID) throws -> LibraryAsset? {
        guard let index = data.libraryAssets.firstIndex(where: { $0.id == id }),
              let state = data.libraryAssets[index].redoHistory.popLast() else { return nil }
        data.libraryAssets[index].undoHistory.append(data.libraryAssets[index].state)
        restore(state, on: &data.libraryAssets[index])
        try save()
        return data.libraryAssets[index]
    }

    public func restoreAssets(_ assets: [LibraryAsset]) throws {
        var changed = false
        for asset in assets {
            guard let index = data.libraryAssets.firstIndex(where: { $0.id == asset.id }) else { continue }
            data.libraryAssets[index] = asset
            changed = true
        }
        if changed {
            try save()
        }
    }

    private func restore(_ state: LibraryAssetState, on asset: inout LibraryAsset) {
        if let kind = state.kind {
            asset.kind = kind
        }
        asset.sha256 = state.sha256
        if let originalName = state.originalName {
            asset.originalName = originalName
        }
        asset.imagePath = state.imagePath
        if let vectorPaths = state.vectorPaths {
            asset.vectorPaths = vectorPaths
        }
        asset.vectorSettings = state.vectorSettings
        asset.vectorDrawing = state.vectorDrawing
        asset.textSettings = state.textSettings
        asset.mutation = state.mutation
    }

    private func projectsUsing(assetID: UUID) -> Set<UUID> {
        Set(data.projects.compactMap { project in
            project.photos.contains { $0.assetID == assetID } ? project.id : nil
        })
    }

    private func insertUnsaved(project: StoredProject, atStart: Bool = true) -> StoredProject {
        var saved = project
        syncObjectAssets(in: &saved)
        saved.updatedAt = Date()
        if atStart {
            data.projects.insert(saved, at: 0)
        } else {
            data.projects.append(saved)
        }
        return saved
    }

    private static func load(from url: URL) throws -> AppStoreData {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppStoreData() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppStoreData.self, from: Data(contentsOf: url))
    }

    private func makePhoto(data imageData: Data, name: String, defaults: (String, RasterSettings)) throws -> ProjectPhoto {
        let asset = try makeAsset(data: imageData, originalName: name)
        var settings = defaults.1
        settings.placement = Self.defaultPlacement(for: imageData)
        settings.widthMM = settings.placement.widthMM
        settings.heightMM = settings.placement.heightMM
        return ProjectPhoto(name: name, assetID: asset.id, settingsName: defaults.0, settings: settings)
    }

    private func makeAsset(data imageData: Data, originalName: String) throws -> LibraryAsset {
        let hash = Self.sha256(imageData)
        if let asset = data.libraryAssets.first(where: { $0.sha256 == hash }) {
            return asset
        }
        let imagePath = "Images/\(hash).jpg"
        let imageURL = absoluteURL(for: imagePath)
        if !FileManager.default.fileExists(atPath: imageURL.path) {
            try imageData.write(to: imageURL, options: .atomic)
        }
        let asset = LibraryAsset(sha256: hash, originalName: originalName, imagePath: imagePath)
        data.libraryAssets.insert(asset, at: 0)
        return asset
    }

    private func syncObjectAssets(in project: inout StoredProject) {
        let globalCounts = assetUseCounts()
        var projectCounts: [UUID: Int] = [:]
        for id in project.photos.compactMap(\.assetID) {
            projectCounts[id, default: 0] += 1
        }
        for index in project.photos.indices {
            let id = project.photos[index].assetID
            let isShared = id.map { max(globalCounts[$0, default: 0], projectCounts[$0, default: 0]) > 1 }
            _ = syncObjectAsset(for: &project.photos[index], projectID: project.id, isShared: isShared)
        }
    }

    private func objectAsset(from photo: ProjectPhoto, kind: LibraryAssetKind, hash: String, parentAssetID: UUID?, editKind: String, projectID: UUID, undoHistory: [LibraryAssetState] = []) -> LibraryAsset {
        LibraryAsset(
            kind: kind,
            sha256: hash,
            originalName: photo.name,
            vectorPaths: photo.vectorPaths,
            vectorSettings: photo.resolvedVectorSettings,
            vectorDrawing: photo.vectorDrawing,
            textSettings: photo.textSettings,
            mutation: PhotoMutation(parentAssetID: parentAssetID, editKind: editKind, projectID: projectID, photoID: photo.id),
            undoHistory: undoHistory
        )
    }

    private func insert(_ asset: LibraryAsset, adjacentTo parentAssetID: UUID?) {
        if let parentAssetID, let index = data.libraryAssets.firstIndex(where: { $0.id == parentAssetID }) {
            data.libraryAssets.insert(asset, at: data.libraryAssets.index(after: index))
        } else {
            data.libraryAssets.insert(asset, at: 0)
        }
    }

    private func defaultSettings(for project: StoredProject? = nil) -> (String, RasterSettings) {
        if let photo = project?.photos.first {
            return (photo.settingsName, photo.settings)
        }
        if let id = data.lastPresetID, let preset = data.settingPresets.first(where: { $0.id == id }) {
            return (preset.name, preset.settings)
        }
        return ("Custom", RasterSettings())
    }

    private func migrateLegacyPhotos() throws -> Bool {
        var changed = false
        for index in data.projects.indices {
            for photoIndex in data.projects[index].photos.indices {
                if let assetID = try assetID(forLegacyPhoto: data.projects[index].photos[photoIndex]) {
                    data.projects[index].photos[photoIndex].assetID = assetID
                    data.projects[index].photos[photoIndex].legacySourceImagePath = nil
                    changed = true
                }
            }
            for undoIndex in data.projects[index].undoHistory.indices {
                for photoIndex in data.projects[index].undoHistory[undoIndex].photos.indices {
                    if let assetID = try assetID(forLegacyPhoto: data.projects[index].undoHistory[undoIndex].photos[photoIndex]) {
                        data.projects[index].undoHistory[undoIndex].photos[photoIndex].assetID = assetID
                        data.projects[index].undoHistory[undoIndex].photos[photoIndex].legacySourceImagePath = nil
                        changed = true
                    }
                }
            }
            for redoIndex in data.projects[index].redoHistory.indices {
                for photoIndex in data.projects[index].redoHistory[redoIndex].photos.indices {
                    if let assetID = try assetID(forLegacyPhoto: data.projects[index].redoHistory[redoIndex].photos[photoIndex]) {
                        data.projects[index].redoHistory[redoIndex].photos[photoIndex].assetID = assetID
                        data.projects[index].redoHistory[redoIndex].photos[photoIndex].legacySourceImagePath = nil
                        changed = true
                    }
                }
            }
        }
        return changed
    }

    private func migrateObjectAssets() -> Bool {
        var changed = false
        for index in data.projects.indices {
            var project = data.projects[index]
            for photoIndex in project.photos.indices where project.photos[photoIndex].assetID == nil && (project.photos[photoIndex].mode == .vector || project.photos[photoIndex].mode == .text) {
                _ = syncObjectAsset(for: &project.photos[photoIndex], projectID: project.id, editKind: "backfill")
                changed = true
            }
            data.projects[index] = project
        }
        return changed
    }

    private func assetID(forLegacyPhoto photo: ProjectPhoto) throws -> UUID? {
        guard photo.assetID == nil, let path = photo.legacySourceImagePath else { return nil }
        let url = absoluteURL(for: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try makeAsset(data: Data(contentsOf: url), originalName: url.deletingPathExtension().lastPathComponent).id
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func objectHash(_ photo: ProjectPhoto) -> String {
        let paths = photo.vectorPaths.map { path in
            ([path.closed ? "1" : "0"] + path.points.map { "\(fmt($0.x)),\(fmt($0.y))" }).joined(separator: "|")
        }.joined(separator: ";")
        let vector = photo.resolvedVectorSettings
        let drawing = photo.vectorDrawing.map { drawing in
            let raw = drawing.rawSegments.map { segment in segment.map { "\(fmt($0.x)),\(fmt($0.y))" }.joined(separator: "|") }.joined(separator: ";")
            let nodes = drawing.nodes.map { segment in segment.map { node in "\(fmt(node.point.x)),\(fmt(node.point.y)),\(fmt(node.tangent?.x ?? 0)),\(fmt(node.tangent?.y ?? 0))" }.joined(separator: "|") }.joined(separator: ";")
            return "\(fmt(drawing.smoothness))|\(fmt(drawing.accuracy))\n\(raw)\n\(nodes)"
        } ?? ""
        let text = photo.textSettings.map { "\($0.text)|\($0.fontFamily)|\(fmt($0.fontSize))|\(fmt($0.letterSpacing))|\(fmt($0.leading))|\($0.alignment.rawValue)" } ?? ""
        return sha256("\(photo.mode.rawValue)|\(photo.passes)\n\(paths)\n\(drawing)\n\(vector.laser.rawValue)|\(fmt(vector.speedMMPerSecond))|\(fmt(vector.powerPercent))\n\(text)".data(using: .utf8) ?? Data())
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private static func defaultPlacement(for data: Data) -> PrintPlacement {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            var width = properties[kCGImagePropertyPixelWidth] as? Double,
            var height = properties[kCGImagePropertyPixelHeight] as? Double,
            width > 0,
            height > 0
        else { return PrintPlacement() }
        if [5, 6, 7, 8].contains((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) {
            swap(&width, &height)
        }

        let maxSide = 68.0
        let scale = min(maxSide / width, maxSide / height)
        let printWidth = width * scale
        let printHeight = height * scale
        return PrintPlacement(
            xMM: (RasterGenerator.workAreaMM - printWidth) / 2,
            yMM: (RasterGenerator.workAreaMM - printHeight) / 2,
            widthMM: printWidth,
            heightMM: printHeight
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private struct XCSObjectDraft {
    var photo: ProjectPhoto
    var imageData: Data?
    var name: String
}

private struct XCSProjectDraft {
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var objects: [XCSObjectDraft]
    var fingerprint: String
}

private enum XCSImportError: LocalizedError {
    case invalidJSON
    case unsupportedProject
    case unsupportedObject(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON: "Invalid XCS JSON"
        case .unsupportedProject: "Unsupported XCS project"
        case .unsupportedObject(let type): "Unsupported XCS object: \(type)"
        }
    }
}

private enum XCSProjectImporter {
    typealias JSON = [String: Any]

    static func makeDraft(data: Data, fileName: String) throws -> XCSProjectDraft {
        guard let root = try JSONSerialization.jsonObject(with: data) as? JSON,
              root["extId"] as? String == "F1",
              let canvas = (root["canvas"] as? [JSON])?.first,
              let displays = canvas["displays"] as? [JSON]
        else { throw XCSImportError.invalidJSON }

        let process = processMap(root)
        let sorted = displays.sorted { int($0["zOrder"]) < int($1["zOrder"]) }
        var objects: [XCSObjectDraft] = []
        var canonical: [String] = ["xcs-v1"]
        for display in sorted {
            guard bool(display["visible"], default: true), bool(display["visibleState"], default: true) else { continue }
            guard intersectsWorkArea(display) else { continue }
            let id = string(display["id"])
            let processData = id.flatMap { process[$0] }
            let enabled = !(processData?.ignored ?? false)
            switch string(display["type"]) {
            case "BITMAP":
                let object = try bitmap(display, process: processData, enabled: enabled)
                canonical.append(fingerprintObject(object, imageData: object.imageData))
                objects.append(object)
            case "PATH":
                let object = try path(display, process: processData, enabled: enabled)
                canonical.append(fingerprintObject(object, imageData: nil))
                objects.append(object)
            case "TEXT":
                let object = try text(display, process: processData, enabled: enabled)
                canonical.append(fingerprintObject(object, imageData: nil))
                objects.append(object)
            case let type?:
                throw XCSImportError.unsupportedObject(type)
            default:
                throw XCSImportError.unsupportedObject("unknown")
            }
        }
        guard !objects.isEmpty else { throw XCSImportError.unsupportedProject }
        let fingerprint = sha256(canonical.joined(separator: "\n").data(using: .utf8) ?? Data())
        return XCSProjectDraft(name: fileName, createdAt: date(root["created"]), updatedAt: date(root["modify"]), objects: objects, fingerprint: fingerprint)
    }

    private static func bitmap(_ display: JSON, process: XCSProcess?, enabled: Bool) throws -> XCSObjectDraft {
        guard let imageData = dataURL(string(display["base64"])) else { throw XCSImportError.unsupportedObject("BITMAP without data") }
        var settings = rasterSettings(process: process)
        settings.placement = placement(display)
        settings.widthMM = settings.placement.widthMM
        settings.heightMM = settings.placement.heightMM
        let photo = ProjectPhoto(name: "Bitmap", mode: .raster, settingsName: "XCS", settings: settings, isEnabled: enabled)
        return XCSObjectDraft(photo: photo, imageData: imageData, name: "Bitmap")
    }

    private static func path(_ display: JSON, process: XCSProcess?, enabled: Bool) throws -> XCSObjectDraft {
        let placement = placement(display)
        let paths = normalize(try parsePath(string(display["dPath"]) ?? ""), in: placement)
        guard !paths.isEmpty else { throw XCSImportError.unsupportedObject("empty PATH") }
        let vector = vectorSettings(process: process, placement: placement)
        let photo = ProjectPhoto(name: "Vector", mode: .vector, settingsName: "XCS", settings: RasterSettings(placement: placement), vectorSettings: vector, vectorPaths: paths, isEnabled: enabled)
        return XCSObjectDraft(photo: photo, imageData: nil, name: "Vector")
    }

    private static func text(_ display: JSON, process: XCSProcess?, enabled: Bool) throws -> XCSObjectDraft {
        let placement = placement(display)
        let settings = textSettings(display)
        let paths = (display["charJSONs"] as? [JSON] ?? []).flatMap { char in
            (try? parsePath(string(char["dPath"]) ?? ""))?.map { transformed($0, char: char, parent: placement) } ?? []
        }
        let vector = vectorSettings(process: process, placement: placement)
        let normalized = paths.isEmpty ? TextVectorGenerator.paths(for: settings, placement: placement) : paths
        let photo = ProjectPhoto(name: settings.text.nilIfEmpty ?? "Text", mode: .text, settingsName: "XCS", settings: RasterSettings(placement: placement), vectorSettings: vector, vectorPaths: normalized, textSettings: settings, isEnabled: enabled)
        return XCSObjectDraft(photo: photo, imageData: nil, name: settings.text.nilIfEmpty ?? "Text")
    }

    private static func processMap(_ root: JSON) -> [String: XCSProcess] {
        guard let device = root["device"] as? JSON,
              let data = device["data"] as? JSON,
              let canvases = data["value"] as? [Any]
        else { return [:] }
        var output: [String: XCSProcess] = [:]
        for canvasValue in canvases {
            guard let pair = canvasValue as? [Any],
                  pair.count > 1,
                  let canvas = pair[1] as? JSON,
                  let displays = canvas["displays"] as? JSON,
                  let values = displays["value"] as? [Any]
            else { continue }
            for value in values {
                guard let pair = value as? [Any],
                      pair.count > 1,
                      let id = pair[0] as? String,
                      let info = pair[1] as? JSON
                else { continue }
                output[id] = XCSProcess(info)
            }
        }
        return output
    }

    private static func rasterSettings(process: XCSProcess?) -> RasterSettings {
        let custom = process?.custom ?? [:]
        let range = custom["powerMinMaxRange"] as? [Any]
        var settings = RasterSettings(
            laser: laser(custom["processingLightSource"]),
            dpi: double(custom["dpi"]) ?? RasterSettings.defaultDPI,
            speedMMPerSecond: double(custom["speed"]) ?? 80,
            minPowerPercent: double(range?.first) ?? 0,
            maxPowerPercent: double(range?.dropFirst().first) ?? double(custom["power"]) ?? 100,
            scanDirection: .bidirectional
        )
        if let dot = double(custom["dotDuration"]) {
            settings.dotDurationMicroseconds = dot
        }
        return settings
    }

    private static func vectorSettings(process: XCSProcess?, placement: PrintPlacement) -> VectorSettings {
        let custom = process?.custom ?? [:]
        return VectorSettings(
            laser: laser(custom["processingLightSource"]),
            placement: placement,
            speedMMPerSecond: double(custom["speed"]) ?? 20,
            powerPercent: double(custom["power"]) ?? 10
        )
    }

    private static func textSettings(_ display: JSON) -> TextSettings {
        let style = display["style"] as? JSON ?? [:]
        return TextSettings(
            text: string(display["text"]) ?? "Text",
            fontFamily: string(style["fontFamily"]) ?? "Helvetica",
            fontSubfamily: string(style["fontSubfamily"]),
            fontSource: string(style["fontSource"]),
            fontSize: double(style["fontSize"]) ?? 18,
            letterSpacing: double(style["letterSpacing"]) ?? 0,
            leading: double(style["leading"]) ?? 0,
            alignment: LaserTextAlignment(rawValue: string(style["align"]) ?? "center") ?? .center,
            curveX: double(style["curveX"]) ?? 0,
            curveY: double(style["curveY"]) ?? 0
        )
    }

    private static func placement(_ display: JSON) -> PrintPlacement {
        PrintPlacement(
            xMM: double(display["x"]) ?? 0,
            yMM: double(display["y"]) ?? 0,
            widthMM: max(0.001, double(display["width"]) ?? 1),
            heightMM: max(0.001, double(display["height"]) ?? 1),
            rotationDegrees: double(display["angle"]) ?? 0
        )
    }

    private static func intersectsWorkArea(_ display: JSON) -> Bool {
        let placement = placement(display)
        return placement.xMM < RasterGenerator.workAreaMM &&
            placement.yMM < RasterGenerator.workAreaMM &&
            placement.xMM + placement.widthMM > 0 &&
            placement.yMM + placement.heightMM > 0
    }

    private static func transformed(_ path: LaserPath, char: JSON, parent: PrintPlacement) -> LaserPath {
        let sx = double((char["scale"] as? JSON)?["x"]) ?? 1
        let sy = double((char["scale"] as? JSON)?["y"]) ?? 1
        let x = double(char["x"]) ?? 0
        let y = double(char["y"]) ?? 0
        let angle = (double(char["angle"]) ?? 0) * .pi / 180
        return LaserPath(closed: path.closed, points: path.points.map { point in
            let px = point.x * sx
            let py = point.y * sy
            let absolute = Point(x: x + px * cos(angle) - py * sin(angle), y: y + px * sin(angle) + py * cos(angle))
            return parent.local(absolute)
        })
    }

    private static func normalize(_ paths: [LaserPath], in placement: PrintPlacement) -> [LaserPath] {
        paths.map { path in
            LaserPath(closed: path.closed, points: path.points.map { placement.local($0) })
        }
    }

    private static func parsePath(_ string: String) throws -> [LaserPath] {
        let tokens = pathTokens(string)
        var index = 0
        var command: Character?
        var cursor = Point(x: 0, y: 0)
        var start = cursor
        var current: [Point] = []
        var paths: [LaserPath] = []
        var lastCubicControl: Point?
        var lastQuadControl: Point?

        func closeCurrent(_ closed: Bool) {
            if current.count > 1 {
                paths.append(LaserPath(closed: closed, points: current))
            }
            current = []
        }

        func resetCurveControls() {
            lastCubicControl = nil
            lastQuadControl = nil
        }

        while index < tokens.count {
            if let first = tokens[index].first, first.isLetter {
                command = first
                index += 1
            }
            guard let command else { break }
            let relative = command.isLowercase
            switch Character(command.uppercased()) {
            case "M":
                guard let point = readPoint(tokens: tokens, index: &index, relativeTo: cursor, relative: relative) else { break }
                closeCurrent(false)
                cursor = point
                start = point
                current = [point]
                resetCurveControls()
                while let point = readPoint(tokens: tokens, index: &index, relativeTo: cursor, relative: relative) {
                    cursor = point
                    current.append(point)
                }
            case "L":
                while let point = readPoint(tokens: tokens, index: &index, relativeTo: cursor, relative: relative) {
                    if current.isEmpty {
                        current = [cursor]
                    }
                    cursor = point
                    current.append(point)
                }
                resetCurveControls()
            case "H":
                while let value = readNumber(tokens: tokens, index: &index) {
                    if current.isEmpty {
                        current = [cursor]
                    }
                    cursor = Point(x: relative ? cursor.x + value : value, y: cursor.y)
                    current.append(cursor)
                }
                resetCurveControls()
            case "V":
                while let value = readNumber(tokens: tokens, index: &index) {
                    if current.isEmpty {
                        current = [cursor]
                    }
                    cursor = Point(x: cursor.x, y: relative ? cursor.y + value : value)
                    current.append(cursor)
                }
                resetCurveControls()
            case "C":
                while let c1 = readPoint(tokens: tokens, index: &index, relativeTo: cursor, relative: relative),
                      let c2 = readPoint(tokens: tokens, index: &index, relativeTo: cursor, relative: relative),
                      let end = readPoint(tokens: tokens, index: &index, relativeTo: cursor, relative: relative) {
                    if current.isEmpty {
                        current = [cursor]
                    }
                    for step in 1...12 {
                        current.append(cubic(cursor, c1, c2, end, Double(step) / 12))
                    }
                    lastCubicControl = c2
                    lastQuadControl = nil
                    cursor = end
                }
            case "S":
                while let c2 = readPoint(tokens: tokens, index: &index, relativeTo: cursor, relative: relative),
                      let end = readPoint(tokens: tokens, index: &index, relativeTo: cursor, relative: relative) {
                    if current.isEmpty {
                        current = [cursor]
                    }
                    let c1 = lastCubicControl.map { reflect($0, around: cursor) } ?? cursor
                    for step in 1...12 {
                        current.append(cubic(cursor, c1, c2, end, Double(step) / 12))
                    }
                    lastCubicControl = c2
                    lastQuadControl = nil
                    cursor = end
                }
            case "Q":
                while let c = readPoint(tokens: tokens, index: &index, relativeTo: cursor, relative: relative),
                      let end = readPoint(tokens: tokens, index: &index, relativeTo: cursor, relative: relative) {
                    if current.isEmpty {
                        current = [cursor]
                    }
                    for step in 1...8 {
                        current.append(quad(cursor, c, end, Double(step) / 8))
                    }
                    lastQuadControl = c
                    lastCubicControl = nil
                    cursor = end
                }
            case "T":
                while let end = readPoint(tokens: tokens, index: &index, relativeTo: cursor, relative: relative) {
                    if current.isEmpty {
                        current = [cursor]
                    }
                    let c = lastQuadControl.map { reflect($0, around: cursor) } ?? cursor
                    for step in 1...8 {
                        current.append(quad(cursor, c, end, Double(step) / 8))
                    }
                    lastQuadControl = c
                    lastCubicControl = nil
                    cursor = end
                }
            case "A":
                while index < tokens.count {
                    let startIndex = index
                    guard let rx = readNumber(tokens: tokens, index: &index),
                          let ry = readNumber(tokens: tokens, index: &index),
                          let rotation = readNumber(tokens: tokens, index: &index),
                          let large = readNumber(tokens: tokens, index: &index),
                          let sweep = readNumber(tokens: tokens, index: &index),
                          let end = readPoint(tokens: tokens, index: &index, relativeTo: cursor, relative: relative)
                    else {
                        index = startIndex
                        break
                    }
                    if current.isEmpty {
                        current = [cursor]
                    }
                    current.append(contentsOf: arcPoints(from: cursor, to: end, radiusX: rx, radiusY: ry, rotationDegrees: rotation, largeArc: large != 0, sweep: sweep != 0))
                    cursor = end
                }
                resetCurveControls()
            case "Z":
                closeCurrent(true)
                cursor = start
                resetCurveControls()
            default:
                throw XCSImportError.unsupportedObject("path command \(command)")
            }
        }
        closeCurrent(false)
        return paths
    }

    private static func pathTokens(_ string: String) -> [String] {
        let pattern = "[AaCcHhLlMmQqSsTtVvZz]|[-+]?(?:\\d*\\.\\d+|\\d+)(?:[eE][-+]?\\d+)?"
        let regex = try? NSRegularExpression(pattern: pattern)
        let ns = string as NSString
        return regex?.matches(in: string, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) } ?? []
    }

    private static func readPoint(tokens: [String], index: inout Int, relativeTo cursor: Point, relative: Bool) -> Point? {
        let start = index
        guard let x = readNumber(tokens: tokens, index: &index), let y = readNumber(tokens: tokens, index: &index) else {
            index = start
            return nil
        }
        return relative ? Point(x: cursor.x + x, y: cursor.y + y) : Point(x: x, y: y)
    }

    private static func readNumber(tokens: [String], index: inout Int) -> Double? {
        guard index < tokens.count, let value = Double(tokens[index]) else { return nil }
        index += 1
        return value
    }

    private static func cubic(_ a: Point, _ b: Point, _ c: Point, _ d: Point, _ t: Double) -> Point {
        let u = 1 - t
        return Point(
            x: u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x,
            y: u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y
        )
    }

    private static func quad(_ a: Point, _ b: Point, _ c: Point, _ t: Double) -> Point {
        let u = 1 - t
        return Point(x: u * u * a.x + 2 * u * t * b.x + t * t * c.x, y: u * u * a.y + 2 * u * t * b.y + t * t * c.y)
    }

    private static func reflect(_ point: Point, around center: Point) -> Point {
        Point(x: center.x * 2 - point.x, y: center.y * 2 - point.y)
    }

    private static func arcPoints(from start: Point, to end: Point, radiusX: Double, radiusY: Double, rotationDegrees: Double, largeArc: Bool, sweep: Bool) -> [Point] {
        var rx = abs(radiusX)
        var ry = abs(radiusY)
        guard rx > 0.0001, ry > 0.0001, hypot(start.x - end.x, start.y - end.y) > 0.0001 else { return [end] }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2
        let dy = (start.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        let scale = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if scale > 1 {
            let factor = sqrt(scale)
            rx *= factor
            ry *= factor
        }

        let rx2 = rx * rx
        let ry2 = ry * ry
        let x12 = x1 * x1
        let y12 = y1 * y1
        let sign = largeArc == sweep ? -1.0 : 1.0
        let ratio = max(0, (rx2 * ry2 - rx2 * y12 - ry2 * x12) / max(0.000001, rx2 * y12 + ry2 * x12))
        let cx1 = sign * sqrt(ratio) * rx * y1 / ry
        let cy1 = sign * -sqrt(ratio) * ry * x1 / rx
        let center = Point(
            x: cosPhi * cx1 - sinPhi * cy1 + (start.x + end.x) / 2,
            y: sinPhi * cx1 + cosPhi * cy1 + (start.y + end.y) / 2
        )
        let v1 = Point(x: (x1 - cx1) / rx, y: (y1 - cy1) / ry)
        let v2 = Point(x: (-x1 - cx1) / rx, y: (-y1 - cy1) / ry)
        let startAngle = atan2(v1.y, v1.x)
        var delta = atan2(v1.x * v2.y - v1.y * v2.x, v1.x * v2.x + v1.y * v2.y)
        if !sweep && delta > 0 {
            delta -= 2 * .pi
        } else if sweep && delta < 0 {
            delta += 2 * .pi
        }
        let steps = max(4, Int(ceil(abs(delta) / (.pi / 12))))
        return (1...steps).map { step in
            let angle = startAngle + delta * Double(step) / Double(steps)
            let x = rx * cos(angle)
            let y = ry * sin(angle)
            return Point(x: center.x + cosPhi * x - sinPhi * y, y: center.y + sinPhi * x + cosPhi * y)
        }
    }

    private static func fingerprintObject(_ object: XCSObjectDraft, imageData: Data?) -> String {
        let photo = object.photo
        let placement = photo.printPlacement
        let settings = photo.resolvedVectorSettings
        let raster = photo.settings
        let paths = photo.vectorPaths.map { path in
            ([path.closed ? "1" : "0"] + path.points.map { "\(round4($0.x)),\(round4($0.y))" }).joined(separator: "|")
        }.joined(separator: ";")
        return [
            photo.mode.rawValue,
            photo.name,
            photo.isEnabled ? "enabled" : "disabled",
            "\(round4(placement.xMM)),\(round4(placement.yMM)),\(round4(placement.widthMM)),\(round4(placement.heightMM)),\(round4(placement.rotationDegrees))",
            "\(settings.laser.rawValue),\(round4(settings.speedMMPerSecond)),\(round4(settings.powerPercent))",
            "\(raster.laser.rawValue),\(round4(raster.dpi)),\(round4(raster.speedMMPerSecond)),\(round4(raster.minPowerPercent)),\(round4(raster.maxPowerPercent)),\(round4(raster.dotDurationMicroseconds))",
            photo.textSettings.map { "\($0.text)|\($0.fontFamily)|\($0.fontSubfamily ?? "")|\(round4($0.fontSize))|\(round4($0.letterSpacing))|\(round4($0.leading))|\($0.alignment.rawValue)" } ?? "",
            imageData.map(sha256) ?? "",
            paths
        ].joined(separator: "\t")
    }

    private static func round4(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private static func dataURL(_ value: String?) -> Data? {
        guard let value else { return nil }
        let base64 = value.split(separator: ",", maxSplits: 1).last.map(String.init) ?? value
        return Data(base64Encoded: base64)
    }

    private static func laser(_ value: Any?) -> Laser {
        (string(value) == "red" || string(value) == "infrared") ? .infrared : .blue
    }

    private static func date(_ value: Any?) -> Date {
        Date(timeIntervalSince1970: (double(value) ?? Date().timeIntervalSince1970 * 1000) / 1000)
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? Int(double(value) ?? 0)
    }

    private static func bool(_ value: Any?, default defaultValue: Bool) -> Bool {
        (value as? NSNumber)?.boolValue ?? value as? Bool ?? defaultValue
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct XCSProcess {
    var type: String?
    var ignored: Bool
    var custom: XCSProjectImporter.JSON

    init(_ json: XCSProjectImporter.JSON) {
        type = json["processingType"] as? String
        ignored = (json["processIgnore"] as? NSNumber)?.boolValue ?? json["processIgnore"] as? Bool ?? false
        if let type,
           let data = json["data"] as? XCSProjectImporter.JSON,
           let process = data[type] as? XCSProjectImporter.JSON,
           let parameter = process["parameter"] as? XCSProjectImporter.JSON,
           let custom = parameter["customize"] as? XCSProjectImporter.JSON {
            self.custom = custom
        } else {
            custom = [:]
        }
    }
}
