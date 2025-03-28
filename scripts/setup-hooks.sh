#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Create .git/hooks directory if it doesn't exist
mkdir -p .git/hooks

# Copy the pre-commit hook
cp "$SCRIPT_DIR/pre-commit" .git/hooks/
chmod +x .git/hooks/pre-commit

echo "Git hooks installed successfully!" 
