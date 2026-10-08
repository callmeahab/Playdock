import Combine

// Holds subscriptions only; UI-state publishers emit from their owning MainActor models.
public final class FeatureObservation: ObservableObject {
    public let objectWillChange = ObservableObjectPublisher()
    private var subscriptions: Set<AnyCancellable> = []

    public init(publishers: [ObservableObjectPublisher]) {
        for publisher in publishers {
            publisher.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        }
    }
}
