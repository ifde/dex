#!/bin/bash

# 1. Ensure Git is initialized
[ -d .git ] || git init

# 2. Extract URLs and Paths from your .gitmodules file and force-register them
echo "Parsing .gitmodules and registering submodules..."

# This loop finds 'path' and 'url' lines and runs 'git submodule add'
grep -E 'path = |url = ' .gitmodules | awk '{print $3}' | while read -r PATH_VAL; read -r URL_VAL; do
    echo "Processing $PATH_VAL from $URL_VAL..."
    
    # Remove the folder if it exists so git can re-register it
    rm -rf "$PATH_VAL"
    
    # Force add the submodule with the absolute URL
    git submodule add -f "$URL_VAL" "$PATH_VAL"
done

# 3. Synchronize to the exact commits in foundry.lock
echo "----------------------------------------"
echo "Syncing to foundry.lock revisions..."
git submodule update --init --recursive
forge install --no-commit

echo "Done. Check your 'lib/' folder."