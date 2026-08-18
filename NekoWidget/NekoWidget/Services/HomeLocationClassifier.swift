import Foundation

/// One short-lived input to the on-device home-cluster calculation. Callers
/// discard these coordinates as soon as `classify(_:)` returns; only the
/// privacy-minimal outing flag is persisted on an `AssetRecord`.
struct AlbumLocationSample: Equatable, Sendable {
    var localIdentifier: String
    var latitude: Double?
    var longitude: Double?
}

/// Finds the densest stable photo-location cluster without retaining GPS data.
///
/// A three-dimensional spatial hash avoids retaining an all-pairs neighbour
/// matrix, and gives dense home libraries a linear-memory fast path. The 3D
/// Earth-centred representation also behaves correctly around the ±180°
/// meridian and at high latitudes.
enum HomeLocationClassifier {
    static let homeRadiusMeters = 200.0
    static let minimumHomePhotoCount = 5

    /// The returned dictionary includes every non-empty identifier. Its value
    /// is `nil` when the asset has no usable GPS coordinate or no stable home
    /// cluster exists, `false` for the home cluster, and `true` everywhere else.
    static func classify(
        _ samples: [AlbumLocationSample]
    ) -> [String: Bool?] {
        classify(
            samples,
            radiusMeters: homeRadiusMeters,
            minimumClusterSize: minimumHomePhotoCount
        )
    }

    /// Parameters are internal so the deterministic verifier can cover the
    /// clustering boundary without exposing product tuning through the UI.
    static func classify(
        _ samples: [AlbumLocationSample],
        radiusMeters: Double,
        minimumClusterSize: Int
    ) -> [String: Bool?] {
        let uniqueSamples = uniqueSamplesByIdentifier(samples)
        var output = Dictionary(uniqueKeysWithValues: uniqueSamples.map {
            ($0.localIdentifier, Optional<Bool>.none)
        })
        guard radiusMeters > 0, minimumClusterSize > 0 else { return output }

        let points = uniqueSamples.compactMap(Point.init(sample:))
        guard points.count >= minimumClusterSize else { return output }

        let chordRadius = chordLength(forArcMeters: radiusMeters)
        let squaredRadius = chordRadius * chordRadius
        // A cell diagonal is exactly one search radius, so every point in one
        // cell is a neighbour. Dense home libraries can therefore be handled
        // without materializing an O(n²) neighbourhood matrix.
        let cellSize = chordRadius / sqrt(3)
        let pointCells = points.map { GridKey(point: $0, cellSize: cellSize) }
        var spatialHash: [GridKey: [Int]] = [:]
        for index in points.indices {
            spatialHash[pointCells[index], default: []].append(index)
        }

        var isCore = Array(repeating: false, count: points.count)
        for index in points.indices {
            let cell = pointCells[index]
            if (spatialHash[cell]?.count ?? 0) >= minimumClusterSize {
                isCore[index] = true
                continue
            }

            var neighbourCount = 0
            search: for xOffset in -2...2 {
                for yOffset in -2...2 {
                    for zOffset in -2...2 {
                        let nearby = GridKey(
                            x: cell.x + Int64(xOffset),
                            y: cell.y + Int64(yOffset),
                            z: cell.z + Int64(zOffset)
                        )
                        for candidate in spatialHash[nearby] ?? []
                            where squaredDistance(points[index], points[candidate])
                                <= squaredRadius {
                            neighbourCount += 1
                            if neighbourCount >= minimumClusterSize {
                                isCore[index] = true
                                break search
                            }
                        }
                    }
                }
            }
        }
        guard isCore.contains(true) else { return output }

        var coreIndicesByCell: [GridKey: [Int]] = [:]
        for index in points.indices where isCore[index] {
            coreIndicesByCell[pointCells[index], default: []].append(index)
        }

        var union = DisjointSet(count: points.count)
        // Core points in one cell are guaranteed to be within the radius.
        for indices in coreIndicesByCell.values {
            guard let first = indices.first else { continue }
            for index in indices.dropFirst() { union.connect(first, index) }
        }

        // Only one exact core-to-core edge is needed to join two internally
        // connected cells. This avoids enumerating every edge in a dense home
        // cluster while preserving DBSCAN's core-point connectivity.
        let coreCells = coreIndicesByCell.keys.sorted()
        let orderByCell = Dictionary(uniqueKeysWithValues: coreCells.enumerated().map {
            ($0.element, $0.offset)
        })
        for (cellOrder, cell) in coreCells.enumerated() {
            guard let left = coreIndicesByCell[cell], let leftFirst = left.first else {
                continue
            }
            for xOffset in -2...2 {
                for yOffset in -2...2 {
                    for zOffset in -2...2 {
                        let nearby = GridKey(
                            x: cell.x + Int64(xOffset),
                            y: cell.y + Int64(yOffset),
                            z: cell.z + Int64(zOffset)
                        )
                        guard let nearbyOrder = orderByCell[nearby],
                              nearbyOrder > cellOrder,
                              let right = coreIndicesByCell[nearby],
                              let rightFirst = right.first,
                              cellSetsHaveNeighbouringPoints(
                                  left,
                                  right,
                                  points: points,
                                  squaredRadius: squaredRadius
                              ) else {
                            continue
                        }
                        union.connect(leftFirst, rightFirst)
                    }
                }
            }
        }

        var membersByRoot: [Int: Set<Int>] = [:]
        var coreRootByIndex: [Int: Int] = [:]
        for index in points.indices where isCore[index] {
            let root = union.root(of: index)
            coreRootByIndex[index] = root
            membersByRoot[root, default: []].insert(index)
        }

        // DBSCAN border points belong to the nearest adjacent core cluster.
        // Distance and then a location-derived cluster key make this stable
        // regardless of PhotoKit enumeration order.
        let stableKeyByRoot = Dictionary(uniqueKeysWithValues: membersByRoot.map {
            ($0.key, stableClusterKey(members: $0.value, points: points))
        })
        for index in points.indices where !isCore[index] {
            let cell = pointCells[index]
            var selectedRoot: Int?
            var selectedDistance = Double.greatestFiniteMagnitude
            for xOffset in -2...2 {
                for yOffset in -2...2 {
                    for zOffset in -2...2 {
                        let nearby = GridKey(
                            x: cell.x + Int64(xOffset),
                            y: cell.y + Int64(yOffset),
                            z: cell.z + Int64(zOffset)
                        )
                        for candidate in coreIndicesByCell[nearby] ?? [] {
                            let candidateDistance = squaredDistance(
                                points[index],
                                points[candidate]
                            )
                            guard candidateDistance <= squaredRadius,
                                  let candidateRoot = coreRootByIndex[candidate] else {
                                continue
                            }
                            let winsDistance = candidateDistance < selectedDistance
                            let winsTie = candidateDistance == selectedDistance
                                && (stableKeyByRoot[candidateRoot] ?? .maximum)
                                    < (selectedRoot.flatMap { stableKeyByRoot[$0] }
                                        ?? .maximum)
                            if winsDistance || winsTie {
                                selectedRoot = candidateRoot
                                selectedDistance = candidateDistance
                            }
                        }
                    }
                }
            }
            if let selectedRoot {
                membersByRoot[selectedRoot, default: []].insert(index)
            }
        }

        let orderedClusters = membersByRoot.sorted { lhs, rhs in
            if lhs.value.count != rhs.value.count {
                return lhs.value.count > rhs.value.count
            }
            return (stableKeyByRoot[lhs.key] ?? .maximum)
                < (stableKeyByRoot[rhs.key] ?? .maximum)
        }
        guard let home = orderedClusters.first else { return output }

        for index in points.indices {
            output[points[index].localIdentifier] = home.value.contains(index) ? false : true
        }
        return output
    }

