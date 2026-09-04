<#
  Tortoise-WoW (Shyalya fork) - One-Click Compile + Setup Script
  =================================================================
  Everything lives under the folder this script sits in - nothing outside it,
  except Git/CMake/VS Build Tools themselves (genuine system tools, not project
  data) which install via winget if missing.

  From a completely bare Windows machine, this:
    1. Installs Git, CMake, VS2022 Build Tools (C++ workload) via winget
    2. Sets up a portable MariaDB (zip, no service, no install) in .\DB
    3. Installs ACE + Boost via vcpkg
    4. Clones the source, fetches its submodules (Eluna - the Lua scripting
       engine upstream pins under src\modules\Eluna), configures, builds and
       installs the server
    5. Creates the 4 game databases, the 'mangos' DB user, imports world
       content + ALL migrations (recursively - a batch of them live in a
       'world' subfolder) + playerbot tables
    6. Generates mangosd.conf / realmd.conf / aiplayerbot.conf / ahbot.conf
       from their .dist templates, patches the DB port into them, tunes a
       few first-run settings, and inserts the realm row using the EXACT
       WorldServerPort from the generated config (this exact mismatch was
       the cause of "connects then bounces back to realm select")
    7. (Optional) extracts client data if $ClientDir is set below
    8. Writes start-database.bat / start-realmd.bat / start-mangosd.bat /
       start-all.bat launchers for every future start - no more retyping
       paths or remembering start order

  Genuinely still manual after this:
    - Extracting client data, UNLESS you set $ClientDir below (experimental -
      see the note on that setting)
    - Creating your GM account (needs mangosd's own interactive console)
  Everything else that bit us during testing - the DB user, the recursive
  migrations, the config DB ports, the realm port mismatch - is now handled.
#>

# ---------------- CONFIG - edit these if you want something different ----------------
# Everything below lives under the folder this script sits in.
$RootDir         = $PSScriptRoot

$RepoUrl         = "https://github.com/Shyalya/tortoise-wow.git"
$Branch          = "playerbots-integration-gh"
$SourceDir       = "$RootDir\source"
$VcpkgDir        = "$RootDir\vcpkg"
$InstallPrefix   = "$RootDir\server"
$BuildPlayerbots  = $true     # $false = a server with no bots at all
$BuildDungeonClear = $true    # smarter bot dungeon-clearing module; requires playerbots
$BuildEluna       = $true     # Lua scripting engine (Eluna). It is a Git SUBMODULE upstream, so the
                               # source alone is not enough - this script fetches it (see step 5b).
                               # Only set $false if that submodule can't be downloaded on your machine;
                               # you then get a server with no Lua scripts at all.
$UseExtractors    = $true     # $false only if you already have dbc/maps/vmaps/mmaps

$DbFolder        = "$RootDir\DB"   # portable MariaDB lives here, not installed as a service
$DbPort          = 3307            # off the default 3306 so it never collides with a real install
$DbRootPassword  = ""              # blank = no password (fine for localhost-only dev use)
$MariaDbVersion  = "11.4.10"       # LTS branch, zip package

$RealmName       = "Tortoise"
$RealmAddress    = "127.0.0.1"     # your PC's LAN IP instead, if other devices will connect
$FirstRunBotCount = 10             # AiPlayerbot.Min/MaxRandomBots for the first start - raise later,
                                    # the shipped template asks for 1000 which makes first start crawl

# EXPERIMENTAL - leave blank to skip. If set to your Turtle WoW 1.18.1 (build 7272) client
# folder, the script will try to run the data extractors for you (dbc/maps/vmaps/mmaps).
# This is the single biggest remaining manual step, but the extractor tools sometimes prompt
# for input the script may not answer correctly - if this section fails or hangs, Ctrl+C it
# and follow the manual steps printed at the end instead. mmap generation alone is often an
# hour or more, extractor tool included.
$ClientDir       = ""
# ---------------------------------------------------------------------------------------

$ErrorActionPreference = "Stop"
function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "[OK] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "`n[FAILED] $msg" -ForegroundColor Red; Read-Host "`nPress Enter to close"; exit 1 }

if ($BuildDungeonClear -and -not $BuildPlayerbots) {
    Warn "DungeonClear requires BUILD_PLAYERBOTS; disabling DungeonClear for this build."
    $BuildDungeonClear = $false
}

# ---------------------------------------------------------------------------------------
# 0. Relaunch elevated - winget installs (esp. VS Build Tools) need admin rights
# ---------------------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Restarting as Administrator (needed to install software)..." -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

Write-Host "Tortoise-WoW one-click compiler + setup" -ForegroundColor Magenta
Write-Host "Everything lives under: $RootDir"
Write-Host "  source:   $SourceDir"
Write-Host "  vcpkg:    $VcpkgDir"
Write-Host "  server:   $InstallPrefix"
Write-Host "  database: $DbFolder (portable, port $DbPort)"
Write-Host "Playerbots: $BuildPlayerbots | DungeonClear: $BuildDungeonClear | Eluna (Lua): $BuildEluna | Extractors: $UseExtractors | Client data automation: $(if ($ClientDir) {$ClientDir} else {'off (manual)'})"
Write-Host "(Git, CMake, and VS Build Tools install system-wide if missing - those are dev tools, not project data)`n"

if ($RootDir.Length -gt 40) {
    Warn "This script's folder path is $($RootDir.Length) characters long ($RootDir). vcpkg's Boost builds generate very long nested paths internally and can fail past Windows' ~260 char limit. If the build step fails with 'path too long' or similar, move this script (and its folder) somewhere shorter, like C:\TWoW, and re-run."
}

# ---------------------------------------------------------------------------------------
# 1. Prerequisites - install via winget if missing
# ---------------------------------------------------------------------------------------
Step "Checking / installing prerequisites"

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Fail "winget isn't available on this machine. Install 'App Installer' from the Microsoft Store (search 'App Installer'), then re-run this script. See install-prerequisites-guide.txt (next to this script) for fully manual install links if you'd rather not use winget at all."
}

