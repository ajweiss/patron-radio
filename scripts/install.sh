#!/bin/bash

# Patron Radio - Installation Script
# This script builds and installs the Patron Radio Plasmoid for Plasma 6.

set -e # Exit on error

echo "--- Patron Radio: Installation Started ---"

# 1. Prepare Build Directory
if [ -d "build" ]; then
    echo "Cleaning old build directory..."
    rm -rf build
fi
mkdir build
cd build

# 2. Configure and Compile
# Install into the user's home so no root is needed; plasmashell picks up
# plasmoids from ~/.local/share/plasma/plasmoids.
echo "Configuring project with CMake..."
cmake .. -DCMAKE_INSTALL_PREFIX="$HOME/.local"

echo "Building C++ plugin..."
make -j$(nproc)

# 3. Install
echo "Installing files to local user directory..."
make install

# 4. Restart Plasma
echo "Restarting Plasma shell..."
systemctl --user restart plasma-plasmashell

echo "--- Installation Complete! ---"
echo "You can now add 'Patron Radio' from your Plasma widget menu."
