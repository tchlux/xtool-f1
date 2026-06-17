import Foundation

public enum ProjectMode: String, Codable, CaseIterable, Sendable {
    case raster
    case vector
    case text
}

public enum ScanDirection: String, Codable, CaseIterable, Sendable {
    case leftToRight
    case bidirectional
}

public enum RasterGCodeMode: String, Codable, CaseIterable, Sendable {
    case asset
    case scanline
}

public enum FrameMode: String, Codable, CaseIterable, Sendable {
    case outline
    case rectangle
    case wrap
}

public struct PrintPlacement: Codable, Equatable, Sendable {
    public var xMM: Double
    public var yMM: Double
    public var widthMM: Double
    public var heightMM: Double
    public var rotationDegrees: Double

    public init(xMM: Double = 37.5, yMM: Double = 37.5, widthMM: Double = 40, heightMM: Double = 40, rotationDegrees: Double = 0) {
        self.xMM = xMM
        self.yMM = yMM
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.rotationDegrees = rotationDegrees
    }

    private enum CodingKeys: String, CodingKey {
        case xMM
        case yMM
        case widthMM
        case heightMM
        case rotationDegrees
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        xMM = try values.decodeIfPresent(Double.self, forKey: .xMM) ?? 37.5
        yMM = try values.decodeIfPresent(Double.self, forKey: .yMM) ?? 37.5
        widthMM = try values.decodeIfPresent(Double.self, forKey: .widthMM) ?? 40
        heightMM = try values.decodeIfPresent(Double.self, forKey: .heightMM) ?? 40
        rotationDegrees = try values.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0
    }

    public func absolute(_ point: Point) -> Point {
        let x = point.x * widthMM
        let y = point.y * heightMM
        let radians = rotationDegrees * .pi / 180
        return Point(x: xMM + x * cos(radians) - y * sin(radians), y: yMM + x * sin(radians) + y * cos(radians))
    }

    public func local(_ point: Point) -> Point {
        let x = point.x - xMM
        let y = point.y - yMM
        let radians = -rotationDegrees * .pi / 180
        let rx = x * cos(radians) - y * sin(radians)
        let ry = x * sin(radians) + y * cos(radians)
        return Point(x: rx / max(0.001, widthMM), y: ry / max(0.001, heightMM))
    }
}

public struct CanvasSnapResult: Equatable, Sendable {
    public var placement: PrintPlacement
    public var verticalGuidesMM: [Double]
    public var horizontalGuidesMM: [Double]

    public init(placement: PrintPlacement, verticalGuidesMM: [Double] = [], horizontalGuidesMM: [Double] = []) {
        self.placement = placement
        self.verticalGuidesMM = verticalGuidesMM
        self.horizontalGuidesMM = horizontalGuidesMM
    }
}

public enum CanvasSnapper {
    public static func snap(_ placement: PrintPlacement, to others: [PrintPlacement], workAreaMM: Double = 115, thresholdMM: Double = 2) -> CanvasSnapResult {
        let verticalTargets = [workAreaMM / 2] + others.flatMap { [$0.xMM, $0.xMM + $0.widthMM / 2, $0.xMM + $0.widthMM] }
        let horizontalTargets = [workAreaMM / 2] + others.flatMap { [$0.yMM, $0.yMM + $0.heightMM / 2, $0.yMM + $0.heightMM] }
        let xSnap = snapDelta(sources: [placement.xMM, placement.xMM + placement.widthMM / 2, placement.xMM + placement.widthMM], targets: verticalTargets, threshold: thresholdMM)
        let ySnap = snapDelta(sources: [placement.yMM, placement.yMM + placement.heightMM / 2, placement.yMM + placement.heightMM], targets: horizontalTargets, threshold: thresholdMM)
        return CanvasSnapResult(
            placement: PrintPlacement(
                xMM: placement.xMM + (xSnap?.delta ?? 0),
                yMM: placement.yMM + (ySnap?.delta ?? 0),
                widthMM: placement.widthMM,
                heightMM: placement.heightMM,
                rotationDegrees: placement.rotationDegrees
            ),
            verticalGuidesMM: xSnap.map { [$0.target] } ?? [],
            horizontalGuidesMM: ySnap.map { [$0.target] } ?? []
        )
    }

