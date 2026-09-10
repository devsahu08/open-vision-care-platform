@echo off
title iCare Brighter Future Frontend Application Launcher
color 0B
echo =====================================================================
echo         iCare Brighter Future Frontend Application Launcher
echo =====================================================================
echo.

cd /d "%~dp0"

echo [*] Launching login.html in default web browser...
start login.html

echo.
echo =====================================================================
echo [SUCCESS] Frontend application opened successfully!
echo =====================================================================
echo.
exit
