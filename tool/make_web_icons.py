"""Builds the web app's icons (web/favicon.png and web/icons/) from assets/icon/icon.png.

Run from the project root: python tool/make_web_icons.py
"""
from PIL import Image

icon = Image.open('assets/icon/icon.png').convert('RGB')


def save(size, path):
    icon.resize((size, size), Image.LANCZOS).save(path, optimize=True)


save(32, 'web/favicon.png')
for size in (192, 512):
    save(size, f'web/icons/Icon-{size}.png')
    # The icon fills its square edge to edge, so it can be cropped to any shape as it is.
    save(size, f'web/icons/Icon-maskable-{size}.png')