    private static func snapDelta(sources: [Double], targets: [Double], threshold: Double) -> (delta: Double, target: Double)? {
        let candidates = sources.flatMap { source in targets.map { target in (delta: target - source, target: target) } }
            .filter { abs($0.delta) <= threshold }
        return candidates.min {
            abs($0.delta) == abs($1.delta) ? $0.target > $1.target : abs($0.delta) < abs($1.delta)
        }
    }
}

public enum CanvasRotationSnapper {
    public static func snap(_ degrees: Double, step: Double = 45, threshold: Double = 4) -> Double {
        let target = (degrees / step).rounded() * step
        return abs(degrees - target) <= threshold ? target : degrees
    }
}

public struct RasterSettings: Codable, Equatable, Sendable {
    public static let minimumDPI = 1.0
    public static let maximumDPI = 1270.0
    public static let defaultDPI = 500.0

    public var laser: Laser
    public var widthMM: Double
    public var heightMM: Double
    public var placement: PrintPlacement
    public var dpi: Double {
        didSet { dpi = Self.clampedDPI(dpi) }
    }
    public var speedMMPerSecond: Double
    public var minPowerPercent: Double
    public var maxPowerPercent: Double
    public var dropPowerThresholdPercent: Double
    public var lineSpacingMM: Double
    public var scanDirection: ScanDirection

    public init(
        laser: Laser = .blue,
        widthMM: Double = 40,
        heightMM: Double = 40,
        placement: PrintPlacement = PrintPlacement(),
        dpi: Double = 500,
        speedMMPerSecond: Double = 200,
        minPowerPercent: Double = 0,
        maxPowerPercent: Double = 100,
        dropPowerThresholdPercent: Double = 1,
        lineSpacingMM: Double = 25.4 / 500,
        scanDirection: ScanDirection = .bidirectional
    ) {
        self.laser = laser
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.placement = placement
        self.dpi = Self.clampedDPI(dpi)
        self.speedMMPerSecond = speedMMPerSecond
        self.minPowerPercent = minPowerPercent
        self.maxPowerPercent = maxPowerPercent
        self.dropPowerThresholdPercent = dropPowerThresholdPercent
        self.lineSpacingMM = lineSpacingMM
        self.scanDirection = scanDirection
    }

    private enum CodingKeys: String, CodingKey {
        case laser
        case widthMM
        case heightMM
        case placement
        case dpi
        case speedMMPerSecond
        case minPowerPercent
        case maxPowerPercent
        case dropPowerThresholdPercent
        case lineSpacingMM
        case scanDirection
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        laser = try values.decodeIfPresent(Laser.self, forKey: .laser) ?? .blue
        widthMM = try values.decodeIfPresent(Double.self, forKey: .widthMM) ?? 40
        heightMM = try values.decodeIfPresent(Double.self, forKey: .heightMM) ?? 40
        placement = try values.decodeIfPresent(PrintPlacement.self, forKey: .placement) ?? PrintPlacement(widthMM: widthMM, heightMM: heightMM)
        dpi = Self.clampedDPI(try values.decodeIfPresent(Double.self, forKey: .dpi) ?? Self.defaultDPI)
        speedMMPerSecond = try values.decodeIfPresent(Double.self, forKey: .speedMMPerSecond) ?? 200
        minPowerPercent = try values.decodeIfPresent(Double.self, forKey: .minPowerPercent) ?? 0
        maxPowerPercent = try values.decodeIfPresent(Double.self, forKey: .maxPowerPercent) ?? 100
        dropPowerThresholdPercent = try values.decodeIfPresent(Double.self, forKey: .dropPowerThresholdPercent) ?? 1
        lineSpacingMM = try values.decodeIfPresent(Double.self, forKey: .lineSpacingMM) ?? (25.4 / dpi)
        scanDirection = try values.decodeIfPresent(ScanDirection.self, forKey: .scanDirection) ?? .bidirectional
    }

    public var dotDurationMicroseconds: Double {
        get { Self.dotDurationMicroseconds(speedMMPerSecond: speedMMPerSecond, dpi: dpi) }
        set { speedMMPerSecond = Self.speedMMPerSecond(dotDurationMicroseconds: newValue, dpi: dpi) }
    }

    public static func dotDurationMicroseconds(speedMMPerSecond: Double, dpi: Double) -> Double {
        (25.4 / clampedDPI(dpi)) / max(0.001, speedMMPerSecond) * 1_000_000
    }

