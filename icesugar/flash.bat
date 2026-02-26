@echo off
REM Flash a .bin file to IceSugar v1.5 via iCELink USB mass storage

set "BIN=%~1"
if "%BIN%"=="" set "BIN=build\top.bin"

if not exist "%BIN%" (
    echo Error: %BIN% not found
    exit /b 1
)

REM Find iCELink drive letter
set "DRIVE="
for /f "tokens=1,2,*" %%a in ('wmic logicaldisk get caption^,volumename 2^>nul') do (
    echo %%b | findstr /i "iCELink" >nul 2>&1 && set "DRIVE=%%a"
)

if "%DRIVE%"=="" (
    echo Error: iCELink drive not found. Is the board connected?
    exit /b 1
)

echo Flashing %BIN% -^> %DRIVE%\
copy /y "%BIN%" "%DRIVE%\"
echo Done.
