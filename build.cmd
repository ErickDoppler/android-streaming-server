@echo off
rem ===========================================================================
rem  build.cmd - builds android-streaming-server on Windows.
rem
rem  "Building" here means
rem
rem    1. find the toolchain (tools\ first, then this machine's JDK / SDK)
rem    2. check every source file the APK needs is present
rem    3. run the Gradle build
rem    4. verify the APK really contains the manifest, the dex and the
rem       viewer page - a Gradle "BUILD SUCCESSFUL" alone is not proof
rem    5. stage a runnable dist\ with the installable APK in it
rem
rem    build.cmd                 debug APK - signed with the local debug key,
rem                              so it installs straight onto a device
rem    build.cmd --release       release APK - smaller, but UNSIGNED, so it
rem                              will not install until you sign it yourself
rem    build.cmd --clean         wipe build outputs first
rem    build.cmd --install       adb-install the result onto the one attached
rem                              device when the build succeeds
rem
rem  Run download-tools.cmd once before the first build.
rem ===========================================================================
setlocal EnableDelayedExpansion
cd /d "%~dp0"

rem AGP 8.7.3 needs JDK >= 17; Gradle 8.11.1 refuses to run on JDK > 23.
set "JDK_FEATURE=17"
set "JDK_MAX=23"
set "ANDROID_PLATFORM=35"
set "BUILD_TOOLS=35.0.0"

set "TOOLS=%CD%\tools"
set "DIST=%CD%\dist"
set "VARIANT=debug"
set "DO_CLEAN="
set "DO_INSTALL="

:args
if "%~1"=="" goto args_done
if /i "%~1"=="--release" set "VARIANT=release"
if /i "%~1"=="--debug" set "VARIANT=debug"
if /i "%~1"=="--clean" set "DO_CLEAN=1"
if /i "%~1"=="--install" set "DO_INSTALL=1"
shift
goto args
:args_done

echo === android-streaming-server : build ^(%VARIANT%^) ===
echo.

rem ----------------------------------------------------- [1/5] the toolchain
echo [1/5] locating the toolchain ...
set "JAVA="
if exist "%TOOLS%\jdk\bin\java.exe" call :try_java "%TOOLS%\jdk\bin\java.exe"
if not defined JAVA if defined JAVA_HOME (
  if exist "%JAVA_HOME%\bin\java.exe" call :try_java "%JAVA_HOME%\bin\java.exe"
)
if not defined JAVA (
  for /f "delims=" %%p in ('where java 2^>nul') do (
    if not defined JAVA call :try_java "%%p"
  )
)
if not defined JAVA goto fail_no_jdk
for %%j in ("!JAVA!") do set "JAVA_BIN=%%~dpj"
for %%j in ("!JAVA_BIN!..") do set "JAVA_HOME=%%~fj"
echo       JDK !JAVA_MAJOR!  ^(!JAVA_HOME!^)

set "SDK="
call :try_sdk "%TOOLS%\android-sdk"
if not defined SDK (
  if exist "local.properties" (
    for /f "usebackq tokens=1,* delims==" %%a in ("local.properties") do (
      if /i "%%a"=="sdk.dir" (
        set "LP=%%b"
        set "LP=!LP:\\=\!"
        set "LP=!LP:\:=:!"
        call :try_sdk "!LP!"
      )
    )
  )
)
if not defined SDK call :try_sdk "%ANDROID_HOME%"
if not defined SDK call :try_sdk "%ANDROID_SDK_ROOT%"
if not defined SDK call :try_sdk "%LOCALAPPDATA%\Android\Sdk"
if not defined SDK goto fail_no_sdk

rem Gradle reads the SDK path from local.properties, so keep it in sync.
rem Forward slashes avoid the java.util.Properties backslash-escape trap.
set "SDK_FWD=!SDK:\=/!"
> local.properties echo sdk.dir=!SDK_FWD!
set "ANDROID_HOME=!SDK!"
set "ANDROID_SDK_ROOT=!SDK!"
echo       Android SDK  ^(!SDK!^)

rem ------------------------------------------------------- [2/5] the sources
echo [2/5] checking sources ...
set "MISSING="
call :need "settings.gradle.kts"
call :need "build.gradle.kts"
call :need "app\build.gradle.kts"
call :need "app\src\main\AndroidManifest.xml"
call :need "app\src\main\assets\index.html"
call :need "app\src\main\java\com\example\streamserver\MainActivity.kt"
call :need "app\src\main\java\com\example\streamserver\StreamRelay.kt"
call :need "app\src\main\java\com\example\streamserver\StreamPlayerView.kt"
if not "!MISSING!"=="" (
  echo [FAIL] missing source file^(s^):!MISSING!
  goto die
)
rem versionName = "1.4"  ->  split on the quote character itself.
set "VERSION="
for /f tokens^=2^ delims^=^" %%v in ('findstr /r /c:"versionName *=" app\build.gradle.kts') do (
  if not defined VERSION set "VERSION=%%v"
)
if not defined VERSION set "VERSION=0"
set "MIN_SDK="
for /f "tokens=2 delims==" %%v in ('findstr /r /c:"minSdk *=" app\build.gradle.kts') do (
  if not defined MIN_SDK set "MIN_SDK=%%v"
)
set "MIN_SDK=!MIN_SDK: =!"
echo       Streaming Server v!VERSION!  ^(minSdk !MIN_SDK!, compileSdk %ANDROID_PLATFORM%^)

