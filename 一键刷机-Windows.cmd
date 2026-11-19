@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0"
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
set "CHECK_ONLY=0"
set "NO_PAUSE=0"
set "FLASH_EXIT=1"
set "PYTHON_EXE="
set "PYTHON_ARGS="
for %%A in (%*) do call :inspect "%%~A"
where py >nul 2>nul
if errorlevel 1 goto find_python
py -3 -c "import sys; sys.exit(sys.version_info < (3, 9))" >nul 2>nul
if errorlevel 1 goto find_python
set "PYTHON_EXE=py"
set "PYTHON_ARGS=-3"
goto run

:find_python
for /f "delims=" %%P in ('where python 2^>nul ^| findstr /v /i "WindowsApps"') do call :try_python "%%P"
if defined PYTHON_EXE goto run
for /d %%D in ("%LocalAppData%\Programs\Python\Python3*") do call :try_python "%%D\python.exe"
if defined PYTHON_EXE goto run
call :try_python "%ProgramFiles%\Python312\python.exe"
if defined PYTHON_EXE goto run
if "%CHECK_ONLY%"=="1" goto missing_python
where winget >nul 2>nul
if errorlevel 1 goto missing_python
if "%CHROMATIC_INSTALL_DEPS%"=="1" goto install_python
echo First setup needs Python 3.12, flash tools and local Python modules.
set /p "APPROVE=Allow dependency installation? Type Y to continue [y/N] "
if /i not "%APPROVE%"=="y" goto finish
set "CHROMATIC_INSTALL_DEPS=1"

:install_python
winget install --id Python.Python.3.12 --exact --source winget --scope user --accept-package-agreements --accept-source-agreements --silent --disable-interactivity
if errorlevel 1 goto finish
call :try_python "%LocalAppData%\Programs\Python\Python312\python.exe"
if defined PYTHON_EXE goto run
where py >nul 2>nul
if errorlevel 1 goto missing_python
py -3 -c "import sys; sys.exit(sys.version_info < (3, 9))" >nul 2>nul
if errorlevel 1 goto missing_python
set "PYTHON_EXE=py"
set "PYTHON_ARGS=-3"

:run
"%PYTHON_EXE%" %PYTHON_ARGS% "%~dp0tools\bootstrap_installer.py" %*
set "FLASH_EXIT=%ERRORLEVEL%"
goto finish

:missing_python
echo Python 3.9 or newer is required. Install Python from https://www.python.org/downloads/windows/
echo Then reopen this script. Check and dry-run modes never install dependencies.
goto finish

:inspect
if /i "%~1"=="--check" set "CHECK_ONLY=1"
if /i "%~1"=="--dry-run" set "CHECK_ONLY=1"
if /i "%~1"=="--help" set "CHECK_ONLY=1"
if /i "%~1"=="-h" set "CHECK_ONLY=1"
if "%CHECK_ONLY%"=="1" set "NO_PAUSE=1"
if /i "%~1"=="--no-pause" set "NO_PAUSE=1"
if /i "%~1"=="--install-deps" set "CHROMATIC_INSTALL_DEPS=1"
exit /b

:try_python
if defined PYTHON_EXE exit /b
if not exist "%~1" exit /b
"%~1" -c "import sys; sys.exit(sys.version_info < (3, 9))" >nul 2>nul
if not errorlevel 1 set "PYTHON_EXE=%~1"
exit /b

:finish
if "%NO_PAUSE%"=="0" pause
exit /b %FLASH_EXIT%
