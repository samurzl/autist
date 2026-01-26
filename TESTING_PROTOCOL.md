# Two-List Todo Testing Protocol

This protocol covers comprehensive manual and build verification for the iOS (iPhone) target.

It focuses on the functional flows implemented in the SwiftUI codebase (lists, work areas, subtasks, recurring series, notifications, and persistence). Run the iOS section on a simulator or device.

## 1. Preconditions & setup

### Required tools
- **Xcode** (latest stable recommended).
- An **iPhone simulator** or physical device for iOS testing.

### Suggested test data
Prepare a short set of labels you can reuse:
- Tasks: “Pay rent”, “Fix bug”, “Call plumber”
- Ideas: “Write a blog post”, “Sketch logo”
- Subtasks: “Outline”, “Draft”, “Review”

## 2. Build & launch verification

### iOS build
1. Open `TwoListTodo.xcodeproj` in Xcode.
2. Choose an iPhone simulator or a connected device.
3. Build and run.

**Expected**: App launches to the main view with the segmented tabs for **Tasks List**, **Ideas List**, **Tasks Work**, **Ideas Work**.

## 3. Smoke tests

### 3.1 Tab navigation
1. Tap each segmented tab.

**Expected**: Each tab changes the main content to its corresponding view (Tasks List, Ideas List, Tasks Work, Ideas Work) with no errors.

### 3.2 Add button visibility
1. In **Tasks List** and **Ideas List**, locate the floating **+** button.

**Expected**: Button appears in bottom-right and is tappable.

## 4. Lists workflow (Tasks List and Ideas List)

### 4.1 Add list items
1. Open **Tasks List**.
2. Tap **+**.
3. Enter a title (e.g., “Pay rent”).
4. Adjust priority and optionally enable a due date.
5. Tap **Add**.

Repeat in **Ideas List**.

**Expected**:
- New item appears at the top of the list.
- Title, priority, and due date display correctly.

### 4.2 Cancel add dialog
1. Tap **+** to open the add sheet.
2. Tap **Cancel**.

**Expected**: No new item is created.

### 4.3 Delete list items
1. Swipe left on a list item.
2. Delete it.

**Expected**: Item is removed from the list.

### 4.4 Move item to Work Area
1. Tap the **arrow** button on a list item.

**Expected**: The item disappears from the list and appears in the corresponding **Work** tab.

## 5. Work Area workflow

### 5.1 Work item status
1. Open **Tasks Work**.
2. Locate an item and change its status between **Active** and **On Hold**.

**Expected**:
- Status control updates.
- On Hold items render in a dimmed state.

### 5.2 Expand work item details
1. Tap the chevron to expand the item.

**Expected**: Priority selector, due date toggle, and subtask editor appear.

### 5.3 Priority and due date editing
1. Change priority with the dropdown.
2. Toggle **Has due date** on and set a date.
3. Toggle **Has due date** off.

**Expected**:
- Priority label updates.
- Due date shows when enabled and clears when disabled.

### 5.4 Subtasks
1. Add a subtask (e.g., “Outline”).
2. Toggle its completion.
3. Remove it using the trash icon.

**Expected**:
- Subtask appears in the list.
- Toggle state persists.
- Subtask is removed when deleted.

### 5.5 Backlog (move to list)
1. Tap **Backlog**.

**Expected**: Item leaves the work area and returns to the original list with no status set.

### 5.6 Complete workflow
1. Tap **Complete** on a work item.

**Expected**: Item moves to the **Graveyard** (via the Work Area menu).

### 5.7 Graveyard restore & delete
1. Open the **Work Area** menu (ellipsis icon).
2. Open **Graveyard**.
3. Restore an item.
4. Delete another item.

**Expected**:
- Restored item returns to the active work area.
- Deleted item is removed permanently.

## 6. Recurring series workflow

### 6.1 Add a recurring series
1. Open **Work Area** menu → **Recurring series**.
2. Tap **Add recurring series**.
3. Fill title and choose **Every X Days**.
4. Tap **Add**.

**Expected**:
- The series appears in the recurring list.
- A work item is generated immediately for the series.

### 6.2 Weekly recurring series
1. Add another recurring series with **Weekly** frequency.
2. Select at least one weekday.
3. Tap **Add**.

**Expected**: Series appears with the weekly schedule description.

### 6.3 Deleting a recurring series
1. Delete a series entry in the recurring list.

**Expected**: Series is removed.

### 6.4 Duplicate prevention + reminder behavior
1. Ensure a recurring-series-generated item remains active.
2. Wait until the next occurrence (use device time adjustments if needed).

**Expected**:
- No duplicate work item is created.
- A reminder notification is scheduled instead.

## 7. Notifications

### 7.1 Permission prompt
1. Fresh install the app.
2. Launch it.

**Expected**: The notification permission prompt appears.

### 7.2 Daily reminders
1. Accept permission.
2. Inspect scheduled notifications (via Xcode console or iOS settings).

**Expected**:
- Daily reminders at **6:00 AM** and **9:00 PM** are scheduled.

### 7.3 Recurring-series reminder
1. Keep a recurring item active beyond its next schedule (from section 6.4).

**Expected**: Notification appears stating a recurring item is still active.

## 8. Persistence

### 8.1 Local persistence
1. Add tasks, ideas, work items, and subtasks.
2. Close and relaunch the app.

**Expected**: All data persists across restarts.

## 9. UI & accessibility checks

### 9.1 Labels and controls
1. Verify **Add** buttons announce as “Add Tasks/Ideas”.
2. Verify **Work area options** menu accessibility label.

**Expected**: Accessibility labels are present and descriptive.

### 9.2 Empty state messaging
1. Ensure empty lists show “No active tasks” / “No recurring series” / “No completed tasks”.

**Expected**: Clear empty state messaging renders in each section.

## 10. Regression checklist (quick sanity run)

Use this as a quick final pass after changes:
- Launch app, add a task, move to work area, complete it, restore it from graveyard.
- Add a recurring series and confirm item generation.
- Toggle status and due date.
- Relaunch and confirm data persistence.

## 11. Reporting

For any failure, capture:
- App version/commit.
- Platform (iOS) and OS version.
- Steps to reproduce.
- Expected vs. actual result.
- Screenshot or screen recording when possible.