rem --------------------------------------------------------- [3/5] the build
if defined DO_CLEAN (
  echo [3/5] cleaning, then building ...
  call "%~dp0gradlew.bat" --console=plain clean
  if errorlevel 1 goto fail_gradle
) else (
  echo [3/5] building ...
)
if /i "%VARIANT%"=="release" (
  call "%~dp0gradlew.bat" --console=plain assembleRelease
  if errorlevel 1 goto fail_gradle
  set "APK="
  for %%f in ("app\build\outputs\apk\release\*.apk") do (
    if not defined APK set "APK=%CD%\app\build\outputs\apk\release\%%~nxf"
  )
) else (
  call "%~dp0gradlew.bat" --console=plain assembleDebug
  if errorlevel 1 goto fail_gradle
  set "APK=%CD%\app\build\outputs\apk\debug\app-debug.apk"
)
if not defined APK goto fail_no_apk
if not exist "!APK!" goto fail_no_apk

rem -------------------------------------------------------- [4/5] verify it
echo [4/5] verifying the APK ...
call :in_apk "AndroidManifest.xml"
if errorlevel 1 goto fail_apk_content
call :in_apk "classes.dex"
if errorlevel 1 goto fail_apk_content
call :in_apk "assets/index.html"
if errorlevel 1 goto fail_apk_content
echo       manifest + dex + viewer page present

rem -------------------------------------------------------- [5/5] stage dist
echo [5/5] staging dist\ ...
if exist "%DIST%" rmdir /s /q "%DIST%"
mkdir "%DIST%"
if /i "%VARIANT%"=="release" (
  set "OUT=%DIST%\streaming-server-!VERSION!-release-unsigned.apk"
) else (
  set "OUT=%DIST%\streaming-server-!VERSION!-debug.apk"
)
copy /y "!APK!" "!OUT!" >nul
if errorlevel 1 goto fail_stage
if exist "readme.md" copy /y "readme.md" "%DIST%\README.md" >nul
if exist "LICENSE" copy /y "LICENSE" "%DIST%\LICENSE" >nul

set "SIZE="
for %%f in ("!OUT!") do set /a SIZE=%%~zf / 1024