function Install-Winget($wingetId, $displayName, $overrideArgs = $null) {
    Write-Host "Installing $displayName via winget..."
    $args = @("install", "--id", $wingetId, "-e", "--accept-package-agreements", "--accept-source-agreements", "--silent")
    if ($overrideArgs) { $args += @("--override", $overrideArgs) }
    & winget @args
    if ($LASTEXITCODE -ne 0) { Fail "winget failed to install $displayName. See install-prerequisites-guide.txt for a manual install instead." }
    Ok "$displayName installed"
}

# winget does NOT reliably add a package to PATH - not for this session, and sometimes not
# even persistently, regardless of the installer's own "add to PATH" option. Rather than trust
# PATH at all, check (and if needed, add) each tool's known default install folder directly -
# the same approach already used below for vswhere, which never relied on PATH either.
function Test-OrAddToPath($exeName, $knownDirs) {
    if (Get-Command $exeName -ErrorAction SilentlyContinue) { return $true }
    foreach ($dir in $knownDirs) {
        if (Test-Path "$dir\$exeName") {
            $env:Path = "$env:Path;$dir"
            return $true
        }
    }
    return $false
}

$gitDirs   = @("$env:ProgramFiles\Git\cmd", "$env:ProgramFiles\Git\bin")
$cmakeDirs = @("$env:ProgramFiles\CMake\bin", "${env:ProgramFiles(x86)}\CMake\bin")

if (Test-OrAddToPath "git.exe" $gitDirs) { Ok "Git already installed" }
else {
    Install-Winget "Git.Git" "Git"
    if (-not (Test-OrAddToPath "git.exe" $gitDirs)) { Fail "Git installed via winget but still can't be found at its usual location ($($gitDirs -join ' or ')). It may have installed somewhere non-default - add its folder to PATH manually and re-run." }
}

