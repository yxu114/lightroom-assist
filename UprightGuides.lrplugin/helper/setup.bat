@echo off
rem Sets up the Upright Guides helper: a Python environment in .venv here,
rem with the packages from requirements.txt. Run it again to repair it.
cd /d "%~dp0"

where py >nul 2>nul
if %errorlevel%==0 (
	py -3 -m venv .venv
) else (
	python -m venv .venv
)
if not exist ".venv\Scripts\python.exe" (
	echo.
	echo Couldn't create the Python environment. Install Python 3 from
	echo https://www.python.org/downloads/ and tick "Add python.exe to PATH".
	pause
	exit /b 1
)

".venv\Scripts\python.exe" -m pip install --upgrade pip
".venv\Scripts\python.exe" -m pip install -r requirements.txt
if errorlevel 1 (
	echo.
	echo The packages didn't install. Check the messages above.
	pause
	exit /b 1
)

echo.
echo Done. Restart Lightroom Classic.
pause
