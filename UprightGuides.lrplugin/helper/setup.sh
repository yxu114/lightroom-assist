#!/bin/sh
# Sets up the Upright Guides helper: a Python environment in .venv here,
# with the packages from requirements.txt. Run it again to repair it.
set -e
cd "$(dirname "$0")"

if ! command -v python3 >/dev/null 2>&1; then
	echo "Install Python 3 first, from https://www.python.org/downloads/"
	exit 1
fi

python3 -m venv .venv
.venv/bin/python3 -m pip install --upgrade pip
.venv/bin/python3 -m pip install -r requirements.txt

echo
echo "Done. Restart Lightroom Classic."
