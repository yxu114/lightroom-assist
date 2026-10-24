' Sends a Lightroom shortcut to the foreground window.
'   stack: Ctrl+G        (Photo > Stacking > Group into Stack)
'   merge: Ctrl+Shift+H  (Photo > Photo Merge > HDR, using the last settings, no dialog)
Set shell = CreateObject("WScript.Shell")
Select Case WScript.Arguments(0)
	Case "stack"
		shell.SendKeys "^g"
	Case "merge"
		shell.SendKeys "^+h"
End Select
