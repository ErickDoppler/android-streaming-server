@echo off
rem ===========================================================================
rem  download-tools.cmd - fetches every tool needed to build this project on
rem  Windows.
rem
rem  Building the APK needs three things, and this script provides all of them
rem  without touching the system: nothing is installed system-wide, nothing
rem  touches the registry or PATH, no Android Studio.
rem
rem    1. a JDK 17        -^> tools\jdk          (Eclipse Temurin, portable)
rem    2. the Android SDK -^> tools\android-sdk  (command-line tools only:
rem       platform-tools + platforms;android-35 + build-tools;35.0.0)
rem    3. Gradle 8.11.1   -^> fetched by gradlew.bat itself, into %%USERPROFILE%%\.gradle
rem
rem  It also writes local.properties, so build.cmd finds the SDK afterwards.
rem
rem    download-tools.cmd          reuse a usable JDK / SDK already on this
rem                                machine, download only what is missing
rem    download-tools.cmd --force  ignore what is installed and download
rem                                private copies into tools\
rem
rem  Downloads come from api.adoptium.net and dl.google.com over HTTPS and are
rem  verified against the checksums those projects publish.
rem ===========================================================================
setlocal EnableDelayedExpansion
cd /d "%~dp0"

rem AGP 8.7.3 needs JDK >= 17; Gradle 8.11.1 refuses to run on JDK > 23.
set "JDK_FEATURE=17"
set "JDK_MAX=23"
set "ANDROID_PLATFORM=35"
set "BUILD_TOOLS=35.0.0"
set "CMDLINE_TOOLS_BUILD=11076708"
rem SHA-1 published by Google in repository2-3.xml for the ZIP above.
set "CMDLINE_SHA1=3d2917302740f476999a091bc5558837c7a863c5"

set "TOOLS=%CD%\tools"
set "JDK_HOME=%TOOLS%\jdk"
set "SDK_HOME=%TOOLS%\android-sdk"
set "DL=%TOOLS%\download"

set "FORCE="
if /i "%~1"=="--force" set "FORCE=1"
if /i "%~1"=="-f" set "FORCE=1"

echo === android-streaming-server : download-tools ===
echo.

rem ================================================================ [1/3] JDK
echo [1/3] JDK %JDK_FEATURE%
set "JAVA="

if defined FORCE goto want_jdk
if not exist "%JDK_HOME%\bin\java.exe" goto jdk_on_machine
set "JAVA=%JDK_HOME%\bin\java.exe"
call :java_major "!JAVA!"
echo [ok]   private JDK !JMAJOR! already in tools\jdk
goto jdk_done

:jdk_on_machine
rem A JDK already on this machine is fine if Gradle 8.11.1 can run on it.
if not defined JAVA_HOME goto jdk_on_path
if not exist "%JAVA_HOME%\bin\java.exe" goto jdk_on_path
call :try_java "%JAVA_HOME%\bin\java.exe"
if defined JAVA goto jdk_done

:jdk_on_path
for /f "delims=" %%p in ('where java 2^>nul') do (
  if not defined JAVA call :try_java "%%p"
)
if defined JAVA goto jdk_done

:want_jdk
echo [..]   resolving the latest Temurin %JDK_FEATURE% for windows-x64 ...
if not exist "%DL%" mkdir "%DL%"
set "API=https://api.adoptium.net/v3/assets/latest/%JDK_FEATURE%/hotspot?os=windows&architecture=x64&image_type=jdk&vendor=eclipse"
set "FURL=%API%"&set "FDST=%DL%\jdk.json"&call :fetch
if errorlevel 1 goto fail_download

rem Pick the .zip package - the .msi installer ends differently.
set "JDK_URL="
for /f "delims=" %%u in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "$j = Get-Content -Raw '%DL%\jdk.json' | ConvertFrom-Json; $b = @($j)[0].binary.package; if ($b -and $b.link -like '*.zip') { $b.link }"') do set "JDK_URL=%%u"
if not defined JDK_URL goto fail_no_jdk

