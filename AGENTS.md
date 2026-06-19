## Test Commands

- Xcode 27 + iOS 27.0:

```sh
DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer /usr/bin/xcodebuild -workspace ObservationBridge.xcworkspace -scheme ObservationBridgeTests -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' CODE_SIGNING_ALLOWED=NO test
```

- Xcode 27 + iOS 26.5:

```sh
DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer /usr/bin/xcodebuild -workspace ObservationBridge.xcworkspace -scheme ObservationBridgeTests -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' CODE_SIGNING_ALLOWED=NO test
```

- Xcode 26.6 + iOS 27.0:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild -workspace ObservationBridge.xcworkspace -scheme ObservationBridgeTests -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' CODE_SIGNING_ALLOWED=NO test
```

- Xcode 26.6 + iOS 26.5:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild -workspace ObservationBridge.xcworkspace -scheme ObservationBridgeTests -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' CODE_SIGNING_ALLOWED=NO test
```

- Xcode 27 + watchOS 26.5:

```sh
DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer /usr/bin/xcodebuild -workspace ObservationBridge.xcworkspace -scheme ObservationBridgeTests -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (42mm),OS=26.5' CODE_SIGNING_ALLOWED=NO test
```

- Xcode 26.6 + watchOS 26.5:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild -workspace ObservationBridge.xcworkspace -scheme ObservationBridgeTests -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (42mm),OS=26.5' CODE_SIGNING_ALLOWED=NO test
```
