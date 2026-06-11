import Testing
@testable import ObservationBridge

@Suite
final class ObservationOptionsTests {
    @Test
    func observationOptionsDefaultsToDidSet() {
        let options = PortableObservationTracking.Options.didSet

        #expect(options.contains(.didSet))
        #expect(!PortableObservationTracking.Options().contains(.didSet))

        let willSetOptions: PortableObservationTracking.Options = [.willSet, .didSet]
        #expect(willSetOptions.contains(.willSet))
        #expect(willSetOptions.contains(.didSet))

        #if compiler(>=6.4)
        if #available(anyAppleOS 27.0, *) {
            let deinitOptions: PortableObservationTracking.Options = [.willSet, .didSet, .deinit]
            #expect(deinitOptions.contains(.willSet))
            #expect(deinitOptions.contains(.didSet))
            #expect(deinitOptions.contains(.deinit))
        }
        #endif
    }
}
