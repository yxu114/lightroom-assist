--[[
Bracket Stacker

Stack Brackets: takes the selected photos (or every photo in the current
folder/collection if 0 or 1 is selected), sorts them, works out the bracket sets
and stacks each set, optionally HDR merging them and colour labelling the results.

Label Brackets: labels stacked photos and merged HDR DNGs in the current
folder/collection, for sets already stacked or merged. Nothing is stacked,
merged or regrouped.

Sets are found either from the bracket exposure pattern (e.g. -2, 0, +2) or by
counting off every N photos.

The Lightroom SDK has no API for creating stacks or HDR merges, so for each set
the plugin selects the photos and sends the shortcut (Ctrl+G / Ctrl+Shift+H).
]]

local LrApplication = import 'LrApplication'
local LrApplicationView = import 'LrApplicationView'
local LrBinding = import 'LrBinding'
local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local prefs = LrPrefs.prefsForPlugin()

local MAX_LISTED_PROBLEMS = 10

-- Exposure values closer than this are treated as equal (EXIF stores thirds as decimals).
local BIAS_TOLERANCE = 0.01

-- Seconds allowed between the end of one bracket frame and the start of the next.
local MAX_FRAME_GAP = 5

-- Seconds to keep waiting for HDR merges after the last merged DNG arrived.
local MERGE_TIMEOUT = 300

-- Seconds between checks for newly merged DNGs.
local MERGE_POLL_INTERVAL = 5

local MAC_KEYSTROKES = {
	stack = [[keystroke "g" using command down]],
	merge = [[keystroke "h" using {command down, shift down}]],
}

