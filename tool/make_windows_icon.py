"""Builds the Windows app icon (windows/runner/resources/app_icon.ico) from assets/icon/icon.png.

Every standard size is resampled from the full image, so the title bar and taskbar icons stay sharp; an .ico
holding only 256 px (what flutter_launcher_icons makes) is scaled down roughly by Windows.

Run from the project root: python tool/make_windows_icon.py
"""
from PIL import Image

sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
Image.open('assets/icon/icon.png').convert('RGBA').save(
    'windows/runner/resources/app_icon.ico', sizes=[(s, s) for s in sizes]
)
