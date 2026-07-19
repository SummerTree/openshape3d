//
//  SketchConnectivity.swift
//  openshape3d
//
//  Endpoint connectivity over sketch entities (plan §B6): double-tapping an
//  entity selects its whole connected chain. Lines and arcs connect through
//  shared (quantized) endpoints; closed entities (circles, rects, ellipses,
//  polygons) have no endpoints and form single-entity islands.
//

import Foundation
import simd

nonisolated extension ProfileDetector {

    /// IDs of every entity endpoint-connected to `startID` (including it).
    /// Unknown IDs return just themselves.
    static func connectedEntityIDs(
        from startID: UUID, in entities: [SketchEntity]
    ) -> Set<UUID> {
        struct NodeKey: Hashable {
            let x, y: Int64
            init(_ p: SIMD2<Double>) {
                x = Int64((p.x / 1e-6).rounded())
                y = Int64((p.y / 1e-6).rounded())
            }
        }

        func endpoints(of entity: SketchEntity) -> [SIMD2<Double>] {
            switch entity {
            case let .line(_, a, b):
                return [a, b]
            case let .arc(_, center, radius, startAngle, endAngle):
                return [
                    SketchEntity.arcPoint(center: center, radius: radius, angle: startAngle),
                    SketchEntity.arcPoint(center: center, radius: radius, angle: endAngle),
                ]
            case .rect, .circle, .ellipse, .polygon:
                return [] // closed: no endpoints to chain through
            }
        }

        var entityIDsAtNode: [NodeKey: [UUID]] = [:]
        var nodesOfEntity: [UUID: [NodeKey]] = [:]
        for entity in entities {
            let keys = endpoints(of: entity).map(NodeKey.init)
            nodesOfEntity[entity.id] = keys
            for key in keys {
                entityIDsAtNode[key, default: []].append(entity.id)
            }
        }

        var visited: Set<UUID> = [startID]
        var queue = [startID]
        while let id = queue.popLast() {
            for key in nodesOfEntity[id] ?? [] {
                for neighbor in entityIDsAtNode[key] ?? [] where !visited.contains(neighbor) {
                    visited.insert(neighbor)
                    queue.append(neighbor)
                }
            }
        }
        return visited
    }
}