if (Test-OrAddToPath "cmake.exe" $cmakeDirs) { Ok "CMake already installed" }
else {
    Install-Winget "Kitware.CMake" "CMake"
    if (-not (Test-OrAddToPath "cmake.exe" $cmakeDirs)) { Fail "CMake installed via winget but still can't be found at its usual location ($($cmakeDirs -join ' or ')). It may have installed somewhere non-default - add its folder to PATH manually and re-run." }
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = $null
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}
if (-not $vsPath) {
    Install-Winget "Microsoft.VisualStudio.2022.BuildTools" "Visual Studio 2022 Build Tools (C++ workload)" `
        "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
    $vsPath = & $vswhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vsPath) {
        Fail "VS Build Tools installed but the C++ workload still isn't detected. Reboot and re-run this script - a fresh install sometimes needs one before CMake can see the compiler."
    }
}
Ok "Visual Studio C++ tools found ($vsPath)"

# ---------------------------------------------------------------------------------------
# 2. Portable MariaDB - download zip, initialize, start it (no service install)
# ---------------------------------------------------------------------------------------
Step "Setting up portable MariaDB in $DbFolder"

$mariadbBin = "$DbFolder\bin"
$mariadbClient = "$mariadbBin\mariadb.exe"

if (-not (Test-Path "$mariadbBin\mysqld.exe")) {
    New-Item -ItemType Directory -Force -Path $DbFolder | Out-Null
    $zipUrl  = "https://archive.mariadb.org/mariadb-$MariaDbVersion/winx64-packages/mariadb-$MariaDbVersion-winx64.zip"
    $zipPath = "$env:TEMP\mariadb-portable.zip"

    Write-Host "Downloading MariaDB $MariaDbVersion (portable zip)..."
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $DbFolder -Force
    Remove-Item $zipPath -Force

    # The zip contains one mariadb-<version>-winx64 subfolder - flatten it into $DbFolder
    $extracted = Get-ChildItem $DbFolder -Directory | Where-Object { $_.Name -like "mariadb-*" } | Select-Object -First 1
    if ($extracted) {
        Get-ChildItem $extracted.FullName | Move-Item -Destination $DbFolder -Force
        Remove-Item $extracted.FullName -Recurse -Force
    }
    Ok "MariaDB $MariaDbVersion extracted"

    Write-Host "Initializing data directory..."
    # mariadb-install-db.exe on Windows does NOT share flags with the Unix shell script -
    # no --auth-root-authentication-method here, it has its own (small) set of options.
    $installArgs = @("--datadir=$DbFolder\data", "--port=$DbPort")
    if ($DbRootPassword) { $installArgs += "--password=$DbRootPassword" }
    & "$mariadbBin\mariadb-install-db.exe" @installArgs
    if ($LASTEXITCODE -ne 0) { Fail "mariadb-install-db.exe failed to initialize the data directory." }

    Ok "Portable MariaDB initialized"
} else {
    Ok "Portable MariaDB already set up at $DbFolder"
}

# Always (re)write the launcher with the current invocation, even on an existing DB folder.
# No --no-defaults / --defaults-file here - both are special "must be parsed first" flags
# that mysqld doesn't seem to recognize when launched through a .bat on this setup (it
# throws "unknown option" for either one). Plain --datadir/--port/--bind-address are
# ordinary options and work regardless of position, and there's no my.ini anywhere for it
# to find on its own, so nothing extra gets read. --console keeps the window's output visible.
@"
@echo off
"%~dp0bin\mysqld.exe" --datadir="%~dp0data" --port=$DbPort --bind-address=127.0.0.1 --console
"@ | Set-Content "$DbFolder\start-database.bat" -Encoding ASCII

# Start it for this session if it isn't already listening on $DbPort
$listening = $false
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect("127.0.0.1", $DbPort)
    $tcp.Close()
    $listening = $true
} catch {}

if (-not $listening) {
    Write-Host "Starting mysqld.exe (in its own console window)..."
    $mysqldArgs = @("--datadir=$DbFolder\data", "--port=$DbPort", "--bind-address=127.0.0.1", "--console")
    Start-Process -FilePath "$mariadbBin\mysqld.exe" -ArgumentList $mysqldArgs
    $waited = 0
    while (-not $listening -and $waited -lt 30) {
        Start-Sleep -Seconds 1
        $waited++
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", $DbPort)
            $tcp.Close()
            $listening = $true
        } catch {}
    }
    if (-not $listening) { Fail "mysqld.exe didn't start listening on port $DbPort within 30 seconds." }
}
Ok "MariaDB is running on 127.0.0.1:$DbPort"

function Invoke-Sql($sqlText, $db, [string[]]$extraArgs = @()) {
    $sqlArgs = @("-u", "root", "-P", $DbPort, "-h", "127.0.0.1") + $extraArgs
    if ($DbRootPassword) { $sqlArgs += "-p$DbRootPassword" }
    if ($db) { $sqlArgs += $db }
    $sqlText | & $mariadbClient @sqlArgs
    if ($LASTEXITCODE -ne 0 -and ($extraArgs -notcontains "--force")) { Fail "A SQL statement failed against database '$db'. Scroll up for the mariadb error." }
}
function Invoke-SqlFile($file, $db, [string[]]$extraArgs = @()) {
    Invoke-Sql (Get-Content $file -Raw) $db $extraArgs
}
function Invoke-SqlScalar($sqlText, $db) {
    $sqlArgs = @("-u", "root", "-P", $DbPort, "-h", "127.0.0.1", "-N", "-B")
    if ($DbRootPassword) { $sqlArgs += "-p$DbRootPassword" }
    if ($db) { $sqlArgs += $db }
    return ($sqlText | & $mariadbClient @sqlArgs)
}

# ---------------------------------------------------------------------------------------
# 3. vcpkg - clone + bootstrap if missing
# ---------------------------------------------------------------------------------------
Step "Setting up vcpkg (used to fetch ACE and Boost - not bundled in the repo)"
if (-not (Test-Path "$VcpkgDir\vcpkg.exe")) {
    if (-not (Test-Path $VcpkgDir)) {
        git clone https://github.com/microsoft/vcpkg.git $VcpkgDir
        if ($LASTEXITCODE -ne 0) { Fail "Could not clone vcpkg to $VcpkgDir." }
    }
    & "$VcpkgDir\bootstrap-vcpkg.bat"
    if ($LASTEXITCODE -ne 0) { Fail "vcpkg bootstrap failed." }
} else {
    Ok "vcpkg already present at $VcpkgDir"
}

# ---------------------------------------------------------------------------------------
# 4. Install ACE (always) and the specific Boost libs (only if building playerbots)
#    NOTE: no vcpkg toolchain file is used at configure time - this repo pins its own
#    MySQL/OpenSSL/zlib under dep/windows on Windows, and the vcpkg toolchain conflicts.
# ---------------------------------------------------------------------------------------
Step "Installing ACE via vcpkg"
& "$VcpkgDir\vcpkg.exe" install ace:x64-windows
if ($LASTEXITCODE -ne 0) { Fail "vcpkg failed to install ACE." }
Ok "ACE installed"

if ($BuildPlayerbots) {
    Step "Installing Boost libraries via vcpkg (this is the slow part, can take 30-60+ min the first time)"
    $boostLibs = @(
        "boost-algorithm","boost-asio","boost-bimap","boost-bind","boost-filesystem",
        "boost-functional","boost-smart-ptr","boost-stacktrace","boost-thread","boost-system"
    ) | ForEach-Object { "$_`:x64-windows" }
    & "$VcpkgDir\vcpkg.exe" install $boostLibs
    if ($LASTEXITCODE -ne 0) { Fail "vcpkg failed to install the Boost libraries." }
    Ok "Boost installed"
}

# ---------------------------------------------------------------------------------------
# 5. Clone or update the source
# ---------------------------------------------------------------------------------------
Step "Getting the tortoise-wow source ($Branch)"
if (-not (Test-Path $SourceDir)) {
    git clone --branch $Branch $RepoUrl $SourceDir
    if ($LASTEXITCODE -ne 0) { Fail "Could not clone $RepoUrl." }
} else {
    Warn "Source folder already exists at $SourceDir - pulling latest instead of re-cloning."
    Push-Location $SourceDir
    git fetch origin
    git checkout $Branch
    git pull origin $Branch
    Pop-Location
}
Ok "Source ready at $SourceDir"