    private static func uniqueSamplesByIdentifier(
        _ samples: [AlbumLocationSample]
    ) -> [AlbumLocationSample] {
        var unique: [String: AlbumLocationSample] = [:]
        for sample in samples where !sample.localIdentifier.isEmpty {
            if unique[sample.localIdentifier] == nil {
                unique[sample.localIdentifier] = sample
            }
        }
        return unique.values.sorted {
            $0.localIdentifier < $1.localIdentifier
        }
    }

    private static func cellSetsHaveNeighbouringPoints(
        _ left: [Int],
        _ right: [Int],
        points: [Point],
        squaredRadius: Double
    ) -> Bool {
        guard let leftBounds = PointBounds(indices: left, points: points),
              let rightBounds = PointBounds(indices: right, points: points),
              leftBounds.minimumSquaredDistance(to: rightBounds) <= squaredRadius else {
            return false
        }
        if leftBounds.maximumSquaredDistance(to: rightBounds) <= squaredRadius {
            return true
        }
        for leftIndex in left {
            for rightIndex in right
                where squaredDistance(points[leftIndex], points[rightIndex])
                    <= squaredRadius {
                return true
            }
        }
        return false
    }

    private static func squaredDistance(_ lhs: Point, _ rhs: Point) -> Double {
        let x = lhs.x - rhs.x
        let y = lhs.y - rhs.y
        let z = lhs.z - rhs.z
        return x * x + y * y + z * z
    }

    private static func chordLength(forArcMeters meters: Double) -> Double {
        2 * Point.earthRadiusMeters * sin(meters / (2 * Point.earthRadiusMeters))
    }

    private static func stableClusterKey(
        members: Set<Int>,
        points: [Point]
    ) -> StableClusterKey {
        members.lazy.map { points[$0].stableKey }.min() ?? .maximum
    }
}

private struct Point {
    static let earthRadiusMeters = 6_371_008.8

    var localIdentifier: String
    var x: Double
    var y: Double
    var z: Double