    public static func speedMMPerSecond(dotDurationMicroseconds: Double, dpi: Double) -> Double {
        (25.4 / clampedDPI(dpi)) / max(10, dotDurationMicroseconds) * 1_000_000
    }

    public static func clampedDPI(_ dpi: Double) -> Double {
        guard dpi.isFinite else { return defaultDPI }
        return min(maximumDPI, max(minimumDPI, dpi))
    }

    public var dropPowerThreshold: Int {
        max(0, min(1000, Int((dropPowerThresholdPercent * 10).rounded())))
    }
}

public struct VectorSettings: Codable, Equatable, Sendable {
    public var laser: Laser
    public var placement: PrintPlacement
    public var speedMMPerSecond: Double
    public var powerPercent: Double

    public init(laser: Laser = .blue, placement: PrintPlacement = PrintPlacement(), speedMMPerSecond: Double = 20, powerPercent: Double = 10) {
        self.laser = laser
        self.placement = placement
        self.speedMMPerSecond = speedMMPerSecond
        self.powerPercent = powerPercent
    }
}

public enum LaserTextAlignment: String, Codable, CaseIterable, Sendable {
    case left
    case center
    case right
}

public struct TextSettings: Codable, Equatable, Sendable {
    public var text: String
    public var fontFamily: String
    public var fontSubfamily: String?
    public var fontSource: String?
    public var fontSize: Double
    public var letterSpacing: Double
    public var leading: Double
    public var alignment: LaserTextAlignment
    public var curveX: Double
    public var curveY: Double

    public init(text: String = "Text", fontFamily: String = "Helvetica", fontSubfamily: String? = nil, fontSource: String? = nil, fontSize: Double = 18, letterSpacing: Double = 0, leading: Double = 0, alignment: LaserTextAlignment = .center, curveX: Double = 0, curveY: Double = 0) {
        self.text = text
        self.fontFamily = fontFamily
        self.fontSubfamily = fontSubfamily
        self.fontSource = fontSource
        self.fontSize = fontSize
        self.letterSpacing = letterSpacing
        self.leading = leading
        self.alignment = alignment
        self.curveX = curveX
        self.curveY = curveY
    }
}

public struct EditableVectorNode: Codable, Equatable, Sendable {
    public var point: Point
    public var tangent: Point?

    public init(point: Point, tangent: Point? = nil) {
        self.point = point
        self.tangent = tangent
    }
}

public struct EditableVectorDrawing: Codable, Equatable, Sendable {
    public var rawSegments: [[Point]]
    public var smoothness: Double
    public var accuracy: Double
    public var nodes: [[EditableVectorNode]]

    public init(rawSegments: [[Point]] = [], smoothness: Double = 0, accuracy: Double = 0, nodes: [[EditableVectorNode]] = []) {
        self.rawSegments = rawSegments
        self.smoothness = smoothness
        self.accuracy = accuracy
        self.nodes = nodes
    }

    private enum CodingKeys: String, CodingKey {
        case rawSegments
        case smoothness
        case accuracy
        case nodes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rawSegments = try values.decodeIfPresent([[Point]].self, forKey: .rawSegments) ?? []
        smoothness = try values.decodeIfPresent(Double.self, forKey: .smoothness) ?? 0
        accuracy = try values.decodeIfPresent(Double.self, forKey: .accuracy) ?? 0
        nodes = try values.decodeIfPresent([[EditableVectorNode]].self, forKey: .nodes) ?? []
    }
}

public struct ProjectPhoto: Identifiable, Codable, Equatable, Sendable {
    public static let maximumPasses = 20

    public var id: UUID
    public var name: String
    public var mode: ProjectMode
    public var assetID: UUID?
    public var legacySourceImagePath: String?
    public var settingsName: String
    public var settings: RasterSettings
    public var vectorSettings: VectorSettings?
    public var vectorPaths: [LaserPath]
    public var vectorDrawing: EditableVectorDrawing?
    public var textSettings: TextSettings?
    public var isEnabled: Bool
    public var passes: Int

    public var printPlacement: PrintPlacement {
        get { mode == .vector || mode == .text ? (vectorSettings?.placement ?? settings.placement) : settings.placement }
        set {
            settings.placement = newValue
            if mode == .vector || mode == .text {
                var vector = vectorSettings ?? VectorSettings()
                vector.placement = newValue
                vectorSettings = vector
            }
        }
    }

