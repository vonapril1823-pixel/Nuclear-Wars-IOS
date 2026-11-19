# Nuclear Wars: iPhone / iPad project

Offline Capacitor app. The game, 3D engine and fonts are bundled in `www/`, so it works with no internet.
It is locked to landscape and runs full screen. The same `www/index.html` is used by the Android project.

iOS apps can only be built with Apple's tools, so you need ONE of these:

## A. A Mac with Xcode
```
npm install
npx cap sync ios        # also runs "pod install" (needs CocoaPods: brew install cocoapods)
npx cap open ios
```
In Xcode: pick the **App** target, Signing & Capabilities, choose your Team (a free Apple ID works), plug in the iPhone, press Run.
With a free Apple ID the app expires after 7 days and must be re-installed; a paid Apple Developer account lasts a year and allows TestFlight.

## B. No Mac: build online with GitHub, then sign with a sideloading tool
1. Make a free GitHub account, create an empty repository and upload every file in this folder.
2. Open the Actions tab, run **Build Nuclear Wars iOS** (about 10 minutes, it runs on a Mac in the cloud).
3. Download `NuclearWars-unsigned-ipa`, unzip it to get `NuclearWars-unsigned.ipa`.
4. Install it on the iPhone with a tool that signs it with your Apple ID, for example AltStore or Sideloadly (same 7-day limit for free Apple IDs).

## Updating the game
Replace `www/index.html` with the new game file (keep the name), run `npx cap sync ios`, rebuild.

## Playing together
- The first time, iOS asks to allow **Local Network**. Tap Allow, otherwise phones cannot find or reach each other.
- Phones on the same Wi-Fi or hotspot find each other automatically. The native plugin is `ios/App/App/NWLan.swift` (twin of the Android `NWLan.java`).
- iPhones cannot receive UDP broadcasts without a special Apple entitlement, so the plugin also scans the local network (`lanScan`) to find hosts. Games hosted on Android phones show up on iPhones this way.
- An Android phone only sees UDP broadcasts. It will not list a game hosted on an iPhone. For that case the Android player taps **Join with code**, or the iPhone is used as the joiner.
- If a connection drops, the match pauses and both phones reconnect by themselves (up to 2 minutes). iOS freezes apps that go to the background, so keep the game open during a match.

## Notes
- The app icon is the default placeholder. Replace `ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png` with a 1024x1024 PNG.
- Camera permission is only used to scan the Versus invite QR code.
- This project was prepared without access to a Mac, so it has not been compiled yet. If Xcode reports an error, send it to me and I will fix it.