# ---------------------------------------------------------------------------------------
# 5b. Submodules - Eluna (the Lua scripting engine) is NOT part of the source tree itself,
#     it is a pinned Git submodule at src\modules\Eluna. A plain 'git clone' leaves that
#     folder empty and CMake then stops dead at configure time with:
#         CMake Error at CMakeLists.txt:50 (message):
#           Eluna submodule is missing.  Run: git submodule update --init --recursive
#     So fetch it here - both for a fresh clone and for an existing checkout, where a
#     'git pull' can move the pinned submodule commit and leave the folder stale.
# ---------------------------------------------------------------------------------------
Step "Fetching source submodules (Eluna Lua engine -> src\modules\Eluna)"
Push-Location $SourceDir
git submodule sync --recursive | Out-Null
git submodule update --init --recursive
$submodulesFailed = ($LASTEXITCODE -ne 0)
if ($submodulesFailed) {
    Warn "git submodule update failed (usually a transient network/GitHub hiccup) - retrying once..."
    git submodule update --init --recursive
    $submodulesFailed = ($LASTEXITCODE -ne 0)
}
Pop-Location

# Verify the exact file CMake checks for, so a missing or half-fetched Eluna is caught
# here with a useful message instead of at configure time. Only demanded when this
# checkout really does pin Eluna as a submodule - upstream could move or drop it, and
# then a hard failure here would be wrong. Same reason the configure check below only
# verifies BUILD_ELUNA when this source tree actually has that option.
$gitmodulesPath  = Join-Path $SourceDir ".gitmodules"
$sourceCMakePath = Join-Path $SourceDir "CMakeLists.txt"
$elunaIsSubmodule = (Test-Path $gitmodulesPath) -and ((Get-Content $gitmodulesPath -Raw) -match "src/modules/Eluna")
$elunaSupported   = (Test-Path $sourceCMakePath) -and ((Get-Content $sourceCMakePath -Raw) -match "BUILD_ELUNA")
$elunaProbe = Join-Path $SourceDir "src\modules\Eluna\LuaEngine.h"

if ($BuildEluna -and $elunaIsSubmodule -and -not (Test-Path $elunaProbe)) {
    Fail @"
The Eluna submodule (src\modules\Eluna) did not download, and CMake refuses to configure
without it - that is the 'Eluna submodule is missing' error. Try this by hand in a terminal,
then re-run this script:
    cd $SourceDir
    git submodule update --init --recursive src/modules/Eluna
If GitHub is unreachable from your machine, set `$BuildEluna = `$false near the top of this
script and re-run - you then get a working server with no Lua scripting.
"@
} elseif ($submodulesFailed) {
    Warn "git submodule update still reported a problem, but $(if (Test-Path $elunaProbe) {'Eluna itself is present, so the build can continue'} else {'this checkout does not pin Eluna, so it may not matter'}). If the build later complains about missing submodule files, re-run 'git submodule update --init --recursive' inside $SourceDir."
} else {
    Ok "Submodules up to date$(if (Test-Path $elunaProbe) {' (Eluna present at src\modules\Eluna)'})"
}

# ---------------------------------------------------------------------------------------
# 6. Configure, build, install
# ---------------------------------------------------------------------------------------
Step "Configuring with CMake"
Push-Location $SourceDir
$buildDir = "build"
$vcpkgInstalled = "$VcpkgDir\installed\x64-windows"
$cmakeCache = Join-Path $buildDir "CMakeCache.txt"

# CMake keeps old -D values in an existing build directory. A failed build from
# before the 2026-09 module-system fix can still have playerbots configured as
# disabled even after this script is updated, so explicitly repair that one
# stale cache entry instead of asking users to delete the whole 20+ minute build.
if (Test-Path $cmakeCache) {
    $cacheContent = Get-Content $cmakeCache -Raw
    $cacheContent = $cacheContent -replace '(?m)^BUILD_PLAYERBOTS:BOOL=.*$', "BUILD_PLAYERBOTS:BOOL=$(if ($BuildPlayerbots) {'ON'} else {'OFF'})"
    $cacheContent = $cacheContent -replace '(?m)^USE_EXTRACTORS:BOOL=.*$', "USE_EXTRACTORS:BOOL=$(if ($UseExtractors) {'ON'} else {'OFF'})"
    $cacheContent = $cacheContent -replace '(?m)^BUILD_ELUNA:BOOL=.*$', "BUILD_ELUNA:BOOL=$(if ($BuildEluna) {'ON'} else {'OFF'})"
    $cacheContent = $cacheContent -replace '(?m)^MODULES:[^=]+=.*$', 'MODULES:STRING=disabled'
    $cacheContent = $cacheContent -replace '(?m)^MODULE_MOD_PLAYERBOTS:[^=]+=.*$', "MODULE_MOD_PLAYERBOTS:STRING=$(if ($BuildPlayerbots) {'static'} else {'disabled'})"
    $cacheContent = $cacheContent -replace '(?m)^MODULE_MOD_DUNGEON_CLEAR:[^=]+=.*$', "MODULE_MOD_DUNGEON_CLEAR:STRING=$(if ($BuildDungeonClear) {'static'} else {'disabled'})"
    Set-Content $cmakeCache $cacheContent -Encoding ASCII
}

# Since the 2026-09 playerbots refactor, leave the global module default
# disabled and explicitly enable the static bot modules we want. This avoids
# accidentally pulling in future modules while still letting mod-playerbots and
# mod-dungeon-clear link directly into mangosd on Windows.
$cmakeArgs = @(
    "-S", $SourceDir,
    "-B", $buildDir, "-A", "x64",
    "-DCMAKE_INSTALL_PREFIX=$InstallPrefix",
    "-DUSE_EXTRACTORS=$(if ($UseExtractors) {'ON'} else {'OFF'})",
    "-DBUILD_PLAYERBOTS=$(if ($BuildPlayerbots) {'ON'} else {'OFF'})",
    "-DBUILD_ELUNA=$(if ($BuildEluna) {'ON'} else {'OFF'})",
    "-DMODULES=disabled",
    "-DMODULE_MOD_PLAYERBOTS=$(if ($BuildPlayerbots) {'static'} else {'disabled'})",
    "-DMODULE_MOD_DUNGEON_CLEAR=$(if ($BuildDungeonClear) {'static'} else {'disabled'})",
    "-DACE_ROOT=$vcpkgInstalled"
)
if ($BuildPlayerbots) {
    $cmakeArgs += "-DBOOST_ROOT=$vcpkgInstalled"
}

