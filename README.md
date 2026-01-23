# Two-List Todo (iPhone)

This repository contains a native iPhone app built with SwiftUI. It provides two list inboxes (Tasks and Ideas) and two work areas so you can intentionally choose what you are focusing on today.

## What the app does

### Tabs (top segmented control)
- **Tasks List** and **Ideas List** show *all* items in each list.
- **Tasks Work** and **Ideas Work** are dedicated areas for the items you are actively working on.

### Lists
- Each list is a simple catalog of all items.
- A floating **Add** button in the bottom-right opens a dialog to set the item title, priority, and optional due date.
- Each list item has a left-hand button that sends it to the matching work area.

### Work areas
- Items in a work area have a **status picker** (Active / Waiting / Done) and a **Complete** button.
- Completing a task sends it to the **Task Graveyard** (inside the same work area tab).
- The Task Graveyard lets you restore a completed item back to the active work area.

### Recurring tasks
- In each work area you can add **recurring series** (e.g., “every 2 days” or “weekly on Monday”).
- When a series becomes due, the app adds a task to the work area.
- If the previous instance from the same series is still active, the app skips the duplicate and sends a reminder notification instead.

### Push notifications
- Two daily reminders are scheduled:
  - **6:00 AM** (morning)
  - **9:00 PM** (evening)
- These notifications remind you to review whether the work-area items are correct for the day ahead.

> **Note:** Notifications require user permission the first time the app launches.

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

## Build and install the macOS app (Xcode on macOS)

### 1) Open the project

1. On your Mac, open **Xcode**.
2. Choose **File → Open...** and select `TwoListTodo.xcodeproj` from this repo.

### 2) Choose the macOS destination

1. In Xcode’s toolbar, open the run destination menu.
2. Select **My Mac** (native macOS) or **Mac Catalyst** if that is the available option.

### 3) Build and run locally

1. Click **Run** (▶︎) to build and launch the app on your Mac.
2. The app will open like any other macOS app and can be quit from the menu bar.

### 4) Create a distributable app (optional)

1. Choose **Product → Archive** in Xcode.
2. When the Organizer opens, select the latest archive and click **Distribute App**.
3. Follow the prompts to export a signed `.app` or package for distribution.

## Notes

- The deployment target is set to iOS 16.0.
- You can customize the app name, icon, or bundle identifier in the Xcode project settings.
