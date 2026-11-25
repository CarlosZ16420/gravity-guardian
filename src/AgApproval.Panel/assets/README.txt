Shield V2 / Transparent app icon

Imported unchanged from docs/shield-transparent-icons.zip in the parent workspace.
The central star and surrounding background are transparent.

icon.svg: editable vector master.
icon-small.svg: optical-size vector for 16-32 px.
icon.ico: Windows multi-resolution icon (16, 20, 24, 32, 40, 48, 64, 128, 256 px).
resource.rc embeds icon.ico in the Windows panel and packaged launcher.
The panel loads the appropriate small and large icons for the window DPI.
Takeover enabled and service running: original colors.
Takeover disabled, unavailable or service stopped: grayscale generated at runtime,
preserving the original alpha channel and transparency mask.
Update, logging and login notices remain in the tooltip without changing colors.
