# No Mas!

**No Meeting Auto-Accept** - A macOS menu bar app that syncs busy time blocks across multiple calendars. Perfect for managing multiple work accounts where third-party calendar sync tools are blocked by enterprise policies.

## Features

- 🔄 **Bidirectional Sync** - Events from any enabled calendar create "busy" blocks on all other calendars
- 🔒 **Privacy-First** - Only syncs time blocks, not event details or attendees
- 🚫 **No Cloud Required** - Runs entirely locally on your Mac
- ⏰ **Automatic Sync** - Configurable sync interval (1-30 minutes)
- 📅 **Works with Enterprise Accounts** - Uses macOS native calendar integration
- 🔔 **Notifications** - Get notified when sync completes
- 🚀 **Launch at Login** - Optionally start with macOS
- 🔢 **Pending Changes Badge** - See how many changes are pending before sync
- 🔁 **Smart Recurring Events** - Recurring events sync as a single series, not individual blocks
- 👁️ **Agenda Glimpse** - Quick view of today's schedule with a single click
- ⏱️ **Meeting Time Tracker** - See your total meeting time for today and this week

## How It Works

1. No Mas! reads events from all your enabled calendars via macOS Calendar.app
2. For each event in Calendar A, it creates a "Busy - Calendar A" block in Calendar B, C, etc.
3. Blocks are tagged with hidden markers to prevent sync loops
4. When events are deleted or changed, corresponding blocks are updated automatically

### Menu Bar Interactions

- **Left-click** the menu bar icon to open the Agenda Glimpse view
- **Right-click** the menu bar icon to access settings, sync controls, and calendar management

### Agenda Glimpse

The Agenda Glimpse provides a compact timeline view of your day:

- **Day Navigation** - Browse through your calendar with previous/next day buttons, or jump to today
- **Timeline View** - See your events laid out on a 24-hour timeline
- **Calendar Colors** - Events are color-coded to match their source calendar
- **Tentative Events** - Shown with a striped pattern to distinguish from confirmed meetings
- **Current Time Indicator** - A red "now" line shows the current time when viewing today
- **Overlapping Events** - Displayed side-by-side when multiple events overlap
- **Smart Locations** - Virtual meeting URLs (Teams, Zoom, Meet, etc.) are displayed as "Online"
- **All-Day Toggle** - Show or hide all-day events with a single click

### Meeting Time Tracker

At the top of the Agenda Glimpse, you'll see:
- **Today's meeting time** - Total hours and minutes scheduled for the day
- **This week's meeting time** - Total time spent in meetings this week

Example: `2h 30m today · 12h 45m this week`

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode Command Line Tools (for building)
- Your calendar accounts added to macOS Calendar.app

## Installation

### Install via Homebrew (Recommended)

```bash
# Add the No Mas! tap
brew tap disbergconsultancy/nomas

# Install No Mas!
brew install --cask nomas
```

That's it! No Mas! will be installed to `/Applications/NoMas.app`.

### Build from Source

```bash
# Clone the repository
git clone https://github.com/disbergconsultancy/NO-MAS.git
cd NO-MAS

# Install to /Applications
make install
```

The app will be built and installed to `/Applications/NoMas.app`.

### Other Make Commands

```bash
make build      # Build the app bundle only
make install    # Build and install to /Applications
make uninstall  # Remove from /Applications
make run        # Build and run the app directly
make clean      # Remove build artifacts
make release    # Create a release package (VERSION=x.x.x)
make help       # Show available commands
```

### Manual Build

If you prefer to build manually:

```bash
# Make the build script executable
chmod +x scripts/build.sh

# Build the app
./scripts/build.sh

# Install to Applications
cp -r .build/release/NoMas.app /Applications/
```

## Setup

1. **Add your calendar accounts to macOS Calendar.app**
   - Open System Settings > Internet Accounts
   - Add your Microsoft 365, Google, or other calendar accounts
   - Make sure calendars are visible in the Calendar.app

2. **Launch No Mas!**
   - Double-click NoMas.app or launch from Applications
   - Grant calendar access when prompted

3. **Configure calendars**
   - Right-click the hand icon in the menu bar
   - Go to Calendars submenu
   - Enable/disable calendars as needed

4. **Adjust settings (optional)**
   - Right-click and select Settings... in the menu
   - Configure sync interval, block title format, etc.