    init?(sample: AlbumLocationSample) {
        guard let latitude = sample.latitude,
              let longitude = sample.longitude,
              latitude.isFinite,
              longitude.isFinite,
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else { return nil }
        let latitudeRadians = latitude * .pi / 180
        let longitudeRadians = longitude * .pi / 180
        let latitudeCosine = cos(latitudeRadians)
        localIdentifier = sample.localIdentifier
        x = Self.earthRadiusMeters * latitudeCosine * cos(longitudeRadians)
        y = Self.earthRadiusMeters * latitudeCosine * sin(longitudeRadians)
        z = Self.earthRadiusMeters * sin(latitudeRadians)
    }

    var stableKey: StableClusterKey {
        StableClusterKey(x: x, y: y, z: z, identifier: localIdentifier)
    }
}

private struct GridKey: Hashable, Comparable {
    var x: Int64
    var y: Int64
    var z: Int64

    init(x: Int64, y: Int64, z: Int64) {
        self.x = x
        self.y = y
        self.z = z
    }

    init(point: Point, cellSize: Double) {
        x = Int64(floor(point.x / cellSize))
        y = Int64(floor(point.y / cellSize))
        z = Int64(floor(point.z / cellSize))
    }

    static func < (lhs: GridKey, rhs: GridKey) -> Bool {
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        return lhs.z < rhs.z
    }
}

private struct PointBounds {
    var minimumX: Double
    var maximumX: Double
    var minimumY: Double
    var maximumY: Double
    var minimumZ: Double
    var maximumZ: Double

    init?(indices: [Int], points: [Point]) {
        guard let firstIndex = indices.first else { return nil }
        let first = points[firstIndex]
        minimumX = first.x
        maximumX = first.x
        minimumY = first.y
        maximumY = first.y
        minimumZ = first.z
        maximumZ = first.z
        for index in indices.dropFirst() {
            let point = points[index]
            minimumX = min(minimumX, point.x)
            maximumX = max(maximumX, point.x)
            minimumY = min(minimumY, point.y)
            maximumY = max(maximumY, point.y)
            minimumZ = min(minimumZ, point.z)
            maximumZ = max(maximumZ, point.z)
        }
    }

    func minimumSquaredDistance(to other: PointBounds) -> Double {
        squaredGap(minimumX, maximumX, other.minimumX, other.maximumX)
            + squaredGap(minimumY, maximumY, other.minimumY, other.maximumY)
            + squaredGap(minimumZ, maximumZ, other.minimumZ, other.maximumZ)
    }

    func maximumSquaredDistance(to other: PointBounds) -> Double {
        let x = max(abs(minimumX - other.maximumX), abs(maximumX - other.minimumX))
        let y = max(abs(minimumY - other.maximumY), abs(maximumY - other.minimumY))
        let z = max(abs(minimumZ - other.maximumZ), abs(maximumZ - other.minimumZ))
        return (x * x) + (y * y) + (z * z)
    }

    private func squaredGap(
        _ leftMinimum: Double,
        _ leftMaximum: Double,
        _ rightMinimum: Double,
        _ rightMaximum: Double
    ) -> Double {
        let gap: Double
        if leftMaximum < rightMinimum {
            gap = rightMinimum - leftMaximum
        } else if rightMaximum < leftMinimum {
            gap = leftMinimum - rightMaximum
        } else {
            gap = 0
        }
        return gap * gap
    }
}

private struct StableClusterKey: Comparable {
    var x: Double
    var y: Double
    var z: Double
    var identifier: String

    static let maximum = StableClusterKey(
        x: .greatestFiniteMagnitude,
        y: .greatestFiniteMagnitude,
        z: .greatestFiniteMagnitude,
        identifier: "~"
    )

    static func < (lhs: StableClusterKey, rhs: StableClusterKey) -> Bool {
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        if lhs.z != rhs.z { return lhs.z < rhs.z }
        return lhs.identifier < rhs.identifier
    }
}

private struct DisjointSet {
    private var parents: [Int]
    private var ranks: [UInt8]

    init(count: Int) {
        parents = Array(0..<count)
        ranks = Array(repeating: 0, count: count)
    }

    mutating func root(of value: Int) -> Int {
        let parent = parents[value]
        if parent != value {
            let resolved = root(of: parent)
            parents[value] = resolved
        }
        return parents[value]
    }

    mutating func connect(_ lhs: Int, _ rhs: Int) {
        let leftRoot = root(of: lhs)
        let rightRoot = root(of: rhs)
        guard leftRoot != rightRoot else { return }
        if ranks[leftRoot] < ranks[rightRoot] {
            parents[leftRoot] = rightRoot
        } else if ranks[leftRoot] > ranks[rightRoot] {
            parents[rightRoot] = leftRoot
        } else {
            parents[rightRoot] = leftRoot
            ranks[leftRoot] += 1
        }
    }
}
