import Combine
import SwiftUI
import PlaydockPresentation

enum LauncherFeature {
    case library, runtime, installation, social, downloads, features, settings, activity, steam

    @MainActor func publisher(in model: LauncherModel) -> ObservableObjectPublisher {
        switch self {
        case .library: model.libraryState.objectWillChange
        case .runtime: model.runtimeState.objectWillChange
        case .installation: model.installationState.objectWillChange
        case .social: model.socialState.objectWillChange
        case .downloads: model.downloadsState.objectWillChange
        case .features: model.featuresState.objectWillChange
        case .settings: model.settingsState.objectWillChange
        case .activity: model.activityState.objectWillChange
        case .steam: model.steamState.objectWillChange
        }
    }
}

// Each view subscribes to its features and app navigation; feature updates stay off the shell.
@MainActor
@propertyWrapper
struct ObservedFeatures: DynamicProperty {
    private let model: LauncherModel
    @ObservedObject private var observation: FeatureObservation

    init(wrappedValue model: LauncherModel, _ features: [LauncherFeature] = []) {
        self.model = model
        _observation = ObservedObject(wrappedValue: FeatureObservation(
            publishers: [model.objectWillChange] + features.map { $0.publisher(in: model) }))
    }

    var wrappedValue: LauncherModel { model }
    var projectedValue: Binding<LauncherModel> { Binding(get: { model }, set: { _ in }) }
}