for %%f in ("!JDK_URL!") do set "JDK_NAME=%%~nxf"
set "JDK_FILE=%DL%\!JDK_NAME!"
echo [..]   downloading !JDK_NAME! ^(~190 MB^) ...
set "FURL=!JDK_URL!"&set "FDST=!JDK_FILE!"&call :fetch
if errorlevel 1 goto fail_download

echo [..]   verifying SHA-256 ...
set "FJDK=!JDK_FILE!"
set "FURL=!JDK_URL!.sha256.txt"&set "FDST=!JDK_FILE!.sha256.txt"&call :fetch
if errorlevel 1 goto fail_download
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; try { $want = ((Get-Content $env:FDST -Raw).Trim() -split '\s+')[0].ToLower(); $got = (Get-FileHash -Algorithm SHA256 $env:FJDK).Hash.ToLower(); if ($want -ne $got) { Write-Host ('       want ' + $want); Write-Host ('       got  ' + $got); exit 1 } } catch { Write-Host ('       ' + $_.Exception.Message); exit 1 }; exit 0"
if errorlevel 1 goto fail_jdk_checksum
echo [ok]   checksum matches Adoptium's published SHA-256

echo [..]   unpacking ...
if exist "%DL%\jdk-unpack" rmdir /s /q "%DL%\jdk-unpack"
mkdir "%DL%\jdk-unpack"
call :unzip "!JDK_FILE!" "%DL%\jdk-unpack"
set "JDK_SRC="
for /d %%d in ("%DL%\jdk-unpack\*") do (
  if exist "%%d\bin\java.exe" set "JDK_SRC=%%d"
)
if not defined JDK_SRC goto fail_unpack
if exist "%JDK_HOME%" rmdir /s /q "%JDK_HOME%"
if not exist "%TOOLS%" mkdir "%TOOLS%"
move "!JDK_SRC!" "%JDK_HOME%" >nul
if not exist "%JDK_HOME%\bin\java.exe" goto fail_unpack
set "JAVA=%JDK_HOME%\bin\java.exe"
call :java_major "!JAVA!"
echo [ok]   private JDK !JMAJOR! installed in tools\jdk

:jdk_done
for %%j in ("!JAVA!") do set "JAVA_BIN=%%~dpj"
for %%j in ("!JAVA_BIN!..") do set "JAVA_HOME=%%~fj"
echo.

rem ======================================================== [2/3] Android SDK
echo [2/3] Android SDK ^(platform %ANDROID_PLATFORM%, build-tools %BUILD_TOOLS%^)
set "SDK="

if defined FORCE goto want_sdk
call :try_sdk "%SDK_HOME%"
if defined SDK goto sdk_done
call :try_sdk "%ANDROID_HOME%"
if defined SDK goto sdk_done
call :try_sdk "%ANDROID_SDK_ROOT%"
if defined SDK goto sdk_done
call :try_sdk "%LOCALAPPDATA%\Android\Sdk"
if defined SDK goto sdk_done

:want_sdk
set "SDK=%SDK_HOME%"
set "SDKMANAGER=%SDK%\cmdline-tools\latest\bin\sdkmanager.bat"
if exist "%SDKMANAGER%" if not defined FORCE (
  echo [ok]   command-line tools already in tools\android-sdk
  goto sdk_packages
)

set "ZIP=commandlinetools-win-%CMDLINE_TOOLS_BUILD%_latest.zip"
echo [..]   downloading the Android command-line tools ...
if not exist "%DL%" mkdir "%DL%"
set "FURL=https://dl.google.com/android/repository/%ZIP%"&set "FDST=%DL%\%ZIP%"&call :fetch
if errorlevel 1 goto fail_download

echo [..]   verifying SHA-1 ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; try { $got = (Get-FileHash -Algorithm SHA1 $env:FDST).Hash.ToLower(); if ($got -ne $env:CMDLINE_SHA1) { Write-Host ('       want ' + $env:CMDLINE_SHA1); Write-Host ('       got  ' + $got); exit 1 } } catch { Write-Host ('       ' + $_.Exception.Message); exit 1 }; exit 0"
if errorlevel 1 goto fail_sdk_checksum
echo [ok]   checksum matches Google's repository manifest

