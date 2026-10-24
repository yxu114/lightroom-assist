return {
	LrSdkVersion = 10.0,
	LrSdkMinimumVersion = 6.0,

	LrToolkitIdentifier = 'com.lightroomassist.uprightguides',
	LrPluginName = 'Upright Guides',

	LrLibraryMenuItems = {
		{
			title = 'Place Upright Guides...',
			file = 'PlaceGuides.lua',
			enabledWhen = 'photosSelected',
		},
	},

	-- File > Plug-in Extras, so it's also reachable from Develop.
	LrExportMenuItems = {
		{
			title = 'Place Upright Guides...',
			file = 'PlaceGuides.lua',
			enabledWhen = 'photosSelected',
		},
	},

	VERSION = { major = 0, minor = 1, revision = 0 },
}
