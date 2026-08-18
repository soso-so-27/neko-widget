import Foundation

@main
enum VerifyAlbumLocation {
    static func main() throws {
        try verifiesMinimumClusterSize()
        try verifiesHomeAndOutingClassification()
        try verifiesStableOrderingAndTieBreak()
        try verifiesAntimeridianNeighbourhood()
        try verifiesRadiusBoundary()
        try verifiesTwoCellNeighbourReach()
        try verifiesSparseChainDoesNotBecomeHome()
        try verifiesDenseLibraryWithoutQuadraticStorage()
        try verifiesOptimizedClassifierAgainstReferenceDBSCAN()
        print("album location classification: ok")
    }

    private static func verifiesMinimumClusterSize() throws {
        let samples = (0..<4).map {
            sample("small-\($0)", latitude: 35, longitude: 139)
        }
        let result = HomeLocationClassifier.classify(samples)
        for sample in samples {
            try expect(value(in: result, for: sample.localIdentifier) == nil,
                       "a four-photo location must not become home")
        }
    }

    private static func verifiesHomeAndOutingClassification() throws {
        var samples = cluster(
            prefix: "home",
            latitude: 35.681236,
            longitude: 139.767125,
            count: 6
        )
        samples += cluster(
            prefix: "park",
            latitude: 35.6895,
            longitude: 139.6917,
            count: 5
        )
        samples.append(sample("away", latitude: 35.7101, longitude: 139.8107))
        samples.append(AlbumLocationSample(
            localIdentifier: "missing",
            latitude: nil,
            longitude: nil
        ))

        let result = HomeLocationClassifier.classify(samples)
        for index in 0..<6 {
            try expect(value(in: result, for: "home-\(index)") == false,
                       "largest cluster should be home")
        }
        for index in 0..<5 {
            try expect(value(in: result, for: "park-\(index)") == true,
                       "non-home stable cluster should be outing")
        }
        try expect(value(in: result, for: "away") == true,
                   "located noise outside home should be outing")
        try expect(value(in: result, for: "missing") == nil,
                   "missing GPS must remain unknown")
    }

    private static func verifiesStableOrderingAndTieBreak() throws {
        let first = cluster(prefix: "a", latitude: 34.7, longitude: 135.5, count: 5)
            + cluster(prefix: "b", latitude: 43.0, longitude: 141.3, count: 5)
        let forward = HomeLocationClassifier.classify(first)
        let reverse = HomeLocationClassifier.classify(Array(first.reversed()))
        try expect(equivalent(forward, reverse),
                   "input order must not change the selected home cluster")
        let homeCount = first.lazy.filter {
            value(in: forward, for: $0.localIdentifier) == false
        }.count
        try expect(homeCount == 5, "an equal-size tie must select exactly one cluster")
    }

    private static func verifiesAntimeridianNeighbourhood() throws {
        let samples = (0..<5).map { index in
            sample(
                "date-line-\(index)",
                latitude: 0,
                longitude: index.isMultiple(of: 2) ? 179.9996 : -179.9996
            )
        }
        let result = HomeLocationClassifier.classify(samples)
        for sample in samples {
            try expect(value(in: result, for: sample.localIdentifier) == false,
                       "nearby photos across the antimeridian should cluster")
        }
    }

    private static func verifiesRadiusBoundary() throws {
        let radius = 200.0
        let inside = [
            equatorialSample("inside-a", eastMeters: 0),
            equatorialSample("inside-b", eastMeters: radius - 0.001)
        ]
        let outside = [
            equatorialSample("outside-a", eastMeters: 0),
            equatorialSample("outside-b", eastMeters: radius + 0.001)
        ]

        let insideResult = HomeLocationClassifier.classify(
            inside,
            radiusMeters: radius,
            minimumClusterSize: 2
        )
        try expect(
            inside.allSatisfy { value(in: insideResult, for: $0.localIdentifier) == false },
            "points just inside the radius must form a cluster"
        )

        let outsideResult = HomeLocationClassifier.classify(
            outside,
            radiusMeters: radius,
            minimumClusterSize: 2
        )
        try expect(
            outside.allSatisfy { value(in: outsideResult, for: $0.localIdentifier) == nil },
            "points just outside the radius must not form a cluster"
        )
    }

