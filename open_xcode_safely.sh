#!/bin/bash
# Safely open Xcode project without hanging on package resolution

echo "Killing any existing Xcode processes..."
killall Xcode 2>/dev/null
sleep 2

echo "Cleaning caches..."
rm -rf ~/Library/Developer/Xcode/DerivedData/Bitkit-*
rm -rf ~/Library/Caches/com.apple.dt.Xcode/*

echo "Opening Xcode project..."
cd ~/bitkit-ios

# Open Xcode first, then open the project
open -a Xcode
sleep 3

# Now open the project file
open Bitkit.xcodeproj

echo ""
echo "Xcode should open now. Once it's open:"
echo "1. Wait for it to finish loading (don't let it resolve packages yet)"
echo "2. If it asks to resolve packages, click 'Cancel' or 'Skip'"
echo "3. Go to File → Packages → Resolve Package Versions manually"
echo "4. Wait for packages to download"
echo "5. Then build (⌘+B)"