echo [..]   unpacking ...
if exist "%DL%\cmdline-unpack" rmdir /s /q "%DL%\cmdline-unpack"
mkdir "%DL%\cmdline-unpack"
call :unzip "%DL%\%ZIP%" "%DL%\cmdline-unpack"
if not exist "%DL%\cmdline-unpack\cmdline-tools\bin\sdkmanager.bat" goto fail_unpack
rem sdkmanager insists on living in cmdline-tools\<channel>\.
if exist "%SDK%\cmdline-tools" rmdir /s /q "%SDK%\cmdline-tools"
mkdir "%SDK%\cmdline-tools"
move "%DL%\cmdline-unpack\cmdline-tools" "%SDK%\cmdline-tools\latest" >nul
if not exist "%SDKMANAGER%" goto fail_unpack
echo [ok]   command-line tools installed in tools\android-sdk

:sdk_packages
set "SDKMANAGER=%SDK%\cmdline-tools\latest\bin\sdkmanager.bat"
rem sdkmanager asks "Accept? (y/N)" once per licence and reads plain stdin.
rem Neither PowerShell nor a cmd pipe reliably feeds stdin to a .bat, but
rem redirecting from a file does - so the y's go through a scratch file.
set "YESFILE=%TEMP%\ass-yes-%RANDOM%.txt"
> "!YESFILE!" (for /l %%i in (1,1,80) do @echo y)

echo [..]   accepting the SDK licences ...
call "%SDKMANAGER%" --sdk_root="%SDK%" --licenses < "!YESFILE!" >nul 2>nul
if not exist "%SDK%\licenses\android-sdk-license" goto fail_licenses

echo [..]   installing platform-tools, platforms;android-%ANDROID_PLATFORM% and
echo        build-tools;%BUILD_TOOLS%  ^(a few hundred MB, please wait^) ...
call "%SDKMANAGER%" --sdk_root="%SDK%" "platform-tools" "platforms;android-%ANDROID_PLATFORM%" "build-tools;%BUILD_TOOLS%" < "!YESFILE!"
if errorlevel 1 goto fail_sdkmanager
del "!YESFILE!" 2>nul
if not exist "%SDK%\platforms\android-%ANDROID_PLATFORM%" goto fail_sdkmanager
if not exist "%SDK%\build-tools\%BUILD_TOOLS%" goto fail_sdkmanager
echo [ok]   Android SDK ready in tools\android-sdk

:sdk_done
echo.

rem ========================================== [3/3] local.properties + Gradle
echo [3/3] wiring the build

rem local.properties is machine-local and git-ignored: it is how Gradle finds
rem the SDK. It is rewritten on every run, so a moved tools\ keeps working.
rem Forward slashes avoid the java.util.Properties backslash-escape trap.
set "SDK_FWD=%SDK:\=/%"
> local.properties echo sdk.dir=%SDK_FWD%
echo [ok]   local.properties -^> sdk.dir=%SDK_FWD%

echo [..]   priming the Gradle wrapper ^(downloads Gradle on the first run^) ...
set "GRADLE_VER="
for /f "tokens=2" %%v in ('call "%~dp0gradlew.bat" --version 2^>nul ^| findstr /b /c:"Gradle "') do set "GRADLE_VER=%%v"
if defined GRADLE_VER (
  echo [ok]   Gradle !GRADLE_VER! is ready
) else (
  echo [warn] could not run gradlew.bat now - it will fetch Gradle during the
  echo        first build instead.
)

if exist "%DL%" rmdir /s /q "%DL%"

echo.
echo All build tools are in place.
echo.
echo   JDK          %JAVA_HOME%
echo   Android SDK  %SDK%
echo.
echo Next:  build.cmd
echo.
endlocal
exit /b 0

rem ---------------------------------------------------------------- helpers

rem java_major <java.exe> - sets JMAJOR to the feature version (17, 21, ...).
rem "java -version" prints to stderr, and a for /f command may not start with
rem a quoted path, so the banner goes through a temp file.
:java_major
set "JMAJOR="
set "JVTMP=%TEMP%\ass-java-%RANDOM%.txt"
"%~1" -version > "!JVTMP!" 2>&1
for /f "tokens=3" %%v in ('findstr /i /c:" version " "!JVTMP!"') do (
  if not defined JMAJOR (
    set "RAW=%%~v"
    for /f "tokens=1 delims=._-" %%a in ("!RAW!") do set "JMAJOR=%%a"
  )
)
del "!JVTMP!" 2>nul
rem Java 8 and older report 1.8.0_xxx - the feature number is the second field.
if "!JMAJOR!"=="1" set "JMAJOR=8"
exit /b 0

