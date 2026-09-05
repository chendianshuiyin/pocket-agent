# 移动平台交付基线

日期：2026-09-05。本文记录 Android 与 iOS 平台配置的静态审查结果，不代表商店发布完成。当前环境没有 Mac/Xcode，iOS 未构建、未签名、未在 iPhone 上验证。

## Android

- `mobile/android/app/build.gradle.kts` 使用 Flutter 3.47.1 的平台默认值；本次生成的 merged release manifest 为 `minSdk 24`、`targetSdk 36`。
- `release` build type 当前引用 `signingConfigs.debug`。因此产物是经过 release 编译优化、但使用 debug certificate 签名的测试 APK；它不是 debug APK，也不是可声明为正式发布签名的 APK。个人测试时，后续安装升级必须继续使用同一 debug keystore。
- 正式发布前必须创建并妥善保管独立的 release key，在本机安全配置 signing credentials，将 `release` 切换到正式 signing config，并核验最终 APK/AAB 的 certificate、versionCode、applicationId 与商店配置。不得把 keystore 或密码提交到仓库。
- `mobile/android/app/src/main/AndroidManifest.xml` 仅显式申请 `android.permission.INTERNET`。应用未启用 biometric secure storage，因此当前不需要 `USE_BIOMETRIC`。
- 同一 manifest 设置了 `android:allowBackup="false"`、`android:fullBackupContent="false"` 和 `android:dataExtractionRules="@xml/backup_rules"`。`mobile/android/app/src/main/res/xml/backup_rules.xml` 对 cloud backup 与 device transfer 的 `root`、`sharedpref`、`database`、`file`、`external` 全部排除，覆盖 secure storage 所用的 SharedPreferences 数据。
- targetSdk 36 下，`INTERNET` 同时满足公网与局域网直连。Android 17 / targetSdk 37 起才需要为直接 LAN 访问声明并运行时请求 `ACCESS_LOCAL_NETWORK`；升级 targetSdk 前应实现并测试拒绝、撤销与重试流程，不应在当前 targetSdk 36 提前请求该权限。

## iOS

- `mobile/ios/Runner.xcodeproj/project.pbxproj` 的 Debug、Profile、Release deployment target 均为 iOS 15.0；当前依赖的最低版本不高于该值。
- `mobile/ios/Runner/Runner.entitlements` 包含空的 `keychain-access-groups`，且三个 build configuration 都通过 `CODE_SIGN_ENTITLEMENTS` 引用该文件，符合 `flutter_secure_storage 10.3.1` 的 Keychain Sharing 配置要求。
- `mobile/lib/core/server_repository.dart` 使用 `IOSOptions(accessibility: KeychainAccessibility.unlocked_this_device)`。对应 Darwin 插件将其映射为 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`，默认 `synchronizable=false`，因此 SSH secret 仅在设备解锁时可访问，不进入 iCloud Keychain，也不能迁移到新设备。
- 工程已包含 `FlutterGeneratedPluginSwiftPackage` 的 package reference、Runner target dependency 和 Frameworks 链接；`mobile/ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme` 也包含 `xcode_backend.sh prepare` pre-action。Windows 上 `mobile/ios/Flutter/ephemeral/` 内的空生成 package 是被忽略的宿主生成物，不能证明最终插件已链接；必须在装有 Xcode 15 或更新版本的 Mac 上重新生成并验证。
- `mobile/ios/Runner/Info.plist` 提供了 `NSLocalNetworkUsageDescription`，用于直连用户配置的局域网 SSH 主机。应用不执行 Bonjour discovery，因此当前没有证据要求配置 `NSBonjourServices`。公网 SSH 不需要额外的 iOS usage description。
- `flutter_secure_storage_darwin 0.3.2` 自带 `PrivacyInfo.xcprivacy`；`shared_preferences_foundation 2.5.7` 自带 UserDefaults required-reason 声明。是否完整进入最终 archive、App Privacy Report 以及 App Store privacy answers，仍须在 Mac 上按真实数据流核验。
- 工程没有预置 `DEVELOPMENT_TEAM` 或 provisioning profile。这是待发布者在 Xcode 中完成的签名配置，不是本次静态源码缺陷。

## Mac/Xcode 验证清单

- [ ] 安装与项目 Flutter 版本兼容的 Xcode 和 command-line tools，确认 Flutter 检测到 Xcode 15 或更新版本。
- [ ] 在 `mobile/` 执行 `flutter pub get`，检查生成的 `FlutterGeneratedPluginSwiftPackage/Package.swift` 包含 `flutter_secure_storage_darwin` 与 `shared_preferences_foundation`。
- [ ] 分别执行 `flutter build ios --debug --no-codesign` 与 `flutter build ios --release --no-codesign`，确认两个 configuration 的 native plugins 均编译和链接成功；只有命令成功后才能记录“iOS 构建通过”。
- [ ] 在 Xcode 中配置唯一且已注册的 Bundle ID、Apple Team、certificate 和 provisioning profile；分别检查 Debug、Profile、Release 的 Signing & Capabilities。
- [ ] Archive 后用 Xcode 或 `codesign` 检查最终 app 的 `keychain-access-groups` entitlement，而不是只检查仓库中的 plist。
- [ ] 在真机写入、读取并更新 SSH secret；杀进程和重启设备后复测，并确认设备未解锁时不可访问。
- [ ] 验证局域网首次连接会显示用途说明；覆盖允许、拒绝、设置中撤销后的 SSH 错误与重试。另测公网 SSH 和本机 loopback WebSocket tunnel。
- [ ] 检查 archive 内各 SDK 的 `PrivacyInfo.xcprivacy`，生成并审阅 App Privacy Report，按实际收集和传输行为填写 App Store Connect privacy answers。
- [ ] 在至少一台 iOS 15+ iPhone 上完成安装、启动、SSH host-key confirmation、PTY、Codex tunnel、前后台切换与重连验证。

## 核查来源

- [Flutter：Swift Package Manager for app developers](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers)
- [`flutter_secure_storage` 官方仓库与平台配置](https://github.com/juliansteenbakker/flutter_secure_storage)
- [Apple：TN3179 Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Apple：Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [Android：Local network permission](https://developer.android.com/privacy-and-security/local-network-permission)
- [Android：Back up user data with Auto Backup](https://developer.android.com/identity/data/autobackup)
- [Android：`<application>` manifest element](https://developer.android.com/guide/topics/manifest/application-element)
