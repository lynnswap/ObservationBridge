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
    }
}
