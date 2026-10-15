//
//  DecalEditing.swift
//  openshape3d
//
//  Visualize ▸ Decals (spec §14): Add Decal… picks an image, the next tap on
//  a body puts it there (facing out of the surface, a third of the body's
//  size); Move on the Surface takes it to the next tap; size, rotation and
//  opacity are sliders (live while dragging, one undo step on release);
//  Remove takes it off. The drawing is DecalKit + the renderers.
//

import Foundation
import simd

extension EditorViewModel {

    /// The decals as shown: the draft while a slider moves, else the design's.
    var decals: [Decal] { decalsDraft ?? session.document.decals }

    /// Add Decal…: hold the picked image until a tap places it.
    func beginDecal(name: String, image: Data, aspect: Double) {
        guard aspect.isFinite, aspect > 0 else { return }
        movingDecalID = nil
        pendingDecal = (name, image, aspect)
    }

    func cancelDecalPlacement() {
        pendingDecal = nil
        movingDecalID = nil
    }

    /// What the next tap does, under the panel.
    var decalHint: String? {
        if pendingDecal != nil { return "Tap the model where the decal goes." }
        if movingDecalID != nil { return "Tap the model where the decal moves to." }
        return nil
    }

    /// A tap while placing or moving a decal: on a body, the decal goes
    /// there facing out of the surface; on empty space nothing changes.
    func decalTap(_ hit: PickHit?) {
        guard let hit, let body = session.document.body(with: hit.bodyID),
              let anchor = FaceMaterialKit.anchor(in: body.render, triangle: hit.triangleIndex) else { return }
        let local4 = simd_inverse(body.transform.matrix)
            * SIMD4(Double(hit.worldPoint.x), Double(hit.worldPoint.y), Double(hit.worldPoint.z), 1)
        let point = SIMD3(local4.x, local4.y, local4.z)
        var next = decals
        if let pending = pendingDecal {
            let decal = Decal(bodyID: body.id, name: pending.name, image: pending.image, center: point,
                              normal: anchor.normal, width: DecalKit.defaultWidth(for: body), aspect: pending.aspect)
            next.append(decal)
            pendingDecal = nil
            selectedDecalID = decal.id
            setDecals(next, title: "Add Decal")
        } else if let id = movingDecalID, let i = next.firstIndex(where: { $0.id == id }) {
            next[i].bodyID = body.id
            next[i].center = point
            next[i].normal = anchor.normal
            movingDecalID = nil
            setDecals(next, title: "Move Decal")
        }
    }

    /// Change one decal. `live` keeps it as a draft (a slider still moving).
    func updateDecal(_ id: UUID, live: Bool = false, _ change: (inout Decal) -> Void) {
        var next = decals
        guard let i = next.firstIndex(where: { $0.id == id }) else { return }
        change(&next[i])
        next[i].width = min(max(next[i].width, DecalKit.widthRange.lowerBound), DecalKit.widthRange.upperBound)
        next[i].opacity = min(max(next[i].opacity, 0), 1)
        next[i].rotation = next[i].rotation.truncatingRemainder(dividingBy: 360)
        if live {
            decalsDraft = next
        } else {
            setDecals(next, title: "Edit Decal")
        }
    }

    func removeDecal(_ id: UUID) {
        if selectedDecalID == id { selectedDecalID = nil }
        if movingDecalID == id { movingDecalID = nil }
        setDecals(decals.filter { $0.id != id }, title: "Remove Decal")
    }

    /// Save a dragged slider's value.
    func commitDecals() {
        guard let draft = decalsDraft else { return }
        setDecals(draft, title: "Edit Decal")
    }

    private func setDecals(_ new: [Decal], title: String) {
        decalsDraft = nil
        let old = session.document.decals
        guard new != old else { return }
        session.perform(SetDecalsCommand(title: title, old: old, new: new))
    }

    /// The decals of the bodies drawn, in world space.
    func decalDrawables(drawn: Set<BodyID>) -> [DecalDrawable] {
        decals.compactMap { decal in
            guard drawn.contains(decal.bodyID), let body = session.document.body(with: decal.bodyID) else { return nil }
            let m = body.transform.matrix
            func point(_ p: SIMD3<Double>) -> SIMD3<Double> {
                let w = m * SIMD4(p, 1)
                return SIMD3(w.x, w.y, w.z)
            }
            func direction(_ d: SIMD3<Double>) -> SIMD3<Double> {
                let w = m * SIMD4(d, 0)
                return SIMD3(w.x, w.y, w.z)
            }
            let (u, v, n) = DecalKit.frame(decal)
            let scale = simd_length(direction(u))
            guard scale > 1e-12 else { return nil }
            let halfWidth = decal.width / 2 * scale, halfHeight = decal.height / 2 * scale
            return DecalDrawable(
                id: decal.id, bodyID: decal.bodyID, image: decal.image,
                center: SIMD3<Float>(point(decal.center)),
                u: SIMD3<Float>(simd_normalize(direction(u))), v: SIMD3<Float>(simd_normalize(direction(v))),
                n: SIMD3<Float>(simd_normalize(direction(n))),
                halfWidth: Float(halfWidth), halfHeight: Float(halfHeight),
                depth: Float(max(halfWidth, halfHeight)), opacity: Float(decal.opacity),
                isSelected: visualizeActive && selectedDecalID == decal.id)
        }
    }
}
