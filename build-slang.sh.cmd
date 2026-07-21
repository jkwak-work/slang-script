@echo off
set "build_config=%~1"
if not defined build_config set "build_config=Debug"
set "sccache_dir=%~2"

if not defined sccache_dir (
    echo Missing sccache cache directory. 1>&2
    exit /b 2
)

if not exist "%sccache_dir%" mkdir "%sccache_dir%" >nul 2>&1
if not exist "%sccache_dir%" (
    echo Failed to create sccache directory: %sccache_dir% 1>&2
    exit /b 1
)

where.exe sccache.exe >nul 2>&1
if errorlevel 1 (
    echo sccache.exe was not found in the Windows PATH. 1>&2
    echo Install it with: winget.exe install Mozilla.sccache 1>&2
    exit /b 1
)

set "SCCACHE_DIR=%sccache_dir%"
set "SLANG_USE_SCCACHE=1"

set "vcvars_output=%TEMP%\build-slang-vcvars-%RANDOM%-%RANDOM%.log"
call "C:\Program Files\Microsoft Visual Studio\18\Professional\VC\Auxiliary\Build\vcvars64.bat" >"%vcvars_output%" 2>&1
set "vcvars_status=%errorlevel%"
if not "%vcvars_status%"=="0" (
    type "%vcvars_output%" 1>&2
    del /q "%vcvars_output%" >nul 2>&1
    exit /b %vcvars_status%
)
del /q "%vcvars_output%" >nul 2>&1

cmake.exe --preset default --log-level=ERROR -DCMAKE_COMPILE_WARNING_AS_ERROR=ON -DSLANG_IGNORE_ABORT_MSG=ON
if errorlevel 1 exit /b %errorlevel%

cmake.exe --build build --config %build_config%
