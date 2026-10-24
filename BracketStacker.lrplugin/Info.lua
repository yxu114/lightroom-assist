return {
	LrSdkVersion = 10.0,
	LrSdkMinimumVersion = 6.0,

	LrToolkitIdentifier = 'com.lightroomassist.bracketstacker',
	LrPluginName = 'Bracket Stacker',

	LrLibraryMenuItems = {
		{
			title = 'Stack Brackets...',
			file = 'StackBrackets.lua',
			enabledWhen = 'photosAvailable',
		},
		{
			title = 'Label Brackets...',
			file = 'LabelBrackets.lua',
			enabledWhen = 'photosAvailable',
		},
	},

	VERSION = { major = 1, minor = 1, revision = 0 },
}