    public var resolvedVectorSettings: VectorSettings {
        var vector = vectorSettings ?? VectorSettings()
        vector.placement = printPlacement
        return vector
    }

    public var resolvedTextSettings: TextSettings {
        textSettings ?? TextSettings(text: name)
    }

    public init(id: UUID = UUID(), name: String = "Photo", mode: ProjectMode = .raster, assetID: UUID? = nil, settingsName: String = "Custom", settings: RasterSettings = RasterSettings(), vectorSettings: VectorSettings? = nil, vectorPaths: [LaserPath] = [], vectorDrawing: EditableVectorDrawing? = nil, textSettings: TextSettings? = nil, isEnabled: Bool = true, passes: Int = 1) {
        self.id = id
        self.name = name
        self.mode = mode
        self.assetID = assetID
        self.legacySourceImagePath = nil
        self.settingsName = settingsName
        self.settings = settings
        self.vectorSettings = vectorSettings
        self.vectorPaths = vectorPaths
        self.vectorDrawing = vectorDrawing
        self.textSettings = textSettings
        self.isEnabled = isEnabled
        self.passes = passes
    }

    public init(id: UUID = UUID(), name: String = "Photo", mode: ProjectMode = .raster, sourceImagePath: String, settingsName: String = "Custom", settings: RasterSettings = RasterSettings(), vectorSettings: VectorSettings? = nil, vectorPaths: [LaserPath] = [], vectorDrawing: EditableVectorDrawing? = nil, textSettings: TextSettings? = nil, isEnabled: Bool = true, passes: Int = 1) {
        self.id = id
        self.name = name
        self.mode = mode
        self.assetID = nil
        self.legacySourceImagePath = sourceImagePath
        self.settingsName = settingsName
        self.settings = settings
        self.vectorSettings = vectorSettings
        self.vectorPaths = vectorPaths
        self.vectorDrawing = vectorDrawing
        self.textSettings = textSettings
        self.isEnabled = isEnabled
        self.passes = passes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case mode
        case assetID
        case sourceImagePath
        case settingsName
        case settings
        case vectorSettings
        case vectorPaths
        case vectorDrawing
        case textSettings
        case isEnabled
        case passes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Photo"
        mode = try values.decodeIfPresent(ProjectMode.self, forKey: .mode) ?? .raster
        assetID = try values.decodeIfPresent(UUID.self, forKey: .assetID)
        legacySourceImagePath = try values.decodeIfPresent(String.self, forKey: .sourceImagePath)
        settingsName = try values.decodeIfPresent(String.self, forKey: .settingsName) ?? "Custom"
        settings = try values.decodeIfPresent(RasterSettings.self, forKey: .settings) ?? RasterSettings()
        vectorSettings = try values.decodeIfPresent(VectorSettings.self, forKey: .vectorSettings)
        vectorPaths = try values.decodeIfPresent([LaserPath].self, forKey: .vectorPaths) ?? []
        vectorDrawing = try values.decodeIfPresent(EditableVectorDrawing.self, forKey: .vectorDrawing)
        textSettings = try values.decodeIfPresent(TextSettings.self, forKey: .textSettings)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        passes = try values.decodeIfPresent(Int.self, forKey: .passes) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(mode, forKey: .mode)
        try values.encodeIfPresent(assetID, forKey: .assetID)
        try values.encodeIfPresent(legacySourceImagePath, forKey: .sourceImagePath)
        try values.encode(settingsName, forKey: .settingsName)
        try values.encode(settings, forKey: .settings)
        try values.encodeIfPresent(vectorSettings, forKey: .vectorSettings)
        if !vectorPaths.isEmpty {
            try values.encode(vectorPaths, forKey: .vectorPaths)
        }
        try values.encodeIfPresent(vectorDrawing, forKey: .vectorDrawing)
        try values.encodeIfPresent(textSettings, forKey: .textSettings)
        if !isEnabled {
            try values.encode(isEnabled, forKey: .isEnabled)
        }
        if passes != 1 {
            try values.encode(passes, forKey: .passes)
        }
    }
}

public struct StoredProjectSnapshot: Codable, Equatable {
    public var name: String
    public var photos: [ProjectPhoto]
    public var gcodeMode: RasterGCodeMode
    public var frameMode: FrameMode
    public var frameSpeedMMPerSecond: Double
    public var libraryAssets: [LibraryAsset]

    public init(name: String, photos: [ProjectPhoto], gcodeMode: RasterGCodeMode = .asset, frameMode: FrameMode = .outline, frameSpeedMMPerSecond: Double = StoredProject.defaultFrameSpeedMMPerSecond, libraryAssets: [LibraryAsset] = []) {
        self.name = name
        self.photos = photos
        self.gcodeMode = gcodeMode
        self.frameMode = frameMode
        self.frameSpeedMMPerSecond = frameSpeedMMPerSecond
        self.libraryAssets = libraryAssets
    }

    public init(project: StoredProject, libraryAssets: [LibraryAsset] = []) {
        self.init(name: project.name, photos: project.photos, gcodeMode: project.gcodeMode, frameMode: project.frameMode, frameSpeedMMPerSecond: project.frameSpeedMMPerSecond, libraryAssets: libraryAssets)
    }

    public func restore(on project: inout StoredProject) {
        project.name = name
        project.photos = photos
        project.gcodeMode = gcodeMode
        project.frameMode = frameMode
        project.frameSpeedMMPerSecond = frameSpeedMMPerSecond
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case photos
        case gcodeMode
        case mode
        case sourceImagePath
        case settings
        case frameMode
        case frameSpeedMMPerSecond
        case libraryAssets
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        if let photos = try values.decodeIfPresent([ProjectPhoto].self, forKey: .photos) {
            self.photos = photos
        } else {
            let mode = try values.decode(ProjectMode.self, forKey: .mode)
            let sourceImagePath = try values.decode(String.self, forKey: .sourceImagePath)
            let settings = try values.decode(RasterSettings.self, forKey: .settings)
            photos = [ProjectPhoto(name: name, mode: mode, sourceImagePath: sourceImagePath, settings: settings)]
        }
        gcodeMode = try values.decodeIfPresent(RasterGCodeMode.self, forKey: .gcodeMode) ?? .asset
        frameMode = try values.decodeIfPresent(FrameMode.self, forKey: .frameMode) ?? .outline
        frameSpeedMMPerSecond = try values.decodeIfPresent(Double.self, forKey: .frameSpeedMMPerSecond) ?? StoredProject.defaultFrameSpeedMMPerSecond
        libraryAssets = try values.decodeIfPresent([LibraryAsset].self, forKey: .libraryAssets) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(photos, forKey: .photos)
        try values.encode(gcodeMode, forKey: .gcodeMode)
        try values.encode(frameMode, forKey: .frameMode)
        try values.encode(frameSpeedMMPerSecond, forKey: .frameSpeedMMPerSecond)
        try values.encode(libraryAssets, forKey: .libraryAssets)
    }
}

public struct StoredProject: Identifiable, Codable, Equatable {
    public static let defaultFrameSpeedMMPerSecond = 200.0

    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var photos: [ProjectPhoto]
    public var gcodeMode: RasterGCodeMode
    public var frameMode: FrameMode
    public var frameSpeedMMPerSecond: Double
    public var undoHistory: [StoredProjectSnapshot]
    public var redoHistory: [StoredProjectSnapshot]
    public var importFingerprint: String?