& cmake @cmakeArgs
if ($LASTEXITCODE -ne 0) {
    $hint = "CMake configure failed. Scroll up for the first 'CMake Error' - the usual causes are:"
    $hint += "`n  - 'Eluna submodule is missing'      -> src\modules\Eluna is empty. Run: git -C `"$SourceDir`" submodule update --init --recursive   (or set `$BuildEluna = `$false and re-run)"
    $hint += "`n  - ACE not found                     -> look for 'Found ACE headers:' above; if missing, the vcpkg ACE install failed"
    $hint += "`n  - a lua.org download failure        -> Eluna's Lua runtime is fetched during configure, so that step needs internet access too"
    Fail $hint
}

if (Test-Path $cmakeCache) {
    $configuredCache = Get-Content $cmakeCache -Raw
    $expectedPlayerbotMode = if ($BuildPlayerbots) { 'ON' } else { 'OFF' }
    $expectedPlayerbotModuleMode = if ($BuildPlayerbots) { 'static' } else { 'disabled' }
    $expectedDungeonClearMode = if ($BuildDungeonClear) { 'static' } else { 'disabled' }
    $expectedElunaMode = if ($BuildEluna) { 'ON' } else { 'OFF' }
    if ($configuredCache -notmatch "(?m)^BUILD_PLAYERBOTS:[^=]+=$expectedPlayerbotMode\s*$" -or
        ($elunaSupported -and $configuredCache -notmatch "(?m)^BUILD_ELUNA:[^=]+=$expectedElunaMode\s*$") -or
        $configuredCache -notmatch "(?m)^MODULE_MOD_PLAYERBOTS:[^=]+=$expectedPlayerbotModuleMode\s*$" -or
        $configuredCache -notmatch "(?m)^MODULE_MOD_DUNGEON_CLEAR:[^=]+=$expectedDungeonClearMode\s*$") {
        Fail "CMake configured but the playerbot/Eluna options do not match this script's settings. Delete $buildDir and re-run if this stale build directory cannot be repaired automatically."
    }
}
Ok "Configure complete"

Step "Building (Release config) - this is the slow part, easily 20-40+ minutes"
cmake --build $buildDir --config Release
if ($LASTEXITCODE -ne 0) { Fail "Build failed. Scroll up to the first red error." }
Ok "Build complete"

Step "Installing into $InstallPrefix"
cmake --install $buildDir --config Release
if ($LASTEXITCODE -ne 0) { Fail "Install step failed." }
Ok "Installed to $InstallPrefix"

Step "Copying required DLLs next to mangosd.exe"
Copy-Item "$vcpkgInstalled\bin\ACE.dll" $InstallPrefix -Force
if ($BuildPlayerbots) { Copy-Item "$vcpkgInstalled\bin\boost_*.dll" $InstallPrefix -Force }
Ok "DLLs copied"

# Eluna reads its scripts from the folder named by Eluna.ScriptPath in mangosd.conf
# ("./lua_scripts", relative to mangosd.exe). The install step copies Eluna's bundled
# extensions into it; make sure it exists regardless, because a missing script path only
# shows up later as confusing Lua errors on first start.
if ($BuildEluna) {
    $luaScriptsDir = Join-Path $InstallPrefix "lua_scripts"
    if (-not (Test-Path $luaScriptsDir)) { New-Item -ItemType Directory -Force -Path $luaScriptsDir | Out-Null }
    Ok "Lua script folder ready: $luaScriptsDir"
}
Pop-Location

# ---------------------------------------------------------------------------------------
# 7. Game databases - create + import into the portable MariaDB
# ---------------------------------------------------------------------------------------
Step "Creating game databases (tw_world, tw_char, tw_logon, tw_logs)"
Invoke-SqlFile "$SourceDir\sql\create_databases.sql" $null
Ok "Databases + base schema created"

Step "Creating the 'mangos' database user (this is the default username/password baked into realmd.conf.dist and mangosd.conf.dist)"
Invoke-Sql @"
CREATE USER IF NOT EXISTS 'mangos'@'localhost' IDENTIFIED BY 'mangos';
CREATE USER IF NOT EXISTS 'mangos'@'127.0.0.1' IDENTIFIED BY 'mangos';
CREATE USER IF NOT EXISTS 'mangos'@'%' IDENTIFIED BY 'mangos';
GRANT ALL PRIVILEGES ON tw_world.* TO 'mangos'@'localhost', 'mangos'@'127.0.0.1', 'mangos'@'%';
GRANT ALL PRIVILEGES ON tw_char.*  TO 'mangos'@'localhost', 'mangos'@'127.0.0.1', 'mangos'@'%';
GRANT ALL PRIVILEGES ON tw_logon.* TO 'mangos'@'localhost', 'mangos'@'127.0.0.1', 'mangos'@'%';
GRANT ALL PRIVILEGES ON tw_logs.*  TO 'mangos'@'localhost', 'mangos'@'127.0.0.1', 'mangos'@'%';
FLUSH PRIVILEGES;
"@ $null
Ok "'mangos' user created and granted on all 4 databases"

