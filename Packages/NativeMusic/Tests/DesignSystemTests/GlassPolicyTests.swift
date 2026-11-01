import DesignSystem
import Testing

@Suite struct GlassPolicyTests {
  @Test func nativeGlassAndAccessibilityMatrix() {
    var count = 0
    for transparency in [false, true] {
      for contrast in [false, true] {
        for motion in [false, true] {
          for power in [false, true] {
            for active in [false, true] {
              let policy = GlassPolicy(
                reduceTransparency: transparency, increasedContrast: contrast,
                reduceMotion: motion, lowPower: power, active: active)
              if transparency || contrast {
                #expect(policy.opaque)
              } else {
                #expect(!policy.opaque)
              }
              if !active || power {
                #expect(policy.simplified)
                #expect(!policy.animates)
              }
              if motion { #expect(!policy.animates) }
              count += 1
            }
          }
        }
      }
    }
    #expect(count == 32)
    let normal = GlassPolicy(
      reduceTransparency: false, increasedContrast: false, reduceMotion: false, lowPower: false,
      active: true)
    #expect(!normal.opaque && !normal.simplified && normal.animates)
  }
}