-- name is 'stack' (Group into Stack) or 'merge' (HDR merge without the dialog).
local function sendShortcut(name)
	local cmd
	if WIN_ENV then
		local vbs = LrPathUtils.child(_PLUGIN.path, 'sendkey.vbs')
		-- Outer quotes are required by cmd.exe when the command contains a quoted path.
		cmd = '"wscript.exe //B //nologo "' .. vbs .. '" ' .. name .. '"'
	else
		cmd = [[osascript -e 'tell application "System Events" to ]] .. MAC_KEYSTROKES[name] .. "'"
	end
	return LrTasks.execute(cmd)
end

local function setLabel(catalog, photos, colour, actionName)
	catalog:withWriteAccessDo(actionName, function()
		for _, photo in ipairs(photos) do
			photo:setRawMetadata('colorNameForLabel', colour)
		end
	end, { timeout = 30 })
end

-- The folders holding the source photos, and every photo already in them, so
-- that merged DNGs can be recognised as the new arrivals.
local function snapshotFolders(catalog, groups)
	local folders, seenFolder = {}, {}
	for _, group in ipairs(groups) do
		for _, photo in ipairs(group) do
			local parent = LrPathUtils.parent(photo:getRawMetadata('path'))
			if not seenFolder[parent] then
				seenFolder[parent] = true
				local folder = catalog:getFolderByPath(parent)
				if folder then
					folders[#folders + 1] = folder
				end
			end
		end
	end

	local existing = {}
	for _, folder in ipairs(folders) do
		for _, photo in ipairs(folder:getPhotos(false)) do
			existing[photo.localIdentifier] = true
		end
	end
	return folders, existing
end

local function activeCollection(catalog)
	local sources = catalog:getActiveSources()
	local source = sources and sources[1]
	if #sources == 1 and type(source) == 'table' and source.type and source:type() == 'LrCollection' then
		return source
	end
	return nil
end

-- HDR merges run in the background, so keep checking the source folders for new
-- DNGs. Each one is labelled and, when working from a collection, added to it so
-- it shows up next to its sources. Stops once every merge has arrived, after
-- MERGE_TIMEOUT seconds with nothing new, or when cancelled.
local function waitForMerges(catalog, folders, existing, expected, options, progress)
	local collection = activeCollection(catalog)
	local arrived, lastArrival = 0, LrDate.currentTime()

	while arrived < expected do
		if progress:isCanceled() or LrDate.currentTime() - lastArrival > MERGE_TIMEOUT then
			break
		end
		progress:setCaption(string.format('Waiting for HDR merges: %d of %d done', arrived, expected))
		LrTasks.sleep(MERGE_POLL_INTERVAL)

		local candidates = {}
		for _, folder in ipairs(folders) do
			for _, photo in ipairs(folder:getPhotos(false)) do
				if not existing[photo.localIdentifier] then
					candidates[#candidates + 1] = photo
				end
			end
		end

		if #candidates > 0 then
			local raw = catalog:batchGetRawMetadata(candidates, { 'fileFormat' })
			local merged = {}
			for _, photo in ipairs(candidates) do
				existing[photo.localIdentifier] = true
				if raw[photo].fileFormat == 'DNG' then
					merged[#merged + 1] = photo
				end
			end

			if #merged > 0 then
				catalog:withWriteAccessDo('Label HDR merges', function()
					if options.labelMerged then
						for _, photo in ipairs(merged) do
							photo:setRawMetadata('colorNameForLabel', 'blue')
						end
					end
					if collection then
						collection:addPhotos(merged)
					end
				end, { timeout = 30 })
				arrived = arrived + #merged
				lastArrival = LrDate.currentTime()
				progress:setPortionComplete(arrived, expected)
			end
		end
	end
	return arrived
end

local function sortPhotos(catalog, photos, sortBy)
	local raw = catalog:batchGetRawMetadata(photos, { 'dateTimeOriginal' })
	local fmt = catalog:batchGetFormattedMetadata(photos, { 'fileName' })

	local sorted = {}
	for i, photo in ipairs(photos) do
		sorted[i] = photo
	end

	table.sort(sorted, function(a, b)
		local nameA, nameB = fmt[a].fileName or '', fmt[b].fileName or ''
		if sortBy == 'time' then
			local timeA = raw[a].dateTimeOriginal or 0
			local timeB = raw[b].dateTimeOriginal or 0
			if timeA ~= timeB then
				return timeA < timeB
			end
		end
		return nameA < nameB
	end)

	return sorted, fmt
end

-- Every N photos is one set.
local function makeGroupsByCount(photos, size)
	local groups = {}
	local count = math.floor(#photos / size)
	for g = 1, count do
		local group = {}
		for j = 1, size do
			group[j] = photos[(g - 1) * size + j]
		end
		groups[g] = group
	end
	return groups, #photos - count * size
end

-- Each frame's offset from the first frame of a set, in steps.
-- 'down' (+ 0 -): 0, -1, -2, ...   'up' (- 0 +): 0, 1, 2, ...
-- 'centre' (0 - +): 0, -1, 1, -2, 2, ...
local function bracketPattern(order, size)
	local pattern = {}
	for k = 0, size - 1 do
		if order == 'down' then
			pattern[k + 1] = -k
		elseif order == 'up' then
			pattern[k + 1] = k
		else
			local m = math.ceil(k / 2)
			pattern[k + 1] = (k % 2 == 1) and -m or m
		end
	end
	return pattern
end

-- Consecutive bracket frames are shot back to back, so the next frame starts
-- within the previous frame's shutter time plus some slack. Doubling the shutter
-- time allows for long exposure noise reduction (a dark frame of equal length).
local function shotBackToBack(prev, next)
	if not prev.dateTimeOriginal or not next.dateTimeOriginal then
		return true
	end
	local allowed = 2 * (prev.shutterSpeed or 0) + MAX_FRAME_GAP
	return next.dateTimeOriginal - prev.dateTimeOriginal <= allowed
end

local function findExifTool()
	local candidates
	if WIN_ENV then
		candidates = {
			'C:\\Program Files\\exiftool\\exiftool.exe',
			'C:\\Program Files (x86)\\exiftool\\exiftool.exe',
			'C:\\Windows\\exiftool.exe',
		}
	else
		candidates = { '/opt/homebrew/bin/exiftool', '/usr/local/bin/exiftool', '/usr/bin/exiftool' }
	end
	for _, path in ipairs(candidates) do
		if LrFileUtils.exists(path) then
			return path
		end
	end
	return nil
end

local function normalisePath(path)
	return (path:gsub('\\', '/'):lower())
end

-- Canon doesn't put the AEB offset into the EXIF exposure compensation when
-- shooting in Manual (it stays 0), but its maker notes record it as
-- AEBBracketValue, plus BracketMode (AEB / Off) which identifies single shots.
-- Lightroom can't read maker notes, so ExifTool reads them. Read-only: no write
-- options are passed. Returns nil if ExifTool isn't installed.
local function readMakerNoteBrackets(catalog, photos)
	local exifTool = findExifTool()
	if not exifTool then
		return nil
	end

	local paths = catalog:batchGetRawMetadata(photos, { 'path' })
	local temp = LrPathUtils.getStandardFilePath('temp')
	local argFile = LrPathUtils.child(temp, 'BracketStacker-args.txt')
	local outFile = LrPathUtils.child(temp, 'BracketStacker-out.txt')

	local args = assert(io.open(argFile, 'wb'))
	for _, line in ipairs({ '-charset', 'filename=utf8', '-fast', '-T',
			'-FilePath', '-BracketMode', '-AEBBracketValue#' }) do
		args:write(line, '\n')
	end
	for _, photo in ipairs(photos) do
		args:write(paths[photo].path, '\n')
	end
	args:close()

	local cmd = '"' .. exifTool .. '" -@ "' .. argFile .. '" > "' .. outFile .. '"'
	if WIN_ENV then
		-- Outer quotes are required by cmd.exe when the command contains quoted paths.
		cmd = '"' .. cmd .. '"'
	end
	LrTasks.execute(cmd)

	local byPath = {}
	local out = io.open(outFile, 'rb')
	if out then
		for line in out:lines() do
			local path, mode, value = line:match('^([^\t]*)\t([^\t]*)\t([^\t\r]*)')
			if path then
				byPath[normalisePath(path)] = { mode = mode, value = tonumber(value) }
			end
		end
		out:close()
	end
	LrFileUtils.delete(argFile)
	LrFileUtils.delete(outFile)

	local result = {}
	for _, photo in ipairs(photos) do
		result[photo] = byPath[normalisePath(paths[photo].path)]
	end
	return result
end

-- Looks for runs of frames whose bracket values match the pattern exactly
-- (e.g. x, x+2, x+4 for - 0 + with 2 stop steps), whatever the base value x is.
-- Bracket values come from Canon's maker notes when ExifTool is available,
-- otherwise from the EXIF exposure compensation. Frames that don't fit a full
-- set are left out, so single exposures and broken brackets never get stacked.
-- Returns sets and unmatched runs, or nil, nil and a photo with no bracket value.
local function makeGroupsByExposure(catalog, photos, order, size, step)
	local raw = catalog:batchGetRawMetadata(photos,
		{ 'exposureBias', 'dateTimeOriginal', 'shutterSpeed' })
	local makerNotes = readMakerNoteBrackets(catalog, photos)

	for _, photo in ipairs(photos) do
		local frame = raw[photo]
		local note = makerNotes and makerNotes[photo]
		if note and note.value then
			frame.bracket = note.value
			frame.bracketed = note.mode ~= 'Off'
		else
			frame.bracket = frame.exposureBias
			frame.bracketed = true
		end
		if frame.bracket == nil then
			return nil, nil, photo
		end
	end

	local pattern = bracketPattern(order, size)

	local function isSetAt(i)
		if i + size - 1 > #photos then
			return false
		end
		local base = raw[photos[i]].bracket
		if not raw[photos[i]].bracketed then
			return false
		end
		for k = 1, size - 1 do
			local frame = raw[photos[i + k]]
			if not frame.bracketed then
				return false
			end
			if math.abs(frame.bracket - base - pattern[k + 1] * step) > BIAS_TOLERANCE then
				return false
			end
			if not shotBackToBack(raw[photos[i + k - 1]], frame) then
				return false
			end
		end
		return true
	end

	local groups, unmatched, run = {}, {}, {}
	local i = 1
	while i <= #photos do
		if isSetAt(i) then
			if #run > 0 then
				unmatched[#unmatched + 1] = run
				run = {}
			end
			groups[#groups + 1] = { unpack(photos, i, i + size - 1) }
			i = i + size
		else
			run[#run + 1] = photos[i]
			i = i + 1
		end
	end
	if #run > 0 then
		unmatched[#unmatched + 1] = run
	end
	return groups, unmatched
end

-- A bracket set should have a different exposure compensation on every frame.
-- Repeated values usually mean a missing or extra frame has shifted the grouping.
local function findSuspectGroups(catalog, groups, fmt)
	local all = {}
	for _, group in ipairs(groups) do
		for _, photo in ipairs(group) do
			all[#all + 1] = photo
		end
	end
	local raw = catalog:batchGetRawMetadata(all, { 'exposureBias' })

	local suspects = {}
	for g, group in ipairs(groups) do
		local seen, duplicate = {}, false
		for _, photo in ipairs(group) do
			local bias = raw[photo].exposureBias
			if bias ~= nil then
				local key = string.format('%.2f', bias)
				if seen[key] then
					duplicate = true
				end
				seen[key] = true
			end
		end
		if duplicate then
			suspects[#suspects + 1] = string.format('Group %d: %s ... %s',
				g, fmt[group[1]].fileName, fmt[group[#group]].fileName)
		end
	end
	return suspects
end

local function confirmWithList(title, intro, lines, question, actionVerb)
	local shown = {}
	for i = 1, math.min(#lines, MAX_LISTED_PROBLEMS) do
		shown[i] = lines[i]
	end
	if #lines > MAX_LISTED_PROBLEMS then
		shown[#shown + 1] = string.format('...and %d more', #lines - MAX_LISTED_PROBLEMS)
	end
	local answer = LrDialogs.confirm(title,
		intro .. '\n\n' .. table.concat(shown, '\n') .. '\n\n' .. question,
		actionVerb, 'Cancel')
	return answer == 'ok'
end

local function showOptionsDialog(context, photoCount)
	local f = LrView.osFactory()
	local bind = LrView.bind
	local share = LrView.share

	local props = LrBinding.makePropertyTable(context)
	props.findBy = prefs.findBy or 'up'
	props.groupSize = prefs.groupSize or 3
	props.step = prefs.step or 2
	props.sortBy = prefs.sortBy or 'time'
	props.delay = prefs.delay or 0.4
	props.checkExposure = prefs.checkExposure ~= false
	props.labelStacked = prefs.labelStacked ~= false
	props.merge = prefs.merge == true
	props.labelMerged = prefs.labelMerged ~= false

	props.isCount = props.findBy == 'count'
	props:addObserver('findBy', function()
		props.isCount = props.findBy == 'count'
	end)

	local contents = {
		bind_to_object = props,
		spacing = f:control_spacing(),

		f:static_text { title = string.format('%d photos will be split into bracket sets and stacked.', photoCount) },
		f:row {
			f:static_text { title = 'Find sets by:', width = share 'label', alignment = 'right' },
			f:popup_menu {
				value = bind 'findBy',
				items = {
					{ title = 'Exposure order  + 0 \226\136\146', value = 'down' },
					{ title = 'Exposure order  \226\136\146 0 +', value = 'up' },
					{ title = 'Exposure order  0 \226\136\146 +', value = 'centre' },
					{ title = 'Fixed count (every N photos)', value = 'count' },
				},
			},
		},
		f:row {
			f:static_text { title = 'Photos per bracket:', width = share 'label', alignment = 'right' },
			f:edit_field { value = bind 'groupSize', min = 2, max = 15, precision = 0, width_in_digits = 4 },
		},
		f:row {
			f:static_text { title = 'Stops between frames:', width = share 'label', alignment = 'right' },
			f:edit_field {
				value = bind 'step', min = 0.3, max = 3, precision = 1, width_in_digits = 4,
				enabled = LrBinding.negativeOfKey('isCount'),
			},
		},
		f:row {
			f:static_text { title = 'Order by:', width = share 'label', alignment = 'right' },
			f:popup_menu {
				value = bind 'sortBy',
				items = {
					{ title = 'Capture time, then file name', value = 'time' },
					{ title = 'File name', value = 'name' },
				},
			},
		},
		f:checkbox {
			title = 'Fixed count only: warn if a group has repeated exposure values',
			value = bind 'checkExposure',
			enabled = bind 'isCount',
		},
		f:separator { fill_horizontal = 1 },
		f:checkbox {
			title = 'Label bracket photos Yellow',
			value = bind 'labelStacked',
		},
		f:checkbox {
			title = 'HDR merge each set (Ctrl+Shift+H, uses your last HDR Merge settings)',
			value = bind 'merge',
		},
		f:checkbox { title = 'Label merged DNGs Blue', value = bind 'labelMerged', enabled = bind 'merge' },
		f:row {
			f:static_text { title = 'Pause per stack (sec):', width = share 'label', alignment = 'right' },
			f:edit_field { value = bind 'delay', min = 0.1, max = 3, precision = 1, width_in_digits = 4 },
		},
		f:static_text {
			title = 'While it runs, keep Lightroom in front and don\'t use the keyboard or mouse.',
		},
	}

	local result = LrDialogs.presentModalDialog {
		title = 'Stack Brackets',
		contents = f:column(contents),
		actionVerb = 'Stack',
	}
	if result ~= 'ok' then
		return nil
	end

	prefs.findBy = props.findBy
	prefs.groupSize = props.groupSize
	prefs.step = props.step
	prefs.sortBy = props.sortBy
	prefs.delay = props.delay
	prefs.checkExposure = props.checkExposure
	prefs.labelStacked = props.labelStacked
	prefs.merge = props.merge
	prefs.labelMerged = props.labelMerged

	return {
		labelStacked = props.labelStacked,
		merge = props.merge,
		labelMerged = props.labelMerged,
		findBy = props.findBy,
		groupSize = math.floor(props.groupSize),
		step = props.step,
		sortBy = props.sortBy,
		delay = props.delay,
		checkExposure = props.checkExposure,
	}
end

-- Returns the sets to stack, or nil if the user cancelled or there was a problem.
local function findGroupsByCount(catalog, sorted, fmt, options)
	local groups, leftover = makeGroupsByCount(sorted, options.groupSize)

	if leftover > 0 then
		local answer = LrDialogs.confirm(
			'Photo count doesn\'t divide evenly',
			string.format('%d photos is not a multiple of %d. The last %d photo(s) will be left unstacked, '
				.. 'and a missing frame earlier on would shift every group after it.\n\nContinue anyway?',
				#sorted, options.groupSize, leftover),
			'Continue', 'Cancel')
		if answer ~= 'ok' then
			return nil
		end
	end

	if options.checkExposure then
		local suspects = findSuspectGroups(catalog, groups, fmt)
		if #suspects > 0 and not confirmWithList(
				string.format('%d group(s) have repeated exposure values', #suspects),
				'These may not be clean brackets:', suspects, 'Stack anyway?', 'Stack Anyway') then
			return nil
		end
	end

	return groups
end

local function findGroupsByExposure(catalog, sorted, fmt, options)
	local sets, unmatched, missing = makeGroupsByExposure(
		catalog, sorted, options.findBy, options.groupSize, options.step)
	if not sets then
		LrDialogs.message('Stack Brackets',
			string.format('%s has no exposure compensation value, so sets can\'t be found by exposure. '
				.. 'Use "Fixed count" instead.', fmt[missing].fileName), 'warning')
		return nil
	end

	-- A lone unmatched photo is most likely a single exposure, so just count it.
	-- Two or more unmatched in a row is more likely a broken bracket worth checking.
	local suspects, singles = {}, 0
	for _, run in ipairs(unmatched) do
		if #run == 1 then
			singles = singles + 1
		else
			suspects[#suspects + 1] = string.format('%s ... %s (%d photos)',
				fmt[run[1]].fileName, fmt[run[#run]].fileName, #run)
		end
	end

	local singlesNote = ''
	if singles > 0 then
		singlesNote = string.format('\n\n%d single photo(s) will also be left unstacked.', singles)
	end

	if #suspects > 0 and not confirmWithList(
			string.format('%d run(s) of photos don\'t match the bracket pattern', #suspects),
			'These will be left unstacked. They may be broken brackets or several singles in a row:',
			suspects,
			string.format('Continue with the %d matching sets?%s', #sets, singlesNote), 'Continue') then
		return nil
	end

	return sets, singles
end

-- Every photo in the active folders/collections, including ones hidden inside
-- collapsed stacks (which the filmstrip selection can't reach).
local function allSourcePhotos(catalog)
	local photos, seen = {}, {}
	for _, source in ipairs(catalog:getActiveSources()) do
		if type(source) == 'table' and source.getPhotos then
			for _, photo in ipairs(source:getPhotos()) do
				if not seen[photo.localIdentifier] then
					seen[photo.localIdentifier] = true
					photos[#photos + 1] = photo
				end
			end
		end
	end
	return photos
end

-- Lightroom names merged HDRs after the first source frame plus -HDR, as DNGs.
-- They're kept out of the bracket matching.
local function splitMergedHdrs(catalog, photos)
	local raw = catalog:batchGetRawMetadata(photos, { 'fileFormat' })
	local fmt = catalog:batchGetFormattedMetadata(photos, { 'fileName' })
	local sources, merged = {}, {}
	for _, photo in ipairs(photos) do
		if raw[photo].fileFormat == 'DNG' and (fmt[photo].fileName or ''):find('HDR', 1, true) then
			merged[#merged + 1] = photo
		else
			sources[#sources + 1] = photo
		end
	end
	return sources, merged
end

-- Photos that are already stacked, and how many stacks they make up. Bracket
-- sets have been stacked by the time they're labelled, so the stacks themselves
-- say which photos are brackets: no need to work the sets out again.
local function stackedPhotos(photos)
	local stacked, tops, stackCount = {}, {}, 0
	for _, photo in ipairs(photos) do
		if photo:getRawMetadata('isInStackInFolder') then
			stacked[#stacked + 1] = photo
			local top = photo:getRawMetadata('topOfStackInFolderContainingPhoto')
			local id = top and top.localIdentifier or photo.localIdentifier
			if not tops[id] then
				tops[id] = true
				stackCount = stackCount + 1
			end
		end
	end
	return stacked, stackCount
end

-- Label Brackets: labels what's already been stacked and merged. Nothing is
-- stacked, merged or regrouped, so there are no set-finding settings to show.
local function runLabel(context, catalog)
	local photos, mergedHdrs = splitMergedHdrs(catalog, allSourcePhotos(catalog))
	local brackets, stackCount = stackedPhotos(photos)

	if #brackets == 0 and #mergedHdrs == 0 then
		LrDialogs.message('Label Brackets',
			'No stacked photos or merged HDR DNGs found here. Run Stack Brackets first.', 'info')
		return
	end

	local f = LrView.osFactory()
	local props = LrBinding.makePropertyTable(context)
	props.labelStacked = prefs.labelStacked ~= false and #brackets > 0
	props.labelMerged = prefs.labelMerged ~= false and #mergedHdrs > 0

	local result = LrDialogs.presentModalDialog {
		title = 'Label Brackets',
		contents = f:column {
			bind_to_object = props,
			spacing = f:control_spacing(),
			f:checkbox {
				title = string.format('Label %d stacked photos Yellow (%d stacks)', #brackets, stackCount),
				value = LrView.bind 'labelStacked',
				enabled = #brackets > 0,
			},
			f:checkbox {
				title = string.format('Label %d merged HDR DNGs Blue', #mergedHdrs),
				value = LrView.bind 'labelMerged',
				enabled = #mergedHdrs > 0,
			},
		},
		actionVerb = 'Label',
	}
	if result ~= 'ok' then
		return
	end

	local yellow = props.labelStacked and brackets or {}
	local blue = props.labelMerged and mergedHdrs or {}
	catalog:withWriteAccessDo('Label brackets', function()
		for _, photo in ipairs(yellow) do
			photo:setRawMetadata('colorNameForLabel', 'yellow')
		end
		for _, photo in ipairs(blue) do
			photo:setRawMetadata('colorNameForLabel', 'blue')
		end
	end, { timeout = 30 })
end

local function runStack(context, catalog)
	local photos = splitMergedHdrs(catalog, catalog:getMultipleSelectedOrAllPhotos())

	if #photos < 2 then
		LrDialogs.message('Bracket Stacker', 'There are not enough photos to work with.', 'info')
		return
	end

	local options = showOptionsDialog(context, #photos)
	if not options then
		return
	end

	local sorted, fmt = sortPhotos(catalog, photos, options.sortBy)

	local groups, singles
	if options.findBy == 'count' then
		groups = findGroupsByCount(catalog, sorted, fmt, options)
	else
		groups, singles = findGroupsByExposure(catalog, sorted, fmt, options)
	end
	if not groups then
		return
	end

	if #groups == 0 then
		LrDialogs.message('Stack Brackets', 'No complete bracket sets found.', 'info')
		return
	end

	-- Group into Stack only works from the Library module.
	LrApplicationView.switchToModule('library')
	pcall(LrApplicationView.showView, 'grid')
	LrTasks.sleep(0.5)

	local progress = LrProgressScope {
		title = 'Stacking brackets',
		functionContext = context,
	}

	local folders, existing
	if options.merge then
		folders, existing = snapshotFolders(catalog, groups)
	end

	-- If a photo is hidden (filtered out or inside a collapsed stack) it can't be
	-- selected, and acting on a partial selection would make a mess.
	local function selectGroup(group)
		catalog:setSelectedPhotos(group[1], { unpack(group, 2) })
		LrTasks.sleep(0.15)
		return #catalog:getTargetPhotos() == #group
	end

	local stacked, stackedPhotos, failure = 0, {}, nil
	for i, group in ipairs(groups) do
		if progress:isCanceled() then
			break
		end
		progress:setCaption(string.format('Stack %d of %d', i, #groups))

		if not selectGroup(group) then
			failure = string.format('Could not select all photos in set %d (%s). '
				.. 'Check that no filter is active and no photos are already inside collapsed stacks.',
				i, fmt[group[1]].fileName)
			break
		end

		-- Merge before stacking: a freshly made stack may collapse to its top photo,
		-- which would leave only one photo selected for the merge.
		if options.merge then
			sendShortcut('merge')
			LrTasks.sleep(options.delay)
			selectGroup(group)
		end

		sendShortcut('stack')
		LrTasks.sleep(options.delay)

		stacked = stacked + 1
		for _, photo in ipairs(group) do
			stackedPhotos[#stackedPhotos + 1] = photo
		end
		progress:setPortionComplete(i, #groups)
	end

	if options.labelStacked and #stackedPhotos > 0 then
		setLabel(catalog, stackedPhotos, 'yellow', 'Label bracket stacks')
	end

	local merged
	if options.merge and stacked > 0 and not progress:isCanceled() then
		progress:setPortionComplete(0, stacked)
		merged = waitForMerges(catalog, folders, existing, stacked, options, progress)
	end

	progress:done()

	local summary = string.format('%d of %d stacks created.', stacked, #groups)
	if singles and singles > 0 then
		summary = summary .. string.format('\n%d single photo(s) left unstacked.', singles)
	end
	if merged then
		summary = summary .. string.format('\n%d of %d HDR merges found%s.', merged, stacked,
			options.labelMerged and ' and labelled Blue' or '')
		if merged < stacked then
			summary = summary .. '\nAny still running will finish in the background, but won\'t be labelled.'
		end
	end

	if failure then
		LrDialogs.message('Stack Brackets stopped', summary .. '\n\n' .. failure, 'warning')
	else
		LrDialogs.message('Stack Brackets', summary, 'info')
	end
end

local function run(mode)
	LrFunctionContext.postAsyncTaskWithContext('BracketStacker', function(context)
		LrDialogs.attachErrorDialogToFunctionContext(context)
		local catalog = LrApplication.activeCatalog()
		if mode == 'label' then
			runLabel(context, catalog)
		else
			runStack(context, catalog)
		end
	end)
end

return { run = run }
