import Flutter
import GoogleMaps
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    guard
      let mapsApiKey = Bundle.main.object(forInfoDictionaryKey: "GMSApiKey") as? String,
      !mapsApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !mapsApiKey.contains("$(")
    else {
      fatalError(
        "Set GOOGLE_MAPS_IOS_API_KEY in ios/Flutter/Local.xcconfig."
      )
    }
    GMSServices.provideAPIKey(mapsApiKey)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
