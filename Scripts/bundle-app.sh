#!/usr/bin/env bash
#
# Ad-hoc signing means macOS may ask for folder access again after a rebuild,
# because TCC permissions are keyed to the app's signing identity.

set -euo pipefail

RUN_APP=false
SYNTHETIC_SCANNER=false

for argument in "$@"; do
    case "$argument" in
        --run)
            RUN_APP=true
            ;;
        --synthetic)
            # The simulated page source still writes real JPEG masters, so crop
            # analysis, margin verdicts, and atomic publication all run for
            # real. This is how to exercise the whole workflow without an
            # fi-8170, and how to reproduce a UI bug without feeding a card.
            SYNTHETIC_SCANNER=true
            RUN_APP=true
            ;;
        *)
            echo "Usage: $0 [--run] [--synthetic]" >&2
            exit 64
            ;;
    esac
done

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$REPOSITORY_ROOT/.build/ScanDeck.app"
CONTENTS_PATH="$APP_PATH/Contents"

cd "$REPOSITORY_ROOT"
swift build -c release --product ScanDeck
BINARY_PATH="$(swift build -c release --show-bin-path)/ScanDeck"

rm -rf "$APP_PATH"
mkdir -p "$CONTENTS_PATH/MacOS" "$CONTENTS_PATH/Resources"
cp "$BINARY_PATH" "$CONTENTS_PATH/MacOS/ScanDeck"
cp "$REPOSITORY_ROOT/Resources/ScanDeck-Info.plist" "$CONTENTS_PATH/Info.plist"
cp "$REPOSITORY_ROOT/Resources/ScanDeck.icns" "$CONTENTS_PATH/Resources/ScanDeck.icns"

# TICKET-034's implementation is private operator tooling: it is deliberately
# ignored by Git, but the local app bundle still needs a stable, direct path to
# it. A public clone remains buildable without the file; only Check Centering is
# unavailable in that case, and the app explains that if the button is pressed.
CENTERING_TOOL_PATH="$REPOSITORY_ROOT/centering/centering_check.py"
if [[ -f "$CENTERING_TOOL_PATH" ]]; then
    mkdir -p "$CONTENTS_PATH/Resources/Centering"
    cp "$CENTERING_TOOL_PATH" \
        "$CONTENTS_PATH/Resources/Centering/centering_check.py"
else
    echo "Warning: private centering tool is absent; Check Centering is unavailable." >&2
fi

codesign --force --sign - "$APP_PATH"

echo "Bundle: $APP_PATH"
echo "Launch: open \"$APP_PATH\""

if [[ $RUN_APP == true ]]; then
    if [[ $SYNTHETIC_SCANNER == true ]]; then
        echo "Page source: synthetic (the scanner is not touched)"
        open "$APP_PATH" --env SCANDECK_SYNTHETIC_SCANNER=1
    else
        open "$APP_PATH"
    fi
fi