    public var snapshot: StoredProjectSnapshot {
        StoredProjectSnapshot(project: self)
    }

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), updatedAt: Date = Date(), photos: [ProjectPhoto] = [], gcodeMode: RasterGCodeMode = .asset, frameMode: FrameMode = .outline, frameSpeedMMPerSecond: Double = StoredProject.defaultFrameSpeedMMPerSecond, undoHistory: [StoredProjectSnapshot] = [], redoHistory: [StoredProjectSnapshot] = [], importFingerprint: String? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.photos = photos
        self.gcodeMode = gcodeMode
        self.frameMode = frameMode
        self.frameSpeedMMPerSecond = frameSpeedMMPerSecond
        self.undoHistory = undoHistory
        self.redoHistory = redoHistory
        self.importFingerprint = importFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt
        case updatedAt
        case photos
        case gcodeMode
        case mode
        case sourceImagePath
        case settings
        case frameMode
        case frameSpeedMMPerSecond
        case undoHistory
        case redoHistory
        case importFingerprint
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        if let photos = try values.decodeIfPresent([ProjectPhoto].self, forKey: .photos) {
            self.photos = photos
        } else {
            let mode = try values.decode(ProjectMode.self, forKey: .mode)
            let sourceImagePath = try values.decode(String.self, forKey: .sourceImagePath)
            let settings = try values.decode(RasterSettings.self, forKey: .settings)
            self.photos = [ProjectPhoto(name: name, mode: mode, sourceImagePath: sourceImagePath, settings: settings)]
        }
        gcodeMode = try values.decodeIfPresent(RasterGCodeMode.self, forKey: .gcodeMode) ?? .asset
        frameMode = try values.decodeIfPresent(FrameMode.self, forKey: .frameMode) ?? .outline
        frameSpeedMMPerSecond = try values.decodeIfPresent(Double.self, forKey: .frameSpeedMMPerSecond) ?? Self.defaultFrameSpeedMMPerSecond
        undoHistory = try values.decodeIfPresent([StoredProjectSnapshot].self, forKey: .undoHistory) ?? []
        redoHistory = try values.decodeIfPresent([StoredProjectSnapshot].self, forKey: .redoHistory) ?? []
        importFingerprint = try values.decodeIfPresent(String.self, forKey: .importFingerprint)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(photos, forKey: .photos)
        try values.encode(gcodeMode, forKey: .gcodeMode)
        try values.encode(frameMode, forKey: .frameMode)
        try values.encode(frameSpeedMMPerSecond, forKey: .frameSpeedMMPerSecond)
        try values.encode(undoHistory, forKey: .undoHistory)
        try values.encode(redoHistory, forKey: .redoHistory)
        try values.encodeIfPresent(importFingerprint, forKey: .importFingerprint)
    }
}

public struct PrintRecord: Identifiable, Codable, Equatable {
    public var id: UUID
    public var projectID: UUID
    public var projectName: String
    public var printedAt: Date
    public var photoCount: Int
    public var generatedLines: Int
    public var generatedBytes: Int

    public init(id: UUID = UUID(), projectID: UUID, projectName: String, printedAt: Date = Date(), photoCount: Int, generatedLines: Int, generatedBytes: Int) {
        self.id = id
        self.projectID = projectID
        self.projectName = projectName
        self.printedAt = printedAt
        self.photoCount = photoCount
        self.generatedLines = generatedLines
        self.generatedBytes = generatedBytes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case projectID
        case projectName
        case printedAt
        case photoCount
        case generatedLines
        case generatedBytes
        case legacyProjectID = "jobID"
        case legacyProjectName = "jobName"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        projectID = try values.decodeIfPresent(UUID.self, forKey: .projectID) ?? values.decode(UUID.self, forKey: .legacyProjectID)
        projectName = try values.decodeIfPresent(String.self, forKey: .projectName) ?? values.decode(String.self, forKey: .legacyProjectName)
        printedAt = try values.decode(Date.self, forKey: .printedAt)
        photoCount = try values.decodeIfPresent(Int.self, forKey: .photoCount) ?? 1
        generatedLines = try values.decode(Int.self, forKey: .generatedLines)
        generatedBytes = try values.decode(Int.self, forKey: .generatedBytes)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(projectID, forKey: .projectID)
        try values.encode(projectName, forKey: .projectName)
        try values.encode(printedAt, forKey: .printedAt)
        try values.encode(photoCount, forKey: .photoCount)
        try values.encode(generatedLines, forKey: .generatedLines)
        try values.encode(generatedBytes, forKey: .generatedBytes)
    }
}

public struct PhotoMutation: Codable, Equatable, Sendable {
    public var parentAssetID: UUID?
    public var editKind: String
    public var values: [String: Double]
    public var projectID: UUID?
    public var photoID: UUID?
    public var createdAt: Date

    public init(parentAssetID: UUID?, editKind: String, values: [String: Double] = [:], projectID: UUID? = nil, photoID: UUID? = nil, createdAt: Date = Date()) {
        self.parentAssetID = parentAssetID
        self.editKind = editKind
        self.values = values
        self.projectID = projectID
        self.photoID = photoID
        self.createdAt = createdAt
    }
}

