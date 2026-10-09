#!/bin/bash
# Clean export script — copies project to Windows, runs import, exports, zips
SRC="/home/joep/dev/growing-guns"
DST="/mnt/c/Users/Gebruiker/Downloads/growing-guns-export"

rm -rf "$DST/.godot"
rsync -a --delete "$SRC/" "$DST/" 2>/dev/null
echo "Copied to $DST"

cat > "$DST/export.bat" << 'BATEND'
@echo off
echo Reimporting assets...
C:\Users\Gebruiker\Downloads\godot_bin\Godot_v4.6.2-stable_win64_console.exe --headless --import --path C:\Users\Gebruiker\Downloads\growing-guns-export 2>nul
echo Exporting...
mkdir C:\Users\Gebruiker\Downloads\growing-guns-export\build\windows 2>nul
del C:\Users\Gebruiker\Downloads\growing-guns-export\build\windows\MoreRounds.exe 2>nul
del C:\Users\Gebruiker\Downloads\growing-guns-export\build\windows\MoreRounds.pck 2>nul
C:\Users\Gebruiker\Downloads\godot_bin\Godot_v4.6.2-stable_win64_console.exe --path C:\Users\Gebruiker\Downloads\growing-guns-export --export-release "Windows LAN" C:\Users\Gebruiker\Downloads\growing-guns-export\build\windows\MoreRounds.exe 2>nul
echo Zipping...
del C:\Users\Gebruiker\Downloads\growing-guns-export\build\windows\MoreRounds.zip 2>nul
C:\Windows\System32\tar.exe -acf C:\Users\Gebruiker\Downloads\growing-guns-export\build\windows\MoreRounds.zip -C C:\Users\Gebruiker\Downloads\growing-guns-export\build\windows MoreRounds.exe MoreRounds.pck godot_iroh.dll
echo Done!
BATEND

cd /mnt/c/Users/Gebruiker/Downloads/growing-guns-export && cmd.exe /c "export.bat"
echo "Export complete!"

# Single shareable file: exe + pck + dll are zipped together so they can never
# get separated (a lost .pck = the "no assets" bug). Copy it back to the repo.
ZIP="$DST/build/windows/MoreRounds.zip"
if [ ! -f "$ZIP" ]; then
    echo "ERROR: build produced no $ZIP" >&2
    exit 1
fi
cp -f "$ZIP" "$SRC/MoreRounds.zip"
echo "Single-file build: $SRC/MoreRounds.zip ($(du -h "$SRC/MoreRounds.zip" | cut -f1))"

# Push it to your friend over P2P. Prints a ticket and stays running until they
# finish downloading. Friend runs:  sendme receive <ticket>  then unzips + runs.
echo "Sharing with sendme — send the ticket below to your friend:"
exec "$SRC/sendme" send "$SRC/MoreRounds.zip"
