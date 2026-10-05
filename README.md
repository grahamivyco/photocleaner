# Shoebox

A Mac app for going through your Photos library one month at a time. Right arrow keeps, left arrow tosses. Nothing is deleted until you confirm at the end of the month, and deleted items go to Recently Deleted in Photos for 30 days.

Runs entirely on your Mac using Apple's PhotoKit. No accounts, no network.

## First run

1. Open Xcode once after it finishes installing. Accept the licence and let it install components.
2. Download this repo: on GitHub, click **Code › Download ZIP**, then double-click the ZIP in Downloads.
3. In the unzipped folder, double-click `Shoebox.xcodeproj`.
4. In the bar at the top of the Xcode window, make sure it says **Shoebox › My Mac**.
5. Press **⌘R**. Xcode builds and opens Shoebox.
6. Click **Open my library**, then **Allow** when macOS asks about Photos.

If Xcode shows a signing error: click **Shoebox** at the top of the left sidebar › **Signing & Capabilities** › set **Signing Certificate** to **Sign to Run Locally**, then press ⌘R again.

## Put it in Applications

1. In Xcode: **Product › Show Build Folder in Finder**.
2. Open `Products › Debug`.
3. Drag `Shoebox.app` into your Applications folder.

## Using it

| Action | Key | Trackpad / mouse |
| --- | --- | --- |
| Keep | → | two-finger swipe right, or drag the photo right |
| Toss (mark for delete) | ← | two-finger swipe left, or drag left |
| Undo last choice | ⌘Z | Undo button |
| Play video or Live Photo | Space | click it |

- Top right shows items left and how much space the tossed items would free.
- Leave mid-month with **Months**. Your choices are saved.
- At the end of a month you see everything you tossed. Click any thumbnail to keep it instead.
- **Move N to Recently Deleted** asks you to confirm, then hands the items to Photos.
- Finished months show a green tick.

## Safety

- Shoebox only reads the library, except for the one confirm step at the end of a month.
- It refuses to work unless `/Volumes/Photos/Photos Library.photoslibrary` exists. If the library moves, change `libraryPath` in `Shoebox/Config.swift`.
- iCloud Photos is on, so tossed items also leave your iPhone and iCloud. They stay recoverable in Recently Deleted for 30 days.
- Progress is stored in `~/Library/Application Support/Shoebox/progress.json`.

## Notes

- The space figure adds up every stored file for an item (original, Live Photo video, edits). It is an estimate of what Photos and iCloud will free.
- After every rebuild in Xcode, macOS may ask for Photos access again. That's normal for apps signed locally.
- `Tools/make_icon.py` redraws the app icon (needs Python and Pillow).