public struct LibraryAssetState: Codable, Equatable, Sendable {
    public var kind: LibraryAssetKind?
    public var sha256: String
    public var originalName: String?
    public var imagePath: String
    public var vectorPaths: [LaserPath]?
    public var vectorSettings: VectorSettings?
    public var vectorDrawing: EditableVectorDrawing?
    public var textSettings: TextSettings?
    public var mutation: PhotoMutation?

    public init(kind: LibraryAssetKind? = nil, sha256: String, originalName: String? = nil, imagePath: String, vectorPaths: [LaserPath]? = nil, vectorSettings: VectorSettings? = nil, vectorDrawing: EditableVectorDrawing? = nil, textSettings: TextSettings? = nil, mutation: PhotoMutation? = nil) {
        self.kind = kind
        self.sha256 = sha256
        self.originalName = originalName
        self.imagePath = imagePath
        self.vectorPaths = vectorPaths
        self.vectorSettings = vectorSettings
        self.vectorDrawing = vectorDrawing
        self.textSettings = textSettings
        self.mutation = mutation
    }
}

public enum LibraryAssetKind: String, Codable, Sendable {
    case raster
    case vector
    case text
}

public struct LibraryAsset: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: LibraryAssetKind
    public var sha256: String
    public var originalName: String
    public var imagePath: String
    public var vectorPaths: [LaserPath]
    public var vectorSettings: VectorSettings?
    public var vectorDrawing: EditableVectorDrawing?
    public var textSettings: TextSettings?
    public var createdAt: Date
    public var mutation: PhotoMutation?
    public var undoHistory: [LibraryAssetState]
    public var redoHistory: [LibraryAssetState]

    public var state: LibraryAssetState {
        LibraryAssetState(kind: kind, sha256: sha256, originalName: originalName, imagePath: imagePath, vectorPaths: vectorPaths, vectorSettings: vectorSettings, vectorDrawing: vectorDrawing, textSettings: textSettings, mutation: mutation)
    }

    public init(id: UUID = UUID(), kind: LibraryAssetKind = .raster, sha256: String, originalName: String, imagePath: String = "", vectorPaths: [LaserPath] = [], vectorSettings: VectorSettings? = nil, vectorDrawing: EditableVectorDrawing? = nil, textSettings: TextSettings? = nil, createdAt: Date = Date(), mutation: PhotoMutation? = nil, undoHistory: [LibraryAssetState] = [], redoHistory: [LibraryAssetState] = []) {
        self.id = id
        self.kind = kind
        self.sha256 = sha256
        self.originalName = originalName
        self.imagePath = imagePath
        self.vectorPaths = vectorPaths
        self.vectorSettings = vectorSettings
        self.vectorDrawing = vectorDrawing
        self.textSettings = textSettings
        self.createdAt = createdAt
        self.mutation = mutation
        self.undoHistory = undoHistory
        self.redoHistory = redoHistory
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case sha256
        case originalName
        case imagePath
        case vectorPaths
        case vectorSettings
        case vectorDrawing
        case textSettings
        case createdAt
        case mutation
        case undoHistory
        case redoHistory
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try values.decodeIfPresent(LibraryAssetKind.self, forKey: .kind) ?? .raster
        sha256 = try values.decode(String.self, forKey: .sha256)
        originalName = try values.decode(String.self, forKey: .originalName)
        imagePath = try values.decodeIfPresent(String.self, forKey: .imagePath) ?? ""
        vectorPaths = try values.decodeIfPresent([LaserPath].self, forKey: .vectorPaths) ?? []
        vectorSettings = try values.decodeIfPresent(VectorSettings.self, forKey: .vectorSettings)
        vectorDrawing = try values.decodeIfPresent(EditableVectorDrawing.self, forKey: .vectorDrawing)
        textSettings = try values.decodeIfPresent(TextSettings.self, forKey: .textSettings)
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        mutation = try values.decodeIfPresent(PhotoMutation.self, forKey: .mutation)
        undoHistory = try values.decodeIfPresent([LibraryAssetState].self, forKey: .undoHistory) ?? []
        redoHistory = try values.decodeIfPresent([LibraryAssetState].self, forKey: .redoHistory) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(kind, forKey: .kind)
        try values.encode(sha256, forKey: .sha256)
        try values.encode(originalName, forKey: .originalName)
        if !imagePath.isEmpty {
            try values.encode(imagePath, forKey: .imagePath)
        }
        if !vectorPaths.isEmpty {
            try values.encode(vectorPaths, forKey: .vectorPaths)
        }
        try values.encodeIfPresent(vectorSettings, forKey: .vectorSettings)
        try values.encodeIfPresent(vectorDrawing, forKey: .vectorDrawing)
        try values.encodeIfPresent(textSettings, forKey: .textSettings)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encodeIfPresent(mutation, forKey: .mutation)
        try values.encode(undoHistory, forKey: .undoHistory)
        try values.encode(redoHistory, forKey: .redoHistory)
    }
}