    private static func verifiesTwoCellNeighbourReach() throws {
        // With cellSize = radius / sqrt(3), these positions land two y-cells
        // apart in the Earth-centred grid while remaining only 0.60r apart.
        // A +/-1-cell search would incorrectly split them.
        let radius = 200.0
        let samples = (0..<3).map {
            equatorialSample("two-cell-left-\($0)", eastMeters: radius * 0.56)
        } + (0..<2).map {
            equatorialSample("two-cell-right-\($0)", eastMeters: radius * 1.16)
        }
        let result = HomeLocationClassifier.classify(
            samples,
            radiusMeters: radius,
            minimumClusterSize: 5
        )
        try expect(
            samples.allSatisfy { value(in: result, for: $0.localIdentifier) == false },
            "points within radius across a two-cell offset must cluster"
        )
    }

    private static func verifiesSparseChainDoesNotBecomeHome() throws {
        let samples = (0..<8).map {
            equatorialSample("sparse-chain-\($0)", eastMeters: Double($0) * 150)
        }
        let result = HomeLocationClassifier.classify(
            samples,
            radiusMeters: 200,
            minimumClusterSize: 5
        )
        try expect(
            samples.allSatisfy { value(in: result, for: $0.localIdentifier) == nil },
            "a sparse epsilon-connected travel chain must not become home"
        )
    }

