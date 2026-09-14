#!/usr/bin/env python3
"""web-asset-generator dependency check. Exits 2 with install guidance when Pillow is missing."""
import sys

def main() -> int:
    try:
        import PIL
        from PIL import Image  # noqa: F401
        print(f"OK Pillow {PIL.__version__}")
        return 0
    except ImportError:
        print("MISSING Pillow — install: pip3 install Pillow (or uv pip install Pillow)")
        return 2

if __name__ == "__main__":
    sys.exit(main())
