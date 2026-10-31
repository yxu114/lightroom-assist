--[[
Upright Guides

Places Guided Upright guides on the selected photos. A helper program
(helper/upright_helper.py) finds the room's true vertical direction from the
straight lines in each photo and returns two vertical guides on strong real
edges, angled to agree with all the lines. Lightroom then computes the
correction from the guides as usual, so they can be dragged afterwards.
Optionally it also adds two horizontal guides on straight-on shots.

Photos are only read by the helper. All changes are develop settings, written
through the SDK, and can be undone from History.
]]

local LrApplication = import 'LrApplication'
local LrApplicationView = import 'LrApplicationView'
local LrBinding = import 'LrBinding'
local LrDate = import 'LrDate'
local LrDevelopController = import 'LrDevelopController'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local prefs = LrPrefs.prefsForPlugin()

local MAX_GUIDES = 4
local MAX_LISTED = 12

-- Upright version Lightroom writes alongside guides; used when a photo has
-- never had Upright set, so Lightroom reads the guides with the current model.
local UPRIGHT_VERSION = 151388160

-- PerspectiveUpright values.
local UPRIGHT_AUTO = 1
local UPRIGHT_GUIDED = 5

-- Seconds to wait for Develop to load a photo, to let it settle before the
-- first change, and for Lightroom to save each mode change.
local LOAD_TIMEOUT = 5
local LOAD_SETTLE = 1
local SOLVE_TIMEOUT = 10

-- The helper lives in helper/ inside this plugin, with its own Python in helper/.venv.
local function helperPaths()
	local helper = LrPathUtils.child(_PLUGIN.path, 'helper')
	local python
	if WIN_ENV then
		python = LrPathUtils.child(helper, '.venv\\Scripts\\python.exe')
	else
		python = LrPathUtils.child(helper, '.venv/bin/python3')
	end
	return python, LrPathUtils.child(helper, 'upright_helper.py'), helper
end

local function quote(s)
	return '"' .. s .. '"'
end

local function run(cmd)
	if WIN_ENV then
		-- Outer quotes are required by cmd.exe when the command contains quoted paths.
		cmd = '"' .. cmd .. '"'
	end
	return LrTasks.execute(cmd)
end

