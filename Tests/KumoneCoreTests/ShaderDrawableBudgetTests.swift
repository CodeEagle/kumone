import CoreGraphics
import Testing
@testable import KumoneCore

@Suite("Shader Drawable Budget Tests")
struct ShaderDrawableBudgetTests {
    @Test func smallDrawableKeepsScaledSize() {
        #expect(ShaderDrawableBudget.clamped(from: CGSize(width: 500, height: 400), scale: 2)
            == CGSize(width: 1000, height: 800))
    }

    @Test func exactBudgetIsUnchanged() {
        #expect(ShaderDrawableBudget.maxPixels == CGSize(width: 1920, height: 1080))
        #expect(ShaderDrawableBudget.clamped(from: CGSize(width: 960, height: 540), scale: 2)
            == CGSize(width: 1920, height: 1080))
    }

    @Test func oversizedLandscapeShrinksProportionally() {
        #expect(ShaderDrawableBudget.clamped(from: CGSize(width: 2560, height: 1440), scale: 2)
            == CGSize(width: 1920, height: 1080))
    }

    @Test func heightLimitsOversizedSquare() {
        #expect(ShaderDrawableBudget.clamped(from: CGSize(width: 2000, height: 2000), scale: 2)
            == CGSize(width: 1080, height: 1080))
    }

    @Test func highScaleRespectsAbsolutePixelBudget() {
        #expect(ShaderDrawableBudget.clamped(from: CGSize(width: 1000, height: 1000), scale: 3)
            == CGSize(width: 1080, height: 1080))
    }

    @Test func nonFiniteDimensionsReturnNil() {
        for value in [CGFloat.infinity, -CGFloat.infinity, CGFloat.nan] {
            #expect(ShaderDrawableBudget.clamped(from: CGSize(width: value, height: 400), scale: 2) == nil)
            #expect(ShaderDrawableBudget.clamped(from: CGSize(width: 500, height: value), scale: 2) == nil)
        }
    }

    @Test func emptyOrNegativeDimensionsReturnNil() {
        for value in [CGFloat.zero, -1] {
            #expect(ShaderDrawableBudget.clamped(from: CGSize(width: value, height: 400), scale: 2) == nil)
            #expect(ShaderDrawableBudget.clamped(from: CGSize(width: 500, height: value), scale: 2) == nil)
        }
        #expect(ShaderDrawableBudget.clamped(from: .zero, scale: 2) == nil)
    }

    @Test func invalidScalesReturnNil() {
        for scale in [CGFloat.zero, -1, .infinity, -.infinity, .nan] {
            #expect(ShaderDrawableBudget.clamped(from: CGSize(width: 500, height: 400), scale: scale) == nil)
        }
    }

    @Test func fractionalClampedPixelsRoundDown() {
        // Height limits the scale to 1080/1081; width becomes 1919.222941720629.
        #expect(ShaderDrawableBudget.clamped(from: CGSize(width: 1921, height: 1081), scale: 1)
            == CGSize(width: 1919, height: 1080))
    }

    @Test func subpixelDimensionsHaveOnePixelMinimum() {
        #expect(ShaderDrawableBudget.clamped(from: CGSize(width: 0.1, height: 0.2), scale: 1)
            == CGSize(width: 1, height: 1))
    }

    @Test func widthLimitAlsoShrinksHeight() {
        #expect(ShaderDrawableBudget.clamped(from: CGSize(width: 4000, height: 500), scale: 1)
            == CGSize(width: 1920, height: 240))
    }
}
