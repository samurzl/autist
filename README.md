# Two-List Todo (iPhone)

This repository now contains a native iPhone app built with SwiftUI. It provides two simple lists—"Today" and "Later"—so you can keep your day focused while still capturing ideas for later.

## Project structure

- `TwoListTodo.xcodeproj` — Xcode project file.
- `TwoListTodo/` — SwiftUI source, assets, and Info.plist.

## Build and install on your iPhone (Xcode on macOS)

### 1) Open the project

1. On your Mac, open **Xcode**.
2. Choose **File → Open...** and select `TwoListTodo.xcodeproj` from this repo.

### 2) Configure signing

1. In Xcode, select the **TwoListTodo** project in the left sidebar.
2. Select the **TwoListTodo** target.
3. Under **Signing & Capabilities**, choose your **Team** (your Apple ID).
4. If asked, allow Xcode to manage signing automatically.

> If you don’t have a paid Apple Developer account, you can still install to a device with a free Apple ID, but the app will need to be re-signed every 7 days.

### 3) Run on your iPhone

1. Connect your iPhone to your Mac with a USB-C/Lightning cable (or enable Wireless Debugging in Xcode if preferred).
2. In Xcode’s toolbar, choose your iPhone as the run destination.
3. Click **Run** (▶︎) to build and install.

### 4) Trust the developer profile (first-time only)

On your iPhone:

1. Open **Settings → General → VPN & Device Management**.
2. Tap the developer profile and choose **Trust**.

The app will now launch from your Home Screen.

## Notes

- The deployment target is set to iOS 16.0.
- You can customize the app name, icon, or bundle identifier in the Xcode project settings.
