@echo off
rem IFM frontend local web server launcher (Windows). Double-click this file.
rem It just runs: python serve.py (with any extra arguments you pass).
cd /d "%~dp0"

set PY=python
where python >nul 2>nul
if errorlevel 1 (
  where py >nul 2>nul
  if errorlevel 1 (
    echo [IFM] Python 3 was not found in PATH.
    echo [IFM] Install it from https://www.python.org/downloads/ and try again,
    echo [IFM] or run manually: py -3 serve.py
    pause
    exit /b 1
  )
  set PY=py -3
)

echo [IFM] Starting the local web server for the IFM frontend ...
%PY% serve.py %*

echo.
echo [IFM] Server stopped.
pause
