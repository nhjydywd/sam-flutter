# sam-flutter

Local image segmentation with a Python server and a Flutter desktop client (macOS/Windows).

![Preview](doc/image.png)

## Start the Server

macOS:

```bash
cd server
./launch.sh
```

Windows (PowerShell):

```bash
cd server
.\launch.ps1
```

## Start the Client

macOS:

```bash
cd gui
flutter run -d macos
```

Windows:

```bash
cd gui
flutter run -d windows
```

## Manage Models

```bash
cd server
python3 manage_model.py
```
