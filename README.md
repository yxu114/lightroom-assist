# Lightroom Assist

Two Lightroom Classic plugins for interior and architectural photographers, for the two most repetitive jobs before editing.

- **Bracket Stacker** groups bracketed exposures into stacks by their exposure pattern, not by the time between shots, so long exposures don't break a set. It can also HDR merge each set and colour label the results.
- **Upright Guides** places Guided Upright guides for you. It finds the straight lines in a photo, works out which way is truly up, and draws the guides on real edges. Lightroom still makes the correction, so you can drag any guide that's off.

Both run entirely on your computer. No AI model, no account and no internet connection.

## What you need

- Adobe Lightroom Classic
- [ExifTool](https://exiftool.org), free. Bracket Stacker needs it for Canon brackets, and Upright Guides needs it always.
- Python 3, free, for Upright Guides only. [Download it here](https://www.python.org/downloads/).

Tested on Windows. The macOS paths are in place but haven't been tested yet.

## Install

### 1. Download

Click the green **Code** button at the top of this page, then **Download ZIP**, and unzip it. Inside are two folders, `BracketStacker.lrplugin` and `UprightGuides.lrplugin`. You can install either or both.

### 2. Put the plugins where they'll stay

Lightroom loads a plugin from wherever it sits, so move the folders somewhere permanent first. The easiest place is Lightroom's Modules folder, which loads them automatically.

- **Windows** `%APPDATA%\Adobe\Lightroom\Modules\`. Paste that into the File Explorer address bar. Create the `Modules` folder if it isn't there.
- **macOS** `~/Library/Application Support/Adobe/Lightroom/Modules/`. In Finder, use **Go > Go to Folder**.

### 3. Install ExifTool

- **Windows** download the Windows executable from [exiftool.org](https://exiftool.org), unzip it, and rename `exiftool(-k).exe` to `exiftool.exe`. Create the folder `C:\Program Files\exiftool\` and move `exiftool.exe` into it, with the `exiftool_files` folder beside it if your download has one.
- **macOS** install the macOS package from [exiftool.org](https://exiftool.org), or run `brew install exiftool`.

### 4. Set up Upright Guides

Skip this if you're only using Bracket Stacker.

Upright Guides measures each photo with a small Python program that lives inside the plugin, in its `helper` folder. It needs its own Python packages, installed once.

- **Windows** open `UprightGuides.lrplugin\helper` and double-click `setup.bat`. It takes a minute or two and says **Done** when finished.
- **macOS** in Terminal, run `sh` followed by a space, drag `setup.sh` from the `helper` folder into the window, and press Return.

If you move the plugin later, run the setup again in its new place.

### 5. Turn them on in Lightroom

Restart Lightroom Classic. If you used the Modules folder, the plugins are already loaded. Otherwise go to **File > Plug-in Manager**, click **Add**, and choose each `.lrplugin` folder.

**macOS only** Bracket Stacker sends keyboard shortcuts to Lightroom, so go to **System Settings > Privacy & Security > Accessibility** and turn on Adobe Lightroom Classic.

## Bracket Stacker

### Stack Brackets

**Library > Plug-in Extras > Stack Brackets...**

1. Open the folder or collection that holds your brackets. Smart collections don't work.
2. Clear any Library filter, and expand any existing stacks.
3. Select the photos to stack, or select none to stack everything in view.
4. Check the settings and click **Stack**. Leave the keyboard and mouse alone until it finishes, because it works by sending Lightroom shortcuts. Cancel from the progress bar at the top left.

Options

- **Label bracket photos Yellow** labels every photo in each stacked set. Labels are added at the very end, after the merges are in, because a merged DNG copies its source's label.
- **HDR merge each set** sends Lightroom's HDR merge shortcut, which reuses your last merge settings without a dialog. Run one HDR merge by hand first with the settings you want.
- **Label merged DNGs Blue** waits for the merges to finish, matching each new DNG to its set by name, the set's first frame plus `-HDR`. It labels each one and adds it to the collection you're in. It gives up after 5 minutes without a new DNG and lists any sets still waiting, so you can run Label Brackets once they're done. If you cancel while merges are running, nothing is labelled.
- **Pause per stack** raise this if some sets get skipped on a slower computer.

When it finishes, the summary gives the number of stacks made, the number of photos not in a stack, and any brackets that couldn't be stacked.

### Label Brackets

**Library > Plug-in Extras > Label Brackets...**

For sets you've already stacked or merged. Every stacked photo is labelled Yellow, and every merged HDR DNG, a DNG with `HDR` in its name, is labelled Blue. Nothing is stacked, merged or regrouped.

### How sets are found

Photos are ordered by capture time, then file name, or by file name alone.

- **Exposure order**, such as `− 0 +` with 2 stops between frames. A set is a run of frames whose exposures follow the pattern exactly, whatever the base exposure. Each frame must also start soon after the one before it, within twice that frame's shutter time plus 5 seconds. Anything that doesn't make a full set is left alone and counted as not in a stack. When ExifTool can read a Canon camera's maker notes, only bracketed frames that don't make a full set are listed for checking, and frames shot without bracketing count as single shots. Otherwise, runs of 2 or more unmatched photos are listed.
- **Fixed count** every N photos is a set. It warns if the count doesn't divide evenly or a set repeats an exposure.

Canon cameras shooting auto exposure bracketing in Manual mode record the bracket offset only in their maker notes, which Lightroom can't read. ExifTool reads them, without changing your files.

### Why keyboard shortcuts

Lightroom's plugin SDK can't create stacks or HDR merges. So for each set the plugin selects the photos and sends the shortcut, Ctrl+G to stack and Ctrl+Shift+H to merge. Colour labels are set through the SDK directly.

## Upright Guides

**Library > Plug-in Extras > Place Upright Guides...**, or in Develop, **File > Plug-in Extras > Place Upright Guides...**

1. Select the photos.
2. Choose the options and click **Place Guides**. It takes about 2 seconds a photo to measure, then a few seconds a photo in Develop. Keep Lightroom in front and leave the keyboard and mouse alone until it finishes.

Options

- **Turn on lens profile correction**, recommended. Guides are placed on the lens corrected image. When it's off and a photo has no profile, they're placed on the uncorrected image.
- **Also add two horizontal guides on straight-on shots** squares the camera to the back wall. It's skipped on angled, two point views.

The summary lists each photo's measured pitch and roll. Photos marked **low confidence** have few or short vertical edges, so check those first.

Lightroom only works out a Guided Upright correction when the Upright mode is changed in Develop. So after placing the guides, the plugin opens each photo in Develop and switches Upright to Auto and back to Guided, as you would by hand, then returns you to where you started.

Only develop settings change, Upright, the guides, and lens correction if ticked, and each step can be undone from History. Your image files are only read.

## Troubleshooting

- **"The helper isn't set up"** run the setup in step 4 again, in the plugin's current folder.
- **ExifTool not found** check it's at `C:\Program Files\exiftool\exiftool.exe` on Windows, or in `/opt/homebrew/bin`, `/usr/local/bin` or `/usr/bin` on macOS.
- **Sets skipped while stacking** raise **Pause per stack**, and don't touch the keyboard or mouse while it runs.
- **A guide is off** drag it in Develop's Transform panel. Lightroom updates the correction straight away.

## Privacy

Nothing leaves your computer. The plugins read your photos and their metadata, write small working files to your system's temp folder, and change only Lightroom develop settings, stacks and labels.

## Licence

MIT, see [LICENSE](LICENSE). Free to use, change and share.
