# sam-flutter (GUI)

Desktop GUI for the SAM2 HTTP server in `../server/`.

Supported platforms in this repo:
- macOS
- Windows

## Run

1) Start the server (repo root):

```bash
./server/launch.sh
```

2) Run the Flutter app (from `gui/`):

```bash
flutter run -d macos
```

Notes (macOS):
- This app enables App Sandbox and adds the network client entitlement, and allows HTTP loads via `NSAppTransportSecurity` so it can talk to the local/LAN server during development.

In the app:
- Click `Connect`
- Click `New Session`
- Enter an image folder path and click `Load Folder`
- Click an image to upload it to the server
- Click on the image to segment (FG/BG toggle in the right panel)

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
