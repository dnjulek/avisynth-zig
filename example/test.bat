@echo off
setlocal
cd /d "%~dp0"

set "RESULT=1"
rem test.bat --no-pause : noninteractive (CI / scripted runs)
set "PAUSE=1"
if /i "%~1"=="--no-pause" set "PAUSE="

where ffmpeg >nul 2>nul || (echo ERROR: ffmpeg not found in PATH. & goto :done)

if not exist "zig-out\bin\invert_example.dll" (
    echo ERROR: plugin not built. Run: zig build -Doptimize=fast
    goto :done
)

echo Loading test.avs (runs every Assert over all frames) and decoding with ffmpeg...
ffmpeg -hide_banner -loglevel error -y -i test.avs -update 1 test_result.png
rem ffmpeg reports failures with NEGATIVE exit codes, which "if errorlevel 1"
rem does not catch - compare against 0 instead.
if %errorlevel% neq 0 (
    echo.
    echo TEST FAILED: an Assert fired or the script could not be loaded.
    goto :done
)

set "RESULT=0"
echo TEST PASSED: result image saved to test_result.png

:done
echo.
if defined PAUSE pause
exit /b %RESULT%
