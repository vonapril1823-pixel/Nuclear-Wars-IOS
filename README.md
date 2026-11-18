# Nuclear Wars: iPhone / iPad project

Same offline game as the Android app (everything is bundled in `www/`), wrapped with Capacitor for iOS.
Landscape only, full screen, screen stays awake. The Versus lobby list uses a Swift version of the Android plugin (`ios/App/App/NWLan.swift`).

## Build with GitHub (no Mac needed)
1. Create a free GitHub repository and upload every file in this folder (keep the `.github` folder).
2. Actions tab > "Build Nuclear Wars iOS IPA" > Run workflow (about 8 minutes).
3. Download the artifact `NuclearWars-ios-ipa` and unzip it to get `NuclearWars-unsigned.ipa`.

## Put it on an iPhone
The IPA is unsigned, so it must be signed with an Apple ID first.
- Free Apple ID: use Sideloadly (Windows/Mac) or AltStore. The app works for 7 days, then re-sign it. Limit: 3 sideloaded apps at once.
- Paid Apple Developer account ($99/year): sign it in Xcode or upload to TestFlight (installs last 90 days).
- iPhone must be on iOS 14.3 or newer. First launch: Settings > General > VPN & Device Management > trust your Apple ID. Turn on Developer Mode (Settings > Privacy & Security) on iOS 16+.

## On a Mac
```
npm install
npx cap sync ios
npx cap open ios      # then pick your team under Signing & Capabilities and press Run
```

## Updating the game
Replace `www/index.html` with the new file (keep the name), then run the workflow again (or `npx cap sync ios`).

## Notes
- iPhone asks for Local Network and Camera permission on first Versus use. Allow both: Local Network finds lobbies, and Camera access lets the phones see each other's addresses for the direct connection.
- Scanning invite QR codes does not work in iPhone web views. Use the lobby list, or Copy and Paste the code.
- iPhone and Android phones on the same hotspot use the same lobby protocol and should see each other's lobbies.