local function splitTabs(line)
	local out = {}
	for field in (line .. '\t'):gmatch('([^\t]*)\t') do
		out[#out + 1] = field
	end
	return out
end

local function waitFor(seconds, done)
	local deadline = LrDate.currentTime() + seconds
	while not done() do
		if LrDate.currentTime() > deadline then
			return false
		end
		LrTasks.sleep(0.1)
	end
	return true
end

-- Sets the Upright mode on the photo open in Develop and waits until Lightroom
-- has saved it, trying once more if it doesn't take. Returns true once saved,
-- false if it never was, or nil and a message if Develop refused the change.
local function setUpright(photo, mode)
	for _ = 1, 2 do
		local ok, result, message = pcall(LrDevelopController.setValue, 'PerspectiveUpright', mode)
		if not ok or result == false then
			return nil, tostring(ok and message or result)
		end
		if waitFor(SOLVE_TIMEOUT, function()
				return (photo:getDevelopSettings() or {}).PerspectiveUpright == mode
			end) then
			return true
		end
	end
	return false
end

-- Lightroom stores the solved correction (UprightTransform_0 to _5, one per
-- mode) only when the Upright mode is changed in Develop; guides written
-- through the SDK alone leave it unsolved. So each photo is opened in Develop
-- and switched to Auto and back to Guided, as you would by hand. Each change is
-- only made once the one before it has been saved: Guided sent while Auto is
-- still solving gets overwritten by Auto. Returns how many were solved, and an
-- error message if Develop refused the change.
local function solveInDevelop(catalog, photos, progress)
	local startModule = LrApplicationView.getCurrentModuleName()
	local active = catalog:getTargetPhoto()
	local selection = catalog:getTargetPhotos()

	LrApplicationView.switchToModule('develop')
	local solved, failure = 0, nil
	for i, photo in ipairs(photos) do
		if progress:isCanceled() then
			break
		end
		progress:setCaption(string.format('Applying correction %d of %d', i, #photos))
		catalog:setSelectedPhotos(photo, {})
		waitFor(LOAD_TIMEOUT, function()
			return catalog:getTargetPhoto() == photo
		end)
		LrTasks.sleep(LOAD_SETTLE)

		-- Lightroom saves the mode change together with its solve, so the saved
		-- mode is enough to know the step finished. The solved transforms can't be
		-- checked directly: on Guided Lightroom keeps only some of them.
		local auto, message = setUpright(photo, UPRIGHT_AUTO)
		local guided
		if auto then
			guided, message = setUpright(photo, UPRIGHT_GUIDED)
		end
		if auto == nil or guided == nil and message then
			failure = message
			break
		end
		if guided then
			solved = solved + 1
		end
		progress:setPortionComplete(i, #photos)
	end

	if active then
		local others = {}
		for _, photo in ipairs(selection) do
			if photo ~= active then
				others[#others + 1] = photo
			end
		end
		catalog:setSelectedPhotos(active, others)
	end
	if startModule and startModule ~= 'develop' then
		LrApplicationView.switchToModule(startModule)
	end
	return solved, failure
end

local function showOptions(context, count)
	local f = LrView.osFactory()
	local props = LrBinding.makePropertyTable(context)
	props.lensOn = prefs.lensOn ~= false
	props.horizontal = prefs.horizontal == true

	local result = LrDialogs.presentModalDialog {
		title = 'Place Upright Guides',
		contents = f:column {
			bind_to_object = props,
			spacing = f:control_spacing(),
			f:static_text {
				title = string.format('Two vertical guides will be placed on %d photo(s) and Upright set to Guided.', count),
			},
			f:checkbox {
				title = 'Turn on lens profile correction (recommended: guides are placed on the corrected image)',
				value = LrView.bind 'lensOn',
			},
			f:checkbox {
				title = 'Also add two horizontal guides on straight-on shots',
				value = LrView.bind 'horizontal',
			},
		},
		actionVerb = 'Place Guides',
	}
	if result ~= 'ok' then
		return nil
	end
	prefs.lensOn = props.lensOn
	prefs.horizontal = props.horizontal
	return { lensOn = props.lensOn, horizontal = props.horizontal }
end

local function main(context)
	local catalog = LrApplication.activeCatalog()
	local photos = catalog:getTargetPhotos()
	if #photos == 0 then
		LrDialogs.message('Upright Guides', 'Select the photos to correct first.', 'info')
		return
	end

	local python, script, helper = helperPaths()
	if not LrFileUtils.exists(python) or not LrFileUtils.exists(script) then
		LrDialogs.message('Upright Guides',
			'The helper isn\'t set up. Expected:\n' .. python .. '\n' .. script
			.. '\n\nRun ' .. (WIN_ENV and 'setup.bat' or 'setup.sh') .. ' in ' .. helper
			.. ', then try again.', 'critical')
		return
	end

	local options = showOptions(context, #photos)
	if not options then
		return
	end

	local progress = LrProgressScope { title = 'Placing Upright guides', functionContext = context }
	progress:setCaption('Measuring photos')

	-- Job list for the helper: one line per photo.
	local temp = LrPathUtils.getStandardFilePath('temp')
	local jobFile = LrPathUtils.child(temp, 'UprightGuides-jobs.txt')
	local resultFile = LrPathUtils.child(temp, 'UprightGuides-results.txt')
	LrFileUtils.delete(resultFile)

	local paths = catalog:batchGetRawMetadata(photos, { 'path' })
	local names = catalog:batchGetFormattedMetadata(photos, { 'fileName' })
	local jobs = assert(io.open(jobFile, 'wb'))
	local byId, lensOnFor = {}, {}
	for i, photo in ipairs(photos) do
		local dev = photo:getDevelopSettings() or {}
		local lensOn = options.lensOn or dev.LensProfileEnable == 1
		local profile = (dev.LensProfileEnable == 1 and dev.LensProfileFilename) or ''
		byId[tostring(i)] = photo
		lensOnFor[photo] = lensOn
		jobs:write(table.concat({ tostring(i), paths[photo].path, profile,
			lensOn and '1' or '0', options.horizontal and '1' or '0' }, '\t'), '\n')
	end
	jobs:close()

	local exitCode = run(quote(python) .. ' -I ' .. quote(script) .. ' ' .. quote(jobFile) .. ' ' .. quote(resultFile))

	local results = {}
	local out = io.open(resultFile, 'rb')
	if out then
		for line in out:lines() do
			local fields = splitTabs(line:gsub('\r$', ''))
			if byId[fields[1]] then
				results[#results + 1] = fields
			end
		end
		out:close()
	end
	LrFileUtils.delete(jobFile)
	LrFileUtils.delete(resultFile)

	if #results == 0 then
		progress:done()
		LrDialogs.message('Upright Guides', string.format('The helper didn\'t return any results (exit code %s).',
			tostring(exitCode)), 'critical')
		return
	end

	progress:setCaption('Writing guides')
	local placed, lines, placedPhotos = 0, {}, {}
	catalog:withWriteAccessDo('Place Upright guides', function()
		for _, r in ipairs(results) do
			local photo = byId[r[1]]
			local name = names[photo].fileName
			if r[2] == 'ok' then
				local guides = {}
				for g in (r[6] or ''):gmatch('[^;]+') do
					guides[#guides + 1] = g
				end
				local settings = {
					PerspectiveUpright = 5,
					UprightFourSegmentsCount = #guides,
				}
				for g = 1, MAX_GUIDES do
					settings['UprightFourSegments_' .. (g - 1)] = guides[g] or ''
				end
				local dev = photo:getDevelopSettings() or {}
				if not dev.UprightVersion or dev.UprightVersion == 0 then
					settings.UprightVersion = UPRIGHT_VERSION
				end
				if lensOnFor[photo] then
					settings.LensProfileEnable = 1
				end
				photo:applyDevelopSettings(settings, 'Upright guides')
				placed = placed + 1
				placedPhotos[#placedPhotos + 1] = photo

				local note = (r[7] or '') ~= '' and ('  (' .. r[7] .. ')') or ''
				lines[#lines + 1] = string.format('%s: pitch %+.1f\194\176, roll %+.1f\194\176%s',
					name, tonumber(r[3]) or 0, tonumber(r[4]) or 0, note)
			else
				lines[#lines + 1] = string.format('%s: skipped, %s', name, r[3] or 'unknown error')
			end
		end
	end, { timeout = 60 })

	local solveNote = ''
	if #placedPhotos > 0 then
		progress:setPortionComplete(0, #placedPhotos)
		local solved, failure = solveInDevelop(catalog, placedPhotos, progress)
		if failure then
			solveNote = string.format('\n\nLightroom refused the Upright mode change (%s), so the correction '
				.. 'isn\'t applied yet. Switch Upright to Auto and back to Guided to apply it.', failure)
		elseif solved < #placedPhotos then
			solveNote = string.format('\n\nCorrection applied on %d of %d. On the rest, switch Upright to '
				.. 'Auto and back to Guided to apply it.', solved, #placedPhotos)
		end
	end

	progress:done()

	local shown = {}
	for i = 1, math.min(#lines, MAX_LISTED) do
		shown[i] = lines[i]
	end
	if #lines > MAX_LISTED then
		shown[#shown + 1] = string.format('...and %d more', #lines - MAX_LISTED)
	end
	LrDialogs.message('Upright Guides',
		string.format('Guides placed on %d of %d photo(s).\n\n%s%s', placed, #photos,
			table.concat(shown, '\n'), solveNote),
		'info')
end

return {
	run = function()
		LrFunctionContext.postAsyncTaskWithContext('UprightGuides', function(context)
			LrDialogs.attachErrorDialogToFunctionContext(context)
			main(context)
		end)
	end,
}