rem ---------------------------------------------------------------- install
set "ADB=!SDK!\platform-tools\adb.exe"
if not exist "!ADB!" (
  set "ADB="
  for /f "delims=" %%p in ('where adb 2^>nul') do (
    if not defined ADB set "ADB=%%p"
  )
)
if defined DO_INSTALL (
  if /i "%VARIANT%"=="release" goto fail_install_unsigned
  if not defined ADB goto fail_no_adb
  echo.
  echo installing on the attached device ...
  "!ADB!" install -r "!OUT!"
  if errorlevel 1 goto fail_install
  "!ADB!" shell am start -n com.example.streamserver/.MainActivity >nul 2>nul
  echo started com.example.streamserver on the device
)

echo.
echo BUILD OK
echo.
echo   APK:  !OUT!  ^(!SIZE! KB^)
echo.
if /i "%VARIANT%"=="release" (
  echo   This release APK is UNSIGNED. Sign it before installing:
  echo     "!SDK!\build-tools\%BUILD_TOOLS%\apksigner.bat" sign --ks my.jks --out streaming-server.apk "!OUT!"
) else (
  if defined ADB (
    echo   Install it:   "!ADB!" install -r "!OUT!"
  ) else (
    echo   Install it:   adb install -r "!OUT!"
  )
  echo   Or copy the APK to the device and tap it.
)
echo.
echo   Once running, the app prints the one TCP port it serves on. Publishers
echo   connect to  ^<device-ip^>:^<port^>  and viewers open  http://^<device-ip^>:^<port^>
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
if !JMAJOR! LSS %JDK_FEATURE% exit /b 0
if !JMAJOR! GTR %JDK_MAX% exit /b 0
set "JAVA=%~1"
set "JAVA_MAJOR=!JMAJOR!"
exit /b 0

rem try_sdk <dir> - sets SDK when that SDK can build this project.
:try_sdk
if "%~1"=="" exit /b 0
if not exist "%~1\platforms\android-%ANDROID_PLATFORM%" exit /b 0
if not exist "%~1\build-tools\%BUILD_TOOLS%" exit /b 0
set "SDK=%~1"
exit /b 0

rem need <file> - appends to MISSING when the file is not there.
:need
if not exist "%~1" set "MISSING=!MISSING! %~1"
exit /b 0

rem in_apk <entry> - errorlevel 1 when the APK does not contain that entry.
:in_apk
"!JAVA_HOME!\bin\jar.exe" tf "!APK!" 2>nul | findstr /x /c:"%~1" >nul
exit /b %errorlevel%

rem --------------------------------------------------------------- failures
:fail_no_jdk
echo.
echo [FAIL] no usable JDK found ^(need %JDK_FEATURE%..%JDK_MAX%: the Android
echo        plugin needs %JDK_FEATURE%+, Gradle 8.11.1 refuses to run on
echo        anything newer than %JDK_MAX%^).
echo        Run  download-tools.cmd  to fetch a private JDK %JDK_FEATURE%.
goto die

:fail_no_sdk
echo.
echo [FAIL] no Android SDK with platform android-%ANDROID_PLATFORM% and
echo        build-tools %BUILD_TOOLS% was found.
echo        Run  download-tools.cmd  to fetch one into tools\.
goto die

:fail_gradle
echo.
echo [FAIL] the Gradle build failed - see the error above.
goto die

:fail_no_apk
echo.
echo [FAIL] Gradle reported success but produced no APK.
goto die

:fail_apk_content
echo.
echo [FAIL] the APK is missing an entry it must contain - not usable.
goto die

:fail_stage
echo.
echo [FAIL] could not stage dist\ - is a file in it open or read-only?
goto die

:fail_install_unsigned
echo.
echo [FAIL] the release APK is unsigned and cannot be installed.
echo        Sign it first, or build without --release.
goto die

:fail_no_adb
echo.
echo [FAIL] adb not found - cannot --install.
goto die

:fail_install
echo.
echo [FAIL] adb could not install the APK - is a device attached and
echo        USB debugging enabled?  ^("adb devices" should list it^)
goto die

:die
echo.
echo BUILD FAILED
endlocal
exit /b 1
