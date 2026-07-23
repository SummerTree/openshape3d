//
//  spike_main.mm — Milestone 0 acceptance harness.
//  Exercises the OCCTBridge Obj-C++ facade on the iOS simulator and asserts
//  the two spike facts: a box tessellates + has exact volume, and an extruded
//  circle is ONE analytic cylindrical face (not a faceted prism).
//
#import <Foundation/Foundation.h>
#import "OCCTBridge.h"

static int failures = 0;
static void check(bool cond, NSString *msg) {
    NSLog(@"[%@] %@", cond ? @"PASS" : @"FAIL", msg);
    if (!cond) failures++;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSLog(@"OCCT version: %@", [OCCTBridge occtVersion]);
        check([OCCTBridge occtVersion].length > 0, @"OCCT links and reports a version");

        OCCTMeshResult *box = [OCCTBridge meshBoxWithSize:10.0];
        NSLog(@"box: tris=%ld verts=%ld vol=%.6f", (long)box.triangleCount,
              (long)box.vertexCount, box.volume);
        check(box.triangleCount > 0, @"box tessellates to >0 triangles");
        check(fabs(box.volume - 1000.0) < 1e-6, @"box volume == 10^3");

        OCCTFaceTypeCounts *c = [OCCTBridge extrudeCircleFaceCountsWithRadius:5.0 height:20.0];
        NSLog(@"extruded circle: planar=%ld cylindrical=%ld other=%ld",
              (long)c.planar, (long)c.cylindrical, (long)c.other);
        check(c.cylindrical == 1, @"extruded circle has exactly ONE cylindrical wall (not 48 facets)");
        check(c.planar == 2, @"extruded circle has 2 planar caps");
        check(c.other == 0, @"extruded circle has no other face types");

        NSLog(@"=== SPIKE %@ (%d failures) ===", failures == 0 ? @"SUCCEEDED" : @"FAILED", failures);
        return failures == 0 ? 0 : 1;
    }
}