## Configuration

### Settings

| Setting | Description | Default |
|---------|-------------|---------|
| Sync Interval | How often to check for changes | 5 minutes |
| Sync Window | How far ahead to sync | 14 days |
| Block Title Format | Format for busy blocks | `Busy - {source_name}` |
| Sync All-Day Events | Include all-day events | Off |
| Sync Recurring as Series | Sync recurring events as a single series instead of individual blocks | On |
| Show Notifications | Notify on sync completion | On |
| Launch at Login | Start No Mas! with macOS | Off |
| Hide All-Day Events | Hide all-day events in Agenda Glimpse | Off |

### Block Title Format

Use `{source_name}` placeholder for the source calendar/account name:
- `Busy - {source_name}` → "Busy - Work Account"
- `[{source_name}] Blocked` → "[Client A] Blocked"
- `🚫 {source_name}` → "🚫 Personal Calendar"

## How Sync Loop Prevention Works

No Mas! prevents infinite sync loops by embedding a hidden marker in each created block:

```
<!-- NOMAS:BLOCK:source=calendar_id:id=event_id -->
```

When scanning calendars, any event containing this marker is recognized as a synced block and ignored, ensuring only "real" events trigger new blocks.

## Troubleshooting

### "App is damaged" or "cannot be opened"

No Mas! is not notarized by Apple (notarization requires an Apple Developer account). macOS Gatekeeper may show a warning when opening the app.

**Fix:** Remove the quarantine attribute:

```bash
xattr -cr /Applications/NoMas.app
```

Then try opening the app again. This is safe - the app is ad-hoc code signed and runs entirely locally.

### "No calendars found"

- Make sure calendar accounts are added in System Settings > Internet Accounts
- Ensure No Mas! has calendar access in System Settings > Privacy & Security > Calendars
- Try quitting and reopening No Mas!

### Blocks not appearing

- Check that at least 2 calendars are enabled in the Calendars submenu
- Verify the source calendar has events within the sync window
- Click "Sync Now" to trigger an immediate sync
- Check View Logs for any errors

### Enterprise account issues

No Mas! uses macOS's native calendar integration, which typically works even when third-party apps are blocked. If your enterprise blocks all calendar access:
1. Verify you can see the calendar in macOS Calendar.app
2. Make sure the calendar allows modifications (read-only calendars cannot receive blocks)

### Performance

No Mas! is lightweight and efficient:
- Runs entirely in the menu bar (no dock icon)
- Only syncs when needed
- Uses macOS EventKit for efficient calendar access

## Development

### Project Structure

```
NO-MAS/
├── Package.swift                 # Swift Package manifest
├── Sources/NoMas/
│   ├── CalSyncApp.swift         # App entry point
│   ├── AppDelegate.swift        # Menu bar setup
│   ├── Services/
│   │   └── SyncEngine.swift     # Core sync logic
│   ├── Models/
│   │   └── Settings.swift       # App settings
│   ├── Views/
│   │   ├── SettingsView.swift   # Settings UI
│   │   └── TodayAgendaView.swift # Agenda Glimpse view
│   ├── Utils/
│   │   └── Logger.swift         # Logging utility
│   └── Resources/
│       └── Info.plist           # App metadata
├── Sources/NoMasCore/
│   ├── BlockMarker.swift        # Sync block marker utilities
│   └── SyncLogic.swift          # Core sync logic
├── scripts/
│   └── build.sh                 # Build script
└── README.md
```

### Building for Development

```bash
# Build debug version
swift build

# Run directly (without app bundle)
swift run NoMas

# Build release version
swift build -c release
```

### Dependencies

- [LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern) - Launch at login functionality

## Privacy

No Mas!:
- ✅ Runs entirely locally on your Mac
- ✅ Does not send any data to external servers
- ✅ Only creates "Busy" blocks (no event details copied)
- ✅ Stores settings in local UserDefaults
- ✅ Logs stored locally in `~/Library/Application Support/NoMas/`

## License

MIT License - See LICENSE file for details.

## Contributing

Contributions welcome! Please open an issue or submit a pull request on [GitHub](https://github.com/disbergconsultancy/NO-MAS).

## Acknowledgments

- Built with Swift and SwiftUI
- Uses Apple's EventKit framework
- Inspired by the need to manage multiple enterprise calendars without enterprise-approved tools