rem try_java <java.exe> - sets JAVA when that JDK is in the supported range.
:try_java
call :java_major "%~1"
if "!JMAJOR!"=="" exit /b 0
if !JMAJOR! LSS %JDK_FEATURE% (
  echo [..]   JDK !JMAJOR! at %~1 is older than %JDK_FEATURE%
  exit /b 0
)
if !JMAJOR! GTR %JDK_MAX% (
  echo [..]   JDK !JMAJOR! at %~1 is newer than %JDK_MAX% - Gradle 8.11.1 cannot use it
  exit /b 0
)
set "JAVA=%~1"
echo [ok]   JDK !JMAJOR! found at %~1 - usable, no download needed
echo        ^(run "download-tools.cmd --force" for a private copy anyway^)
exit /b 0

rem try_sdk <dir> - sets SDK when that SDK can already build this project.
:try_sdk
if "%~1"=="" exit /b 0
if not exist "%~1\platforms\android-%ANDROID_PLATFORM%" exit /b 0
if not exist "%~1\build-tools\%BUILD_TOOLS%" exit /b 0
set "SDK=%~1"
echo [ok]   usable Android SDK found at %~1
exit /b 0

rem fetch - downloads FURL to FDST. curl.exe when present, else PowerShell.
rem
rem The URL is passed in a variable, NOT as an argument: "call" runs one extra
rem round of percent expansion over its command line, and Adoptium's download
rem links contain %2B (an encoded "+"), which that round would eat.
:fetch
where curl >nul 2>nul
if %errorlevel%==0 (
  curl -fsSL --retry 3 --proto "=https" -o "!FDST!" "!FURL!"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $ProgressPreference = 'SilentlyContinue'; try { Invoke-WebRequest -Uri $env:FURL -OutFile $env:FDST -UseBasicParsing; exit 0 } catch { Write-Host $_.Exception.Message; exit 1 }"
)
if errorlevel 1 exit /b 1
rem A 0-byte file means the transfer died silently - treat it as a failure.
for %%f in ("!FDST!") do if %%~zf EQU 0 exit /b 1
if not exist "!FDST!" exit /b 1
exit /b 0

rem unzip <zip> <destination directory>
:unzip
where tar >nul 2>nul
if %errorlevel%==0 (
  tar -xf "%~1" -C "%~2"
  exit /b %errorlevel%
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '%~1' -DestinationPath '%~2' -Force"
exit /b %errorlevel%

rem --------------------------------------------------------------- failures
:fail_download
echo.
echo [FAIL] a download failed. Check the network / proxy and try again.
goto die

:fail_no_jdk
echo.
echo [FAIL] api.adoptium.net offered no JDK %JDK_FEATURE% build for windows-x64.
echo        Install a JDK %JDK_FEATURE% yourself and set JAVA_HOME, then re-run.
goto die

:fail_jdk_checksum
echo.
echo [FAIL] SHA-256 of the JDK archive does not match Adoptium's.
echo        The download was corrupted or tampered with - nothing installed.
goto die

:fail_sdk_checksum
echo.
echo [FAIL] SHA-1 of %ZIP% does not match Google's repository manifest.
echo        The download was corrupted or tampered with - nothing installed.
goto die

:fail_unpack
echo.
echo [FAIL] an archive did not unpack as expected.
goto die

:fail_licenses
echo.
echo [FAIL] the Android SDK licences were not accepted, so nothing can be
echo        installed. Accept them by hand with:
echo          "%SDK%\cmdline-tools\latest\bin\sdkmanager.bat" --sdk_root="%SDK%" --licenses
goto die

:fail_sdkmanager
echo.
echo [FAIL] sdkmanager could not install the SDK packages.
echo        Re-run the script; a partial download usually resumes cleanly.
goto die

:die
echo.
echo DOWNLOAD FAILED
endlocal
exit /b 1
