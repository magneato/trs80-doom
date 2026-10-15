#!/bin/bash
# ==============================================================================
# setup.sh - TRS-80 Model 4 DOOM development environment (Ubuntu 24.04)
# ==============================================================================
# Installs / checks, all into ./tools (ignored by git):
#   zmac      George Phillips' Z-80 cross-assembler (writes TRS-80 /CMD files and trs80gp symbol files),
#             built from http://48k.ca/zmac.zip
#   trs80gp   George Phillips' TRS-80 emulator: Model 4 ROMs and TRSDOS 6 built in, emulator extensions for
#             tests.  Taken from ~/Downloads/trs80gp-2.5.5.zip if present, else http://48k.ca/trs80gp-2.5.5.zip
#   python3 + Pillow (+ numpy not needed)
#   freedoom  the Freedoom source checkout in ./freedoom (cloned if missing): all game data comes from it (BSD)
# ==============================================================================
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$ROOT/tools"
mkdir -p "$T"
TRS_ZIP_NAME="trs80gp-2.5.5.zip"
TRS_SHA="753787bc4f7937f58bda26438922f26bb67d98c2f4ff182f12c035c1685a41f0"

echo "-- python"
command -v python3 >/dev/null || { echo "python3 is required (sudo apt install python3 python3-pil)"; exit 1; }
python3 -c "import PIL" 2>/dev/null || { echo "Pillow is required (sudo apt install python3-pil)"; exit 1; }

echo "-- zmac"
if [ ! -x "$T/zmac" ]; then
    command -v gcc >/dev/null && command -v g++ >/dev/null && command -v yacc >/dev/null \
        || { echo "gcc, g++ and bison are required (sudo apt install build-essential bison)"; exit 1; }
    rm -rf "$T/zmac-src"; mkdir -p "$T/zmac-src"
    curl -sSL -o "$T/zmac-src/zmac.zip" http://48k.ca/zmac.zip
    (cd "$T/zmac-src" && unzip -q zmac.zip && cd src && make CFLAGS="-std=gnu89 -O2" >/dev/null)   # old-style C: not C23
    cp "$T/zmac-src/src/zmac" "$T/zmac"
fi
echo "   $("$T/zmac" --version 2>&1 | head -1)"

echo "-- trs80gp"
if [ ! -x "$T/trs80gp" ]; then
    Z="$HOME/Downloads/$TRS_ZIP_NAME"
    if [ ! -f "$Z" ]; then
        Z="$T/$TRS_ZIP_NAME"
        curl -sSL -o "$Z" "http://48k.ca/$TRS_ZIP_NAME"
    fi
    echo "$TRS_SHA  $Z" | sha256sum -c --quiet || { echo "unexpected $TRS_ZIP_NAME checksum"; exit 1; }
    rm -rf "$T/trs80gp-dist"; mkdir -p "$T/trs80gp-dist"
    (cd "$T/trs80gp-dist" && unzip -q "$Z")
    case "$(uname -m)" in
        x86_64) cp "$T/trs80gp-dist/linux-64/trs80gp" "$T/trs80gp" ;;
        aarch64) cp "$T/trs80gp-dist/rpi-64/trs80gp" "$T/trs80gp" ;;
        *) cp "$T/trs80gp-dist/linux-32/trs80gp" "$T/trs80gp" ;;
    esac
    chmod +x "$T/trs80gp"
fi
echo "   trs80gp ready"

echo "-- Freedoom"
if [ ! -d "$ROOT/freedoom/levels" ]; then
    command -v git >/dev/null || { echo "git is required (sudo apt install git)"; exit 1; }
    git clone --depth 1 https://github.com/freedoom/freedoom.git "$ROOT/freedoom"
fi
echo "   freedoom: $(git -C "$ROOT/freedoom" log -1 --format='%h %cs' 2>/dev/null || echo present)"
echo "Done.  ./run.sh to play, make test to check."
