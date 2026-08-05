@echo off
setlocal

set "VERSION=%DAYFLOW_GRADLE_VERSION%"
if "%VERSION%"=="" set "VERSION=9.6.1"
if "%GRADLE_USER_HOME%"=="" set "GRADLE_USER_HOME=%USERPROFILE%\.gradle"
set "CACHE_DIR=%GRADLE_USER_HOME%\wrapper\dists\dayflow-%VERSION%"
set "GRADLE_HOME=%CACHE_DIR%\gradle-%VERSION%"
set "ARCHIVE=%CACHE_DIR%\gradle-%VERSION%-bin.zip"

if not exist "%GRADLE_HOME%\bin\gradle.bat" (
  if not exist "%CACHE_DIR%" mkdir "%CACHE_DIR%"
  if not exist "%ARCHIVE%" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; Invoke-WebRequest -Uri 'https://services.gradle.org/distributions/gradle-%VERSION%-bin.zip' -OutFile '%ARCHIVE%'"
    if errorlevel 1 exit /b %errorlevel%
  )
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -Force '%ARCHIVE%' '%CACHE_DIR%'"
  if errorlevel 1 exit /b %errorlevel%
)

call "%GRADLE_HOME%\bin\gradle.bat" %*
exit /b %errorlevel%
