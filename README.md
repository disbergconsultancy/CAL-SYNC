# CalSync

A macOS menu bar app that syncs busy time blocks across multiple calendars. Perfect for managing multiple work accounts where third-party calendar sync tools are blocked by enterprise policies.

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

## How It Works

1. CalSync reads events from all your enabled calendars via macOS Calendar.app
2. For each event in Calendar A, it creates a "Busy - Calendar A" block in Calendar B, C, etc.
3. Blocks are tagged with hidden markers to prevent sync loops
4. When events are deleted or changed, corresponding blocks are updated automatically

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode Command Line Tools (for building)
- Your calendar accounts added to macOS Calendar.app

## Installation

### Quick Install (Recommended)

```bash
# Clone the repository
git clone <repo-url>
cd CAL-SYNC

# Install to /Applications
make install
```

That's it! The app will be built and installed to `/Applications/CalSync.app`.

### Other Make Commands

```bash
make build      # Build the app bundle only
make install    # Build and install to /Applications
make uninstall  # Remove from /Applications
make run        # Build and run the app directly
make clean      # Remove build artifacts
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
cp -r .build/release/CalSync.app /Applications/
```

## Setup

1. **Add your calendar accounts to macOS Calendar.app**
   - Open System Settings > Internet Accounts
   - Add your Microsoft 365, Google, or other calendar accounts
   - Make sure calendars are visible in the Calendar.app

2. **Launch CalSync**
   - Double-click CalSync.app or launch from Applications
   - Grant calendar access when prompted

3. **Configure calendars**
   - Click the calendar icon in the menu bar
   - Go to Calendars submenu
   - Enable/disable calendars as needed

4. **Adjust settings (optional)**
   - Click Settings... in the menu
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
| Launch at Login | Start CalSync with macOS | Off |

### Block Title Format

Use `{source_name}` placeholder for the source calendar/account name:
- `Busy - {source_name}` → "Busy - Work Account"
- `[{source_name}] Blocked` → "[Client A] Blocked"
- `🚫 {source_name}` → "🚫 Personal Calendar"

## How Sync Loop Prevention Works

CalSync prevents infinite sync loops by embedding a hidden marker in each created block:

```
<!-- CALSYNC:BLOCK:source=calendar_id:id=event_id -->
```

When scanning calendars, any event containing this marker is recognized as a synced block and ignored, ensuring only "real" events trigger new blocks.

## Troubleshooting

### "No calendars found"

- Make sure calendar accounts are added in System Settings > Internet Accounts
- Ensure CalSync has calendar access in System Settings > Privacy & Security > Calendars
- Try quitting and reopening CalSync

### Blocks not appearing

- Check that at least 2 calendars are enabled in the Calendars submenu
- Verify the source calendar has events within the sync window
- Click "Sync Now" to trigger an immediate sync
- Check View Logs for any errors

### Enterprise account issues

CalSync uses macOS's native calendar integration, which typically works even when third-party apps are blocked. If your enterprise blocks all calendar access:
1. Verify you can see the calendar in macOS Calendar.app
2. Make sure the calendar allows modifications (read-only calendars cannot receive blocks)

### Performance

CalSync is lightweight and efficient:
- Runs entirely in the menu bar (no dock icon)
- Only syncs when needed
- Uses macOS EventKit for efficient calendar access

## Development

### Project Structure

```
CAL-SYNC/
├── Package.swift                 # Swift Package manifest
├── Sources/CalSync/
│   ├── CalSyncApp.swift         # App entry point
│   ├── AppDelegate.swift        # Menu bar setup
│   ├── Services/
│   │   └── SyncEngine.swift     # Core sync logic
│   ├── Models/
│   │   └── Settings.swift       # App settings
│   ├── Views/
│   │   └── SettingsView.swift   # Settings UI
│   ├── Utils/
│   │   └── Logger.swift         # Logging utility
│   └── Resources/
│       └── Info.plist           # App metadata
├── scripts/
│   └── build.sh                 # Build script
└── README.md
```

### Building for Development

```bash
# Build debug version
swift build

# Run directly (without app bundle)
swift run CalSync

# Build release version
swift build -c release
```

### Dependencies

- [LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern) - Launch at login functionality

## Privacy

CalSync:
- ✅ Runs entirely locally on your Mac
- ✅ Does not send any data to external servers
- ✅ Only creates "Busy" blocks (no event details copied)
- ✅ Stores settings in local UserDefaults
- ✅ Logs stored locally in ~/Library/Application Support/CalSync/

## License

MIT License - See LICENSE file for details.

## Contributing

Contributions welcome! Please open an issue or submit a pull request.

## Acknowledgments

- Built with Swift and SwiftUI
- Uses Apple's EventKit framework
- Inspired by the need to manage multiple enterprise calendars without enterprise-approved tools