public struct SettingPreset: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var settings: RasterSettings
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, settings: RasterSettings, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.settings = settings
        self.updatedAt = updatedAt
    }
}

public enum DebugLogLevel: String, Codable {
    case info
    case warning
    case error
}

public struct DebugLogEntry: Identifiable, Codable, Equatable {
    public var id: UUID
    public var date: Date
    public var level: DebugLogLevel
    public var message: String

    public init(id: UUID = UUID(), date: Date = Date(), level: DebugLogLevel = .info, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
    }
}

public struct AppStoreData: Codable, Equatable {
    public var projects: [StoredProject]
    public var libraryAssets: [LibraryAsset]
    public var settingPresets: [SettingPreset]
    public var lastPresetID: UUID?
    public var lastVectorSettings: VectorSettings?
    public var lastFrameSpeedMMPerSecond: Double?
    public var history: [PrintRecord]
    public var debugLog: [DebugLogEntry]
    public var recentMachineHosts: [String]

    public init(projects: [StoredProject] = [], libraryAssets: [LibraryAsset] = [], settingPresets: [SettingPreset] = [], lastPresetID: UUID? = nil, lastVectorSettings: VectorSettings? = nil, lastFrameSpeedMMPerSecond: Double? = nil, history: [PrintRecord] = [], debugLog: [DebugLogEntry] = [], recentMachineHosts: [String] = []) {
        self.projects = projects
        self.libraryAssets = libraryAssets
        self.settingPresets = settingPresets
        self.lastPresetID = lastPresetID
        self.lastVectorSettings = lastVectorSettings
        self.lastFrameSpeedMMPerSecond = lastFrameSpeedMMPerSecond
        self.history = history
        self.debugLog = debugLog
        self.recentMachineHosts = recentMachineHosts
    }

    private enum CodingKeys: String, CodingKey {
        case projects
        case legacyProjects = "jobs"
        case libraryAssets
        case settingPresets
        case lastPresetID
        case lastVectorSettings
        case lastFrameSpeedMMPerSecond
        case history
        case debugLog
        case recentMachineHosts
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projects = try values.decodeIfPresent([StoredProject].self, forKey: .projects) ?? values.decodeIfPresent([StoredProject].self, forKey: .legacyProjects) ?? []
        libraryAssets = try values.decodeIfPresent([LibraryAsset].self, forKey: .libraryAssets) ?? []
        settingPresets = try values.decodeIfPresent([SettingPreset].self, forKey: .settingPresets) ?? []
        lastPresetID = try values.decodeIfPresent(UUID.self, forKey: .lastPresetID)
        lastVectorSettings = try values.decodeIfPresent(VectorSettings.self, forKey: .lastVectorSettings)
        lastFrameSpeedMMPerSecond = try values.decodeIfPresent(Double.self, forKey: .lastFrameSpeedMMPerSecond)
        history = try values.decodeIfPresent([PrintRecord].self, forKey: .history) ?? []
        debugLog = try values.decodeIfPresent([DebugLogEntry].self, forKey: .debugLog) ?? []
        recentMachineHosts = try values.decodeIfPresent([String].self, forKey: .recentMachineHosts) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(projects, forKey: .projects)
        try values.encode(libraryAssets, forKey: .libraryAssets)
        try values.encode(settingPresets, forKey: .settingPresets)
        try values.encodeIfPresent(lastPresetID, forKey: .lastPresetID)
        try values.encodeIfPresent(lastVectorSettings, forKey: .lastVectorSettings)
        try values.encodeIfPresent(lastFrameSpeedMMPerSecond, forKey: .lastFrameSpeedMMPerSecond)
        try values.encode(history, forKey: .history)
        try values.encode(debugLog, forKey: .debugLog)
        try values.encode(recentMachineHosts, forKey: .recentMachineHosts)
    }
}