    private static func verifiesDenseLibraryWithoutQuadraticStorage() throws {
        let samples = (0..<10_000).map {
            sample("dense-\($0)", latitude: 35.681236, longitude: 139.767125)
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = HomeLocationClassifier.classify(samples)
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        try expect(result.count == samples.count, "dense stress result lost identifiers")
        try expect(
            samples.allSatisfy { value(in: result, for: $0.localIdentifier) == false },
            "ten thousand colocated photos must form one home cluster"
        )
        try expect(
            elapsed < 5,
            "dense 10k classification regressed beyond the linear fast path: \(elapsed)s"
        )
    }

    private static func verifiesOptimizedClassifierAgainstReferenceDBSCAN() throws {
        let configurations: [(radius: Double, minimumCount: Int)] = [
            (55, 2),
            (90, 3),
            (140, 5),
            (200, 5),
            (360, 7)
        ]
        let seeds: [UInt64] = [
            0x243f_6a88_85a3_08d3,
            0x1319_8a2e_0370_7344,
            0xa409_3822_299f_31d0,
            0x082e_fa98_ec4e_6c89
        ]

        for configuration in configurations {
            for seed in seeds {
                let samples = randomizedScenario(
                    seed: seed,
                    radiusMeters: configuration.radius,
                    minimumClusterSize: configuration.minimumCount
                )
                let expected = referenceDBSCAN(
                    samples,
                    radiusMeters: configuration.radius,
                    minimumClusterSize: configuration.minimumCount
                )
                let actual = HomeLocationClassifier.classify(
                    samples,
                    radiusMeters: configuration.radius,
                    minimumClusterSize: configuration.minimumCount
                )
                try expect(
                    equivalent(actual, expected),
                    "optimized DBSCAN diverged from reference "
                        + "(r=\(configuration.radius), "
                        + "min=\(configuration.minimumCount), seed=\(seed))"
                )

                let reversed = Array(samples.reversed())
                let reversedActual = HomeLocationClassifier.classify(
                    reversed,
                    radiusMeters: configuration.radius,
                    minimumClusterSize: configuration.minimumCount
                )
                try expect(
                    equivalent(reversedActual, expected),
                    "optimized DBSCAN changed with input order "
                        + "(r=\(configuration.radius), "
                        + "min=\(configuration.minimumCount), seed=\(seed))"
                )
            }
        }
    }

    private static func cluster(
        prefix: String,
        latitude: Double,
        longitude: Double,
        count: Int
    ) -> [AlbumLocationSample] {
        (0..<count).map { index in
            // Roughly eleven metres per 0.0001° latitude near these fixtures.
            sample(
                "\(prefix)-\(index)",
                latitude: latitude + Double(index) * 0.00002,
                longitude: longitude + Double(index) * 0.00002
            )
        }
    }

    private static func sample(
        _ identifier: String,
        latitude: Double,
        longitude: Double
    ) -> AlbumLocationSample {
        AlbumLocationSample(
            localIdentifier: identifier,
            latitude: latitude,
            longitude: longitude
        )
    }

    private static func equatorialSample(
        _ identifier: String,
        eastMeters: Double
    ) -> AlbumLocationSample {
        sample(
            identifier,
            latitude: 0,
            longitude: eastMeters / ReferencePoint.earthRadiusMeters * 180 / .pi
        )
    }

    private static func randomizedScenario(
        seed: UInt64,
        radiusMeters: Double,
        minimumClusterSize: Int
    ) -> [AlbumLocationSample] {
        var random = SeededGenerator(seed: seed)
        var samples: [AlbumLocationSample] = []
        let origins = [
            (latitude: 35.681236, longitude: 139.767125, count: minimumClusterSize + 5),
            (latitude: 35.690000, longitude: 139.700000, count: minimumClusterSize + 2),
            (latitude: 70.000000, longitude: 20.000000, count: max(2, minimumClusterSize - 2))
        ]

        for (originIndex, origin) in origins.enumerated() {
            for pointIndex in 0..<origin.count {
                let angle = random.unitInterval() * 2 * Double.pi
                let distance = sqrt(random.unitInterval()) * radiusMeters * 0.42
                samples.append(offsetSample(
                    "random-\(seed)-\(originIndex)-\(pointIndex)",
                    latitude: origin.latitude,
                    longitude: origin.longitude,
                    eastMeters: cos(angle) * distance,
                    northMeters: sin(angle) * distance
                ))
            }
        }

        for index in 0..<36 {
            samples.append(offsetSample(
                "noise-\(seed)-\(index)",
                latitude: 35.685,
                longitude: 139.735,
                eastMeters: (random.unitInterval() * 16 - 8) * radiusMeters,
                northMeters: (random.unitInterval() * 16 - 8) * radiusMeters
            ))
        }

        // Points immediately inside and outside epsilon exercise squared-
        // distance boundaries in the same property comparison.
        samples.append(equatorialSample(
            "boundary-origin-\(seed)",
            eastMeters: radiusMeters * 30
        ))
        samples.append(equatorialSample(
            "boundary-inside-\(seed)",
            eastMeters: radiusMeters * 30 + radiusMeters * (1 - 1e-8)
        ))
        samples.append(equatorialSample(
            "boundary-outside-\(seed)",
            eastMeters: radiusMeters * 30 + radiusMeters * (1 + 1e-8)
        ))
        samples.append(AlbumLocationSample(
            localIdentifier: "missing-\(seed)",
            latitude: nil,
            longitude: nil
        ))
        samples.append(AlbumLocationSample(
            localIdentifier: "invalid-\(seed)",
            latitude: 91,
            longitude: 0
        ))
        return samples
    }

    private static func offsetSample(
        _ identifier: String,
        latitude: Double,
        longitude: Double,
        eastMeters: Double,
        northMeters: Double
    ) -> AlbumLocationSample {
        let latitudeRadians = latitude * .pi / 180
        let shiftedLatitude = latitude
            + northMeters / ReferencePoint.earthRadiusMeters * 180 / .pi
        var shiftedLongitude = longitude
            + eastMeters / (ReferencePoint.earthRadiusMeters * cos(latitudeRadians))
                * 180 / .pi
        while shiftedLongitude > 180 { shiftedLongitude -= 360 }
        while shiftedLongitude < -180 { shiftedLongitude += 360 }
        return sample(identifier, latitude: shiftedLatitude, longitude: shiftedLongitude)
    }

    private static func referenceDBSCAN(
        _ samples: [AlbumLocationSample],
        radiusMeters: Double,
        minimumClusterSize: Int
    ) -> [String: Bool?] {
        let uniqueSamples = referenceUniqueSamples(samples)
        var output = Dictionary(uniqueKeysWithValues: uniqueSamples.map {
            ($0.localIdentifier, Optional<Bool>.none)
        })
        guard radiusMeters > 0, minimumClusterSize > 0 else { return output }

        let points = uniqueSamples.compactMap(ReferencePoint.init(sample:))
        guard points.count >= minimumClusterSize else { return output }
        let chordRadius = 2 * ReferencePoint.earthRadiusMeters
            * sin(radiusMeters / (2 * ReferencePoint.earthRadiusMeters))
        let squaredRadius = chordRadius * chordRadius
        let neighbourhoods = points.indices.map { index in
            points.indices.filter {
                referenceSquaredDistance(points[index], points[$0]) <= squaredRadius
            }
        }
        let isCore = neighbourhoods.map { $0.count >= minimumClusterSize }
        guard isCore.contains(true) else { return output }

        var union = ReferenceDisjointSet(count: points.count)
        for index in points.indices where isCore[index] {
            for neighbour in neighbourhoods[index]
                where neighbour > index && isCore[neighbour] {
                union.connect(index, neighbour)
            }
        }

        var membersByRoot: [Int: Set<Int>] = [:]
        var coreRootByIndex: [Int: Int] = [:]
        for index in points.indices where isCore[index] {
            let root = union.root(of: index)
            coreRootByIndex[index] = root
            membersByRoot[root, default: []].insert(index)
        }
        let stableKeyByRoot = Dictionary(uniqueKeysWithValues: membersByRoot.map {
            ($0.key, referenceStableClusterKey(members: $0.value, points: points))
        })

        for index in points.indices where !isCore[index] {
            var selectedRoot: Int?
            var selectedDistance = Double.greatestFiniteMagnitude
            for candidate in neighbourhoods[index] where isCore[candidate] {
                guard let candidateRoot = coreRootByIndex[candidate] else { continue }
                let candidateDistance = referenceSquaredDistance(points[index], points[candidate])
                let winsDistance = candidateDistance < selectedDistance
                let winsTie = candidateDistance == selectedDistance
                    && (stableKeyByRoot[candidateRoot] ?? .maximum)
                        < (selectedRoot.flatMap { stableKeyByRoot[$0] } ?? .maximum)
                if winsDistance || winsTie {
                    selectedRoot = candidateRoot
                    selectedDistance = candidateDistance
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

    private static func referenceUniqueSamples(
        _ samples: [AlbumLocationSample]
    ) -> [AlbumLocationSample] {
        var unique: [String: AlbumLocationSample] = [:]
        for sample in samples where !sample.localIdentifier.isEmpty {
            if unique[sample.localIdentifier] == nil { unique[sample.localIdentifier] = sample }
        }
        return unique.values.sorted { $0.localIdentifier < $1.localIdentifier }
    }

    private static func referenceSquaredDistance(
        _ lhs: ReferencePoint,
        _ rhs: ReferencePoint
    ) -> Double {
        let x = lhs.x - rhs.x
        let y = lhs.y - rhs.y
        let z = lhs.z - rhs.z
        return x * x + y * y + z * z
    }

    private static func referenceStableClusterKey(
        members: Set<Int>,
        points: [ReferencePoint]
    ) -> ReferenceStableClusterKey {
        members.lazy.map { points[$0].stableKey }.min() ?? .maximum
    }

    private static func value(
        in result: [String: Bool?],
        for identifier: String
    ) -> Bool? {
        guard let stored = result[identifier] else {
            fatalError("missing classification entry for \(identifier)")
        }
        return stored
    }

    private static func equivalent(
        _ lhs: [String: Bool?],
        _ rhs: [String: Bool?]
    ) -> Bool {
        guard Set(lhs.keys) == Set(rhs.keys) else { return false }
        return lhs.keys.allSatisfy { value(in: lhs, for: $0) == value(in: rhs, for: $0) }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw VerificationError(message: message)
        }
    }
}

private struct VerificationError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func unitInterval() -> Double {
        state &+= 0x9e37_79b9_7f4a_7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        value ^= value >> 31
        return Double(value >> 11) / 9_007_199_254_740_992.0
    }
}

private struct ReferencePoint {
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

    var stableKey: ReferenceStableClusterKey {
        ReferenceStableClusterKey(x: x, y: y, z: z, identifier: localIdentifier)
    }
}

private struct ReferenceStableClusterKey: Comparable {
    var x: Double
    var y: Double
    var z: Double
    var identifier: String

    static let maximum = ReferenceStableClusterKey(
        x: .greatestFiniteMagnitude,
        y: .greatestFiniteMagnitude,
        z: .greatestFiniteMagnitude,
        identifier: "~"
    )

    static func < (lhs: ReferenceStableClusterKey, rhs: ReferenceStableClusterKey) -> Bool {
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        if lhs.z != rhs.z { return lhs.z < rhs.z }
        return lhs.identifier < rhs.identifier
    }
}

private struct ReferenceDisjointSet {
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