Step "Importing world content from sql\base (can take a few minutes)"
Get-ChildItem "$SourceDir\sql\base\*.sql" | ForEach-Object {
    Invoke-SqlFile $_.FullName "tw_world"
}
Ok "sql\base imported"

Step "Applying schema migrations (tolerating duplicate-key errors on purpose, per the repo docs)"
# -Recurse matters: a chunk of the migration files live in subfolders like
# sql\database_updates\world\, not directly in sql\database_updates\. Missing
# those caused a "database structure is not up to date" crash on first start.
Get-ChildItem "$SourceDir\sql\database_updates" -Recurse -Filter "*.sql" | Sort-Object FullName | ForEach-Object {
    if ($_.Name -match '_(character|char)\.sql$') {
        $migrationDb = "tw_char"
    } elseif ($_.Name -match '_(auth|logon)\.sql$') {
        $migrationDb = "tw_logon"
    } else {
        $migrationDb = "tw_world"
    }
    Invoke-SqlFile $_.FullName $migrationDb @("--force")
    Invoke-Sql "INSERT IGNORE INTO migrations (Name,Hash,AppliedAt) VALUES ('$($_.BaseName)','manual',NOW());" $migrationDb
}
Ok "Migrations applied and recorded"

if ($BuildPlayerbots) {
    Step "Importing playerbot tables"
    # The 2026-09 source refactor moved the vendored playerbots module from
    # src\modules\PlayerBots to modules\mod-playerbots. Support both layouts so
    # reruns against an older checkout still work.
    $pbSqlDir = "$SourceDir\modules\mod-playerbots\sql"
    if (-not (Test-Path $pbSqlDir)) { $pbSqlDir = "$SourceDir\src\modules\PlayerBots\sql" }
    if (-not (Test-Path $pbSqlDir)) { Fail "Playerbot SQL directory not found under the checked-out source (expected modules\mod-playerbots\sql)." }
    Get-ChildItem "$pbSqlDir\world\*.sql" | ForEach-Object { Invoke-SqlFile $_.FullName "tw_world" }
    Get-ChildItem "$pbSqlDir\world\classic\*.sql" | ForEach-Object { Invoke-SqlFile $_.FullName "tw_world" }
    Get-ChildItem "$pbSqlDir\characters\*.sql" | ForEach-Object { Invoke-SqlFile $_.FullName "tw_char" }
    Ok "Playerbot tables imported"
}

# ---------------------------------------------------------------------------------------
# 8. Config files - generate from .dist, patch DB port, tune first-run settings
# ---------------------------------------------------------------------------------------
Step "Generating config files from .dist templates"

$configMap = @{
    "mangosd.conf.dist"     = "mangosd.conf"
    "realmd.conf.dist"      = "realmd.conf"
    "aiplayerbot.conf.dist" = "aiplayerbot.conf"
    "ahbot.conf.dist"       = "ahbot.conf"
}
foreach ($distName in $configMap.Keys) {
    $realName = $configMap[$distName]
    $distPath = Join-Path $InstallPrefix $distName
    $realPath = Join-Path $InstallPrefix $realName

    # Upstream installs aiplayerbot.conf.dist, but the current mod-playerbots
    # CMake rules omit ahbot.conf.dist. Copy that template directly from source
    # so AhBot does not silently run without a config file.
    if ($BuildPlayerbots -and $distName -eq "ahbot.conf.dist" -and -not (Test-Path $distPath)) {
        $ahbotTemplate = Join-Path $SourceDir "modules\mod-playerbots\src\ahbot\ahbot.conf.dist.in"
        if (Test-Path $ahbotTemplate) {
            Copy-Item $ahbotTemplate $distPath
            Ok "Copied missing ahbot.conf.dist from mod-playerbots source"
        }
    }

    if (-not (Test-Path $distPath)) { Warn "$distName not found in $InstallPrefix - skipping (playerbot templates only exist if BUILD_PLAYERBOTS was ON)"; continue }
    if (Test-Path $realPath) { Ok "$realName already exists - leaving it alone (delete it and re-run if you want it regenerated)"; continue }
    Copy-Item $distPath $realPath
    Ok "Created $realName"
}

$moduleConfigDir = Join-Path $InstallPrefix "modules"
if ($BuildDungeonClear) {
    $dcDist = Join-Path $moduleConfigDir "mod_dungeon_clear.conf.dist"
    $dcConf = Join-Path $moduleConfigDir "mod_dungeon_clear.conf"
    if (-not (Test-Path $dcDist)) {
        New-Item -ItemType Directory -Force -Path $moduleConfigDir | Out-Null
        $dcTemplate = Join-Path $SourceDir "modules\mod-dungeon-clear\conf\mod_dungeon_clear.conf.dist"
        if (Test-Path $dcTemplate) { Copy-Item $dcTemplate $dcDist }
    }
    if ((Test-Path $dcDist) -and -not (Test-Path $dcConf)) {
        Copy-Item $dcDist $dcConf
        Ok "Created modules\mod_dungeon_clear.conf"
    } elseif (Test-Path $dcConf) {
        Ok "modules\mod_dungeon_clear.conf already exists - leaving it alone"
    } else {
        Warn "mod_dungeon_clear.conf.dist not found; DungeonClear will use built-in defaults"
    }
}

$mangosdConfPath = Join-Path $InstallPrefix "mangosd.conf"
$realmdConfPath  = Join-Path $InstallPrefix "realmd.conf"
$aiplayerbotConfPath = Join-Path $InstallPrefix "aiplayerbot.conf"

