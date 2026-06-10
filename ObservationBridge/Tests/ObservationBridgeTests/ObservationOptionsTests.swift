import Testing
@testable import ObservationBridge

@Suite
final class ObservationOptionsTests {
    @Test
    func observationOptionsDefaultsToDidSet() {
        let options = ObservationOptions.didSet

        #expect(options.contains(.didSet))
        #expect(!ObservationOptions().contains(.didSet))

        let willSetOptions: ObservationOptions = [.willSet, .didSet]
        #expect(willSetOptions.contains(.willSet))
        #expect(willSetOptions.contains(.didSet))

        #if compiler(>=6.4)
        if #available(anyAppleOS 27.0, *) {
            let deinitOptions: ObservationOptions = [.willSet, .didSet, .deinit]
            #expect(deinitOptions.contains(.willSet))
            #expect(deinitOptions.contains(.didSet))
            #expect(deinitOptions.contains(.deinit))
        }
        #endif
    }
}
