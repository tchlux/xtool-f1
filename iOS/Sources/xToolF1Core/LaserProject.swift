import Foundation

public struct LaserProject: Codable, Sendable {
    public var name: String
    public var preview: Bool
    public var operations: [LaserOperation]

    public init(name: String, preview: Bool, operations: [LaserOperation]) {
        self.name = name
        self.preview = preview
        self.operations = operations
    }
}

public struct LaserOperation: Codable, Sendable {
    public var laser: Laser
    public var powerPercent: Double
    public var speedMMPerSecond: Double
    public var paths: [LaserPath]

    public init(laser: Laser, powerPercent: Double, speedMMPerSecond: Double, paths: [LaserPath]) {
        self.laser = laser
        self.powerPercent = powerPercent
        self.speedMMPerSecond = speedMMPerSecond
        self.paths = paths
    }
}

public enum Laser: String, Codable, Sendable {
    case blue
    case infrared
}

public struct LaserPath: Codable, Equatable, Sendable {
    public var closed: Bool
    public var points: [Point]

    public init(closed: Bool, points: [Point]) {
        self.closed = closed
        self.points = points
    }
}

public struct Point: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

extension Array where Element == LaserPath {
    func centerOutCutOrder(relativeTo center: Point, placement: PrintPlacement? = nil) -> [LaserPath] {
        let items = enumerated().compactMap { PathOrderItem(index: $0.offset, path: $0.element, placement: placement, center: center) }
        var parents = Array<Int?>(repeating: nil, count: items.count)
        for child in items.indices {
            parents[child] = items.indices
                .filter { parent in
                    parent != child
                        && items[parent].path.closed
                        && items[parent].bounds.contains(items[child].bounds)
                        && items[child].orderedPath.points.allSatisfy { items[parent].orderedPath.contains($0) }
                }
                .min { items[$0].bounds.area < items[$1].bounds.area }
        }

        var roots: [Int] = []
        var children = [[Int]](repeating: [], count: items.count)
        for index in items.indices {
            if let parent = parents[index] {
                children[parent].append(index)
            } else {
                roots.append(index)
            }
        }

        var output: [LaserPath] = []
        func emit(_ index: Int) {
            for child in children[index].sorted(by: { items[$0].comesBefore(items[$1]) }) {
                emit(child)
            }
            output.append(items[index].path)
        }
        for root in roots.sorted(by: { items[$0].comesBefore(items[$1]) }) {
            emit(root)
        }
        return output
    }

    var textCutOrder: [LaserPath] {
        let items = enumerated().compactMap { PathOrderItem(index: $0.offset, path: $0.element) }
        var parents = Array<Int?>(repeating: nil, count: items.count)
        for child in items.indices {
            parents[child] = items.indices
                .filter { parent in
                    parent != child
                        && items[parent].path.closed
                        && items[parent].bounds.contains(items[child].bounds)
                        && items[child].path.points.allSatisfy { items[parent].path.contains($0) }
                }
                .min { items[$0].bounds.area < items[$1].bounds.area }
        }

        var roots: [Int] = []
        var children = [[Int]](repeating: [], count: items.count)
        for index in items.indices {
            if let parent = parents[index] {
                children[parent].append(index)
            } else {
                roots.append(index)
            }
        }

        var output: [LaserPath] = []
        func emit(_ index: Int) {
            for child in children[index].sorted(by: { items[$0].textComesBefore(items[$1]) }) {
                emit(child)
            }
            output.append(items[index].path)
        }
        for root in roots.sorted(by: { items[$0].textComesBefore(items[$1]) }) {
            emit(root)
        }
        return output
    }
}

private extension LaserPath {
    func placed(in placement: PrintPlacement) -> LaserPath {
        LaserPath(closed: closed, points: points.map(placement.absolute))
    }

    var cutSize: Double {
        if closed, points.count > 2 {
            let area = abs(points.indices.reduce(0.0) { total, index in
                let next = points[(index + 1) % points.count]
                return total + points[index].x * next.y - next.x * points[index].y
            }) / 2
            if area > 0 { return area }
        }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(), let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return 0 }
        return (maxX - minX) * (maxY - minY)
    }

    var cutCenter: Point? {
        guard points.count > 1 else { return nil }
        var segments = Array(zip(points, points.dropFirst()))
        if closed {
            segments.append((points[points.count - 1], points[0]))
        }
        var total = 0.0
        var x = 0.0
        var y = 0.0
        for segment in segments {
            let length = hypot(segment.1.x - segment.0.x, segment.1.y - segment.0.y)
            total += length
            x += (segment.0.x + segment.1.x) / 2 * length
            y += (segment.0.y + segment.1.y) / 2 * length
        }
        guard total > 0.000001 else { return nil }
        return Point(x: x / total, y: y / total)
    }

    var pathBounds: PathBounds? {
        guard points.count > 1, let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(), let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        return PathBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    func contains(_ point: Point) -> Bool {
        guard closed, points.count > 2 else { return false }
        var inside = false
        var previous = points.count - 1
        for index in points.indices {
            let a = points[index]
            let b = points[previous]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            previous = index
        }
        return inside
    }
}

private struct PathOrderItem {
    var index: Int
    var path: LaserPath
    var orderedPath: LaserPath
    var bounds: PathBounds
    var distanceFromCenter: Double

    init?(index: Int, path: LaserPath, placement: PrintPlacement? = nil, center: Point = Point(x: 0.5, y: 0.5)) {
        let orderedPath = placement.map { path.placed(in: $0) } ?? path
        guard let bounds = orderedPath.pathBounds else { return nil }
        self.index = index
        self.path = path
        self.orderedPath = orderedPath
        self.bounds = bounds
        let cutCenter = orderedPath.cutCenter ?? bounds.center
        self.distanceFromCenter = hypot(cutCenter.x - center.x, cutCenter.y - center.y)
    }

    func comesBefore(_ other: PathOrderItem) -> Bool {
        if abs(distanceFromCenter - other.distanceFromCenter) > 0.000001 { return distanceFromCenter < other.distanceFromCenter }
        let left = orderedPath.cutSize
        let right = other.orderedPath.cutSize
        if abs(left - right) > 0.000001 { return left < right }
        return index < other.index
    }

    func textComesBefore(_ other: PathOrderItem) -> Bool {
        if bounds.verticallyOverlaps(other.bounds), abs(bounds.minX - other.bounds.minX) > 0.000001 {
            return bounds.minX < other.bounds.minX
        }
        if abs(bounds.minY - other.bounds.minY) > 0.000001 {
            return bounds.minY < other.bounds.minY
        }
        if abs(bounds.minX - other.bounds.minX) > 0.000001 {
            return bounds.minX < other.bounds.minX
        }
        return index < other.index
    }
}

private struct PathBounds {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double

    var area: Double { (maxX - minX) * (maxY - minY) }
    var center: Point { Point(x: (minX + maxX) / 2, y: (minY + maxY) / 2) }

    func contains(_ other: PathBounds) -> Bool {
        minX <= other.minX && minY <= other.minY && maxX >= other.maxX && maxY >= other.maxY && area > other.area + 0.000001
    }

    func verticallyOverlaps(_ other: PathBounds) -> Bool {
        minY <= other.maxY && maxY >= other.minY
    }
}
