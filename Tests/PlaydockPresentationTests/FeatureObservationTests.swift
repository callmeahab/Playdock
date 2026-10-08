import Combine
import XCTest
@testable import PlaydockPresentation

final class FeatureObservationTests: XCTestCase {
    func testUnrelatedFeaturesDoNotInvalidateLibraryViews() async {
        await MainActor.run {
            let library = LibraryModel(), social = SocialModel(), installation = InstallationModel()
            let observation = FeatureObservation(publishers: [library.objectWillChange])
            var updates = 0
            let subscription = observation.objectWillChange.sink { updates += 1 }
            social.busy = true
            installation.storageBusy = true
            XCTAssertEqual(updates, 0)
            library.refreshing = true
            XCTAssertEqual(updates, 1)
            withExtendedLifetime(subscription) {}
        }
    }

    func testSelectedFeaturesAndNavigationEachInvalidateOnce() async {
        await MainActor.run {
            let navigation = ObservableObjectPublisher()
            let steam = SteamConnectionModel(), social = SocialModel(), runtime = RuntimeModel()
            let observation = FeatureObservation(publishers: [navigation, steam.objectWillChange, social.objectWillChange])
            var updates = 0
            let subscription = observation.objectWillChange.sink { updates += 1 }
            runtime.bridgeBusy = true
            XCTAssertEqual(updates, 0)
            steam.busy = true
            social.message = "Reconnecting"
            navigation.send()
            XCTAssertEqual(updates, 3)
            withExtendedLifetime(subscription) {}
        }
    }

    func testObservationReleasesSubscriptions() async {
        await MainActor.run {
            let social = SocialModel()
            weak var released: FeatureObservation?
            var updates = 0
            var subscription: AnyCancellable?
            do {
                let observation = FeatureObservation(publishers: [social.objectWillChange])
                released = observation
                subscription = observation.objectWillChange.sink { updates += 1 }
                social.busy = true
            }
            XCTAssertNil(released)
            social.busy = false
            XCTAssertEqual(updates, 1)
            withExtendedLifetime(subscription) {}
        }
    }
}