if (Test-Path $mangosdConfPath) {
    $content = Get-Content $mangosdConfPath -Raw
    # Patch the port in every *DatabaseInfo connection string (the templates default to
    # 3306; user/pass/dbname already match what was just created above).
    $content = $content -replace '(127\.0\.0\.1;)\d+(;mangos;mangos;)', "`${1}$DbPort`${2}"
    # We already applied every migration by hand above - the auto-updater would replay them
    # against a mismatched migrations table on a database built this way.
    $content = $content -replace '(?m)^Database\.AutoUpdate\.Enabled\s*=\s*\d+', 'Database.AutoUpdate.Enabled = 0'
    # LogSQL=1 (the template default) writes every SQL statement to disk - with playerbots
    # the first start alone is tens of thousands of inserts computing the gear cache.
    $content = $content -replace '(?m)^LogSQL\s*=\s*\d+', 'LogSQL = 0'
    Set-Content $mangosdConfPath $content -Encoding ASCII -NoNewline
    Ok "Patched mangosd.conf (DB port -> $DbPort, AutoUpdate off, LogSQL off)"
}
if (Test-Path $realmdConfPath) {
    $content = Get-Content $realmdConfPath -Raw
    $content = $content -replace '(127\.0\.0\.1;)\d+(;mangos;mangos;)', "`${1}$DbPort`${2}"
    Set-Content $realmdConfPath $content -Encoding ASCII -NoNewline
    Ok "Patched realmd.conf (DB port -> $DbPort)"
}
if ($BuildPlayerbots -and (Test-Path $aiplayerbotConfPath)) {
    $content = Get-Content $aiplayerbotConfPath -Raw
    $content = $content -replace '(?m)^AiPlayerbot\.Enabled\s*=\s*\d+', 'AiPlayerbot.Enabled = 1'
    $content = $content -replace '(?m)^AiPlayerbot\.MinRandomBots\s*=\s*\d+', "AiPlayerbot.MinRandomBots = $FirstRunBotCount"
    $content = $content -replace '(?m)^AiPlayerbot\.MaxRandomBots\s*=\s*\d+', "AiPlayerbot.MaxRandomBots = $FirstRunBotCount"
    Set-Content $aiplayerbotConfPath $content -Encoding ASCII -NoNewline
    Ok "Patched aiplayerbot.conf (enabled, bot count -> $FirstRunBotCount for a fast first start - raise it later)"
}

# ---------------------------------------------------------------------------------------
# 9. Realm entry - using the ACTUAL WorldServerPort from the generated config.
#    This exact mismatch (config ships 8090, the realmlist.port column defaults to 8085)
#    is what causes "select realm -> connecting -> bounced back to realm list".
# ---------------------------------------------------------------------------------------
Step "Inserting realm entry"
$worldPort = 8085
if (Test-Path $mangosdConfPath) {
    $mc = Get-Content $mangosdConfPath -Raw
    if ($mc -match '(?m)^WorldServerPort\s*=\s*(\d+)') { $worldPort = $matches[1] }
}
$existingRealms = Invoke-SqlScalar "SELECT COUNT(*) FROM realmlist;" "tw_logon"
if ([int]$existingRealms -eq 0) {
    Invoke-Sql "INSERT INTO realmlist (name, address, port, icon, realmflags, timezone, allowedSecurityLevel, population) VALUES ('$RealmName', '$RealmAddress', $worldPort, 1, 0, 1, 0, 0);" "tw_logon"
    Ok "Realm '$RealmName' inserted at $RealmAddress`:$worldPort (matches mangosd.conf's WorldServerPort)"
} else {
    Ok "realmlist already has $existingRealms row(s) - leaving as-is. If mangosd.conf's WorldServerPort ($worldPort) doesn't match what's in the table, that's the classic 'bounces back to realm select' bug - update it manually."
}

# ---------------------------------------------------------------------------------------
# 10. Client data extraction - EXPERIMENTAL, only runs if $ClientDir is set
# ---------------------------------------------------------------------------------------
if ($ClientDir -and (Test-Path $ClientDir)) {
    Step "Attempting client data extraction into $ClientDir (experimental)"
    $extractTools = @(
        @{ Name = "mapextractor.exe";  Produces = "dbc/maps" },
        @{ Name = "vmapextractor.exe"; Produces = "vmap source data" },
        @{ Name = "vmap_assembler.exe"; Produces = "vmaps" },
        @{ Name = "MoveMapGen.exe";    Produces = "mmaps (slow - an hour or more is normal)" }
    )
    $missingTools = $extractTools | Where-Object { -not (Test-Path (Join-Path $InstallPrefix $_.Name)) }
    if ($missingTools) {
        Warn "Extractor tool(s) not found in $InstallPrefix ($(($missingTools | ForEach-Object { $_.Name }) -join ', ')) - USE_EXTRACTORS may not have been ON. Skipping."
    } else {
        foreach ($tool in $extractTools) {
            Copy-Item (Join-Path $InstallPrefix $tool.Name) $ClientDir -Force
        }
        # Extractors load these project DLLs from their working directory.
        foreach ($dll in @("libmpq.dll", "libmySQL.dll")) {
            $dllPath = Join-Path $InstallPrefix $dll
            if (Test-Path $dllPath) { Copy-Item $dllPath $ClientDir -Force }
        }
        Push-Location $ClientDir
        $extractSteps = $extractTools
        $extractionOk = $true
        foreach ($tool in $extractSteps) {
            if (-not (Test-Path $tool.Name)) { Warn "$($tool.Name) not found in $ClientDir - skipping remaining extraction steps."; $extractionOk = $false; break }
            Write-Host "Running $($tool.Name) -> $($tool.Produces) ..."
            # Auto-answer any Y/N prompts these tools may raise; if a tool needs different
            # input this will not work correctly - check its console output.
            $answers = (("y`r`n") * 20)
            $answers | & ".\$($tool.Name)"
            if ($LASTEXITCODE -ne 0) { Warn "$($tool.Name) exited with a non-zero code - check its output above before trusting the result."; $extractionOk = $false }
        }
        Pop-Location
        if ($extractionOk) {
            foreach ($folder in @("dbc", "maps", "vmaps", "mmaps")) {
                $src = Join-Path $ClientDir $folder
                if (Test-Path $src) {
                    Copy-Item $src $InstallPrefix -Recurse -Force
                    Ok "Copied $folder into $InstallPrefix"
                } else {
                    Warn "$folder wasn't produced in $ClientDir - extraction may have failed partway. Check the output above."
                }
            }
        } else {
            Warn "Client data extraction did not complete cleanly - verify dbc/maps/vmaps/mmaps by hand in $ClientDir, then copy whichever exist into $InstallPrefix."
        }
    }
} else {
    Ok "Client data extraction skipped (`$ClientDir not set) - see the manual steps below"
}

