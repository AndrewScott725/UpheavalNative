#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

TARGET_GODOT_API="4.7"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

printf '\nUpheaval native crowd builder for Godot 4.7.2\n'
printf 'Target GDExtension API: %s\n\n' "$TARGET_GODOT_API"

# Apple compiler / SDK
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Apple Command Line Tools are required."
  echo "Run: xcode-select --install"
  echo "Then rerun this BUILD_MAC.command."
  exit 1
fi

# Required command-line tools
if ! command -v git >/dev/null 2>&1; then
  echo "git is required and is normally installed with Apple Command Line Tools."
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required. Install Python 3, then rerun this script."
  exit 1
fi

# Prefer an existing SCons. If absent, try a user-local Python install.
if ! command -v scons >/dev/null 2>&1; then
  echo "SCons was not found. Attempting a user-local install..."
  if ! python3 -m pip install --user scons; then
    echo
    echo "Automatic SCons installation failed."
    echo "If you use Homebrew, run: brew install scons"
    echo "Then rerun this BUILD_MAC.command."
    exit 1
  fi
  export PATH="$HOME/Library/Python/3.13/bin:$HOME/Library/Python/3.12/bin:$HOME/Library/Python/3.11/bin:$HOME/Library/Python/3.10/bin:$HOME/Library/Python/3.9/bin:$HOME/.local/bin:$PATH"
fi

if ! command -v scons >/dev/null 2>&1; then
  echo "SCons still is not on PATH."
  echo "Install it with: brew install scons"
  exit 1
fi

# Use current godot-cpp and explicitly target the Godot 4.7 extension API.
# Reclone if this folder came from the older 4.2-targeted Upheaval package.
if [ -d godot-cpp ]; then
  echo "Removing existing godot-cpp checkout so the 4.7 API build is clean..."
  rm -rf godot-cpp
fi

echo "Downloading godot-cpp..."
git clone --depth 1 https://github.com/godotengine/godot-cpp.git godot-cpp

echo
echo "Building Upheaval crowd extension (Godot 4.7 API, universal macOS, debug)..."
scons platform=macos arch=universal target=template_debug api_version="$TARGET_GODOT_API" -j"$JOBS"

echo
echo "Building Upheaval crowd extension (Godot 4.7 API, universal macOS, release)..."
scons platform=macos arch=universal target=template_release api_version="$TARGET_GODOT_API" -j"$JOBS"

DEBUG_LIB="bin/libupheaval_crowd.macos.template_debug.universal.dylib"
RELEASE_LIB="bin/libupheaval_crowd.macos.template_release.universal.dylib"

if [ ! -f "$DEBUG_LIB" ] || [ ! -f "$RELEASE_LIB" ]; then
  echo
  echo "Build completed but the expected universal dylibs were not found:"
  echo "  $DEBUG_LIB"
  echo "  $RELEASE_LIB"
  echo "Check the SCons output above before opening Godot."
  exit 1
fi

# Activate only after both libraries exist, so Godot never sees a half-built
# extension descriptor.
cp -f upheaval_crowd.gdextension.disabled upheaval_crowd.gdextension

echo
echo "SUCCESS: Native Upheaval crowd solver built for Godot 4.7.x."
echo "Debug library:   $DEBUG_LIB"
echo "Release library: $RELEASE_LIB"
echo
echo "Now fully quit and reopen Godot 4.7.2, open this project, and run it."
echo "In Godot Output, confirm you see:"
echo "  Upheaval crowd backend: native C++ spatial hash"
echo
read -r -p "Press Return to close this window..." _
