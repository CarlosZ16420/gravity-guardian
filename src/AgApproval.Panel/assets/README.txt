Shield V2 / App & Tray Icons

App icon (white continuous-corner squircle tile, transparent outside the tile):
- icon.svg: editable vector master.
- icon-small.svg: optical-size vector for 16-32 px.
- icon.ico: Windows multi-resolution icon (16, 20, 24, 32, 40, 48, 64, 128, 256 px).
- resource.rc embeds icon.ico as IDI_APP_ICON (101) for Explorer, desktop shortcuts, taskbar, and Alt+Tab.

Tray & in-app brand icon (transparent central star and background):
- icon-tray.svg: editable vector master.
- icon-tray-small.svg: optical-size vector for 16-32 px.
- icon-tray.ico: Windows multi-resolution icon (16, 20, 24, 32, 40, 48, 64, 128, 256 px).
- resource.rc embeds icon-tray.ico as IDI_TRAY_ICON (103) for the system tray and in-app panel header.
- In-app header keeps original colors; tray icon reflects runtime state (color when active, grayscale when disabled or stopped, preserving original alpha).
