# chuckit

Thank you so much for taking a look at one of my first PUBLIC projects.

I believe everyone has the right to fully remove software they no longer want. Too often, deleted apps leave pieces of themselves scattered across your system, lingering like something you never invited in. Chuckit exists to change that: when you decide an app is gone, it should be gone …… completely gone. Please enjoy it, and let me know what you think.

All I ask in return: chuckit is free for you to use and enjoy, but please do not copy, redistribute, or sell it, in whole or in part, without my written permission. See the LICENSE file for the full terms.

## What it does

Drag any app onto the can and chuckit investigates: it scans the standard application-data folders (Application Support, Preferences, Caches, Logs, Saved Application State, LaunchAgents, Containers, Group Containers, and more) for files belonging to that app. A wider scan mode searches additional folders on the internal startup drive, including hidden files. File attribution is based on matching evidence; review every candidate. Chuckit cannot guarantee that it will find every leftover.

## Safety first

- Every removal starts with a review screen. Identifier matches come pre-selected; name-only matches and shared data are left for you to judge. Uncheck anything you want to keep.
- The Move to Trash button stays disabled until you check the review acknowledgment, and the acknowledgment resets on every attempt.
- Chuckit moves items to macOS Trash. It never permanently deletes anything and never empties Trash. Anything chucked can be recovered with Put Back.
- A move is reported as successful when its original location is gone and a destination in Trash is confirmed. If selected leftover files fail, the main app is kept in place.
- It only works on your internal startup drive. External drives and network volumes are excluded.

## Requirements

- macOS 27.0 or later (current deployment target)
- Xcode 27.0 or later to build
- Full Disk Access (optional but recommended): lets chuckit find leftovers in protected app data. You can skip it; some files may be missed.
- Finder automation permission and possibly administrator approval, which macOS handles. Chuckit never asks for or touches your password.

## Building

Open `chuckit.xcodeproj` in Xcode and run the chuckit scheme. Select your own signing team for distribution builds. The `chuckit/` folder contains the application source and resources.

## Project layout

```text
chuckit.xcodeproj/    Xcode project and shared build scheme
chuckit/             Application source, assets and bundled instructions
ChuckitWidget/       Widget extension source and assets
Tests/               Regression suite and runner
DEVELOPMENT.md       RFO2 workflow notes and file map
ChuckitInfo.plist     Application configuration
Chuckit.entitlements Application entitlements
README.md            Project documentation
LICENSE              Usage terms
```

Application and widget asset catalogs and configuration files serve separate targets. Each application Swift source has one canonical copy.

## Tests

Run `bash Tests/run-tests.sh` from the repository root, or supply a writable output path. Tests use disposable fixtures and never uninstall real applications.

## Developer notes

Read [How Chuckit is built](DEVELOPMENT.md) for the workflow, file map, thread boundaries, animation and testing notes signed **RFO2**.

## License

Free to download and use. Selling it, redistributing it, or reusing any of its code requires my written permission. See LICENSE for the full terms.