# ---------------------------------------------------------------------------------------
# 11. Launcher scripts - so every future start is one double-click
# ---------------------------------------------------------------------------------------
Step "Writing launcher scripts"

@"
@echo off
cd /d "%~dp0"
realmd.exe
"@ | Set-Content (Join-Path $InstallPrefix "start-realmd.bat") -Encoding ASCII

@"
@echo off
cd /d "%~dp0"
mangosd.exe
"@ | Set-Content (Join-Path $InstallPrefix "start-mangosd.bat") -Encoding ASCII

@"
@echo off
setlocal
echo Checking database...
powershell -NoProfile -Command "try { `$c = New-Object System.Net.Sockets.TcpClient; `$c.Connect('127.0.0.1', $DbPort); `$c.Close(); exit 0 } catch { exit 1 }"
if %ERRORLEVEL% NEQ 0 (
  echo Starting database...
  start "MariaDB" "%~dp0..\DB\start-database.bat"
  timeout /t 8 /nobreak >nul
) else (
  echo Database already running.
)
echo Starting realmd...
start "realmd" "%~dp0start-realmd.bat"
timeout /t 3 /nobreak >nul
echo Starting mangosd - first start can take a long time (migrations + bot travel graph)...
start "mangosd" "%~dp0start-mangosd.bat"
echo.
echo Three windows should now be open: MariaDB, realmd, mangosd.
pause
"@ | Set-Content (Join-Path $InstallPrefix "start-all.bat") -Encoding ASCII

Ok "Wrote start-realmd.bat, start-mangosd.bat, start-all.bat in $InstallPrefix"

# ---------------------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------------------
Step "DONE"
Write-Host "Server binaries + configs: $InstallPrefix" -ForegroundColor Green
Write-Host "Portable database:         $DbFolder  (127.0.0.1:$DbPort, user 'mangos'/'mangos', plus 'root' with $(if ($DbRootPassword) {'the password you set'} else {'no password'}))" -ForegroundColor Green
Write-Host "Realm:                      $RealmName at $RealmAddress`:$worldPort" -ForegroundColor Green
Write-Host "`nTo start the server from now on, just run:  $InstallPrefix\start-all.bat" -ForegroundColor Green
Write-Host "`nGenuinely still manual:" -ForegroundColor Yellow
if (-not ($ClientDir -and (Test-Path $ClientDir))) {
    Write-Host "  1. Extract client data - copy mapextractor.exe, vmapextractor.exe, vmap_assembler.exe and MoveMapGen.exe (plus any DLLs they require) from $InstallPrefix into your Turtle WoW 1.18.1 build 7272 client and run them in that order. Move the resulting dbc/maps/vmaps/mmaps folders into $InstallPrefix."
    Write-Host "     (Set `$ClientDir near the top of this script and re-run to attempt this automatically next time.)"
} else {
    Write-Host "  1. Client data extraction was attempted automatically - double check dbc/maps/vmaps/mmaps landed in $InstallPrefix and look reasonable in size."
}
Write-Host "  2. Put the same address ($RealmAddress) into the client's realmlist.wtf."
Write-Host "  3. Run start-all.bat, then in the mangosd window: account create <name> <password>, then account set gmlevel <name> 3 -1 if you want GM."
if ($BuildEluna) {
    Write-Host "`nLua scripting (Eluna) is built in and enabled by default (Eluna.Enabled in mangosd.conf)." -ForegroundColor Green
    Write-Host "Drop .lua files into $InstallPrefix\lua_scripts - Eluna's own bundled extensions are already there." -ForegroundColor Green
    Write-Host "Heads up: a single Lua state is not thread safe, so while Eluna.Enabled = 1 the core switches" -ForegroundColor Yellow
    Write-Host "continent maps back to single-threaded object/visibility updates (it says so in ElunaErrors.log)." -ForegroundColor Yellow
    Write-Host "If you don't need Lua and want the parallel map updates from RECOMMENDED_mangosd.conf, set Eluna.Enabled = 0." -ForegroundColor Yellow
}
Write-Host "`n(Full detail: $SourceDir\INSTALL-WINDOWS.md, and $SourceDir\docs\ELUNA.md for Lua scripting)" -ForegroundColor Gray
Read-Host "`nPress Enter to close"
