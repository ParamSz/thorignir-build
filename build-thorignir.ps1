$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Fail([string]$Message) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host " ERROR: $Message" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    throw $Message
}

function Require-Path([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path)) {
        Fail "$Label no encontrado: $Path"
    }
}

$repo = $env:APPVEYOR_BUILD_FOLDER
if ([string]::IsNullOrWhiteSpace($repo)) {
    $repo = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$sourceZip = Join-Path $repo "Thorignir-7.3.5-Updated.zip"
Require-Path $sourceZip "ZIP original de Thorignir"

$work = "C:\thorignir-26972"
$src = Join-Path $work "Thorignir-7.3.5-Updated"
$build = Join-Path $work "build"
$install = Join-Path $work "server"

Write-Host "============================================================"
Write-Host " THORIGNIR 7.3.5 26972 - COMPILADOR MSVC 2019"
Write-Host "============================================================"
Write-Host "[1/8] Limpiando area temporal..."
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work | Out-Null

Write-Host "[2/8] Extrayendo SOURCE ORIGINAL, sin parches Linux..."
Expand-Archive -LiteralPath $sourceZip -DestinationPath $work -Force
Require-Path (Join-Path $src "CMakeLists.txt") "CMakeLists.txt de Thorignir"

# ------------------------------------------------------------
# EXACTAMENTE la rama de dependencias que pide este source.
# AppVeyor mantiene Boost 1.64 y MySQL 5.7 en sus imÃ¡genes.
# ------------------------------------------------------------
$boostRoot = "C:\Libraries\boost_1_64_0"
$boostLib = Join-Path $boostRoot "lib64-msvc-14.1"
Require-Path (Join-Path $boostRoot "boost\version.hpp") "Boost 1.64 headers"
Require-Path $boostLib "Boost 1.64 MSVC 14.1 x64 libs"

$mysqlRoot = "C:\Program Files\MySQL\MySQL Server 5.7"
$mysqlInclude = Join-Path $mysqlRoot "include"
$mysqlLibrary = Join-Path $mysqlRoot "lib\libmysql.lib"
Require-Path (Join-Path $mysqlInclude "mysql.h") "MySQL 5.7 headers"
Require-Path $mysqlLibrary "MySQL 5.7 libmysql.lib"

Write-Host "[3/8] Buscando OpenSSL 1.1.1 x64..."
$opensslRoot = $null
$opensslCandidates = @(
    "C:\OpenSSL-v111-Win64",
    "C:\OpenSSL-Win64"
)

foreach ($candidate in $opensslCandidates) {
    $opensslExe = Join-Path $candidate "bin\openssl.exe"
    if (Test-Path $opensslExe) {
        $ver = (& $opensslExe version 2>$null) -join " "
        Write-Host "  $candidate -> $ver"
        if ($ver -match "^OpenSSL 1\.1\.1") {
            $opensslRoot = $candidate
            break
        }
    }
}

if (-not $opensslRoot) {
    Fail "No encontre OpenSSL 1.1.1 x64 en la imagen."
}

Write-Host "[4/8] Preparando CMake 3.16.4 exacto..."
$cmakeRoot = Join-Path $work "cmake-3.16.4-win64-x64"
$cmakeExe = Join-Path $cmakeRoot "bin\cmake.exe"

if (-not (Test-Path $cmakeExe)) {
    $cmakeZip = Join-Path $work "cmake-3.16.4-win64-x64.zip"
    $cmakeUrl = "https://github.com/Kitware/CMake/releases/download/v3.16.4/cmake-3.16.4-win64-x64.zip"
    Invoke-WebRequest -UseBasicParsing -Uri $cmakeUrl -OutFile $cmakeZip
    Expand-Archive -LiteralPath $cmakeZip -DestinationPath $work -Force
}
Require-Path $cmakeExe "CMake 3.16.4"

$env:BOOST_ROOT = $boostRoot
$env:BOOST_LIBRARYDIR = $boostLib
$env:MYSQL_ROOT = $mysqlRoot
$env:OPENSSL_ROOT_DIR = $opensslRoot

Write-Host ""
Write-Host "----- TOOLCHAIN -----"
& $cmakeExe --version
Write-Host "BOOST_ROOT=$env:BOOST_ROOT"
Write-Host "BOOST_LIBRARYDIR=$env:BOOST_LIBRARYDIR"
& (Join-Path $opensslRoot "bin\openssl.exe") version
Write-Host "MYSQL_ROOT=$env:MYSQL_ROOT"
Write-Host "---------------------"
Write-Host ""

New-Item -ItemType Directory -Path $build -Force | Out-Null
New-Item -ItemType Directory -Path $install -Force | Out-Null

Write-Host "[5/8] Generando Visual Studio 2019 x64..."
$configureArgs = @(
    "-S", $src,
    "-B", $build,
    "-G", "Visual Studio 15 2017",
    "-A", "x64",
    "-DCMAKE_INSTALL_PREFIX=$install",
    "-DBOOST_ROOT=$boostRoot",
    "-DBOOST_LIBRARYDIR=$boostLib",
    "-DOPENSSL_ROOT_DIR=$opensslRoot",
    "-DMYSQL_INCLUDE_DIR=$mysqlInclude",
    "-DMYSQL_LIBRARY=$mysqlLibrary",
    "-DSERVERS=ON",
    "-DSCRIPTS=ON",
    "-DTOOLS=OFF",
    "-DUSE_COREPCH=OFF",
    "-DUSE_SCRIPTPCH=OFF",
    "-DWITHOUT_GIT=ON",
    "-DWITH_SOURCE_TREE=no"
)

& $cmakeExe @configureArgs
if ($LASTEXITCODE -ne 0) { Fail "CMake configure fallo con codigo $LASTEXITCODE" }

Write-Host "[6/8] Compilando Thorignir con MSVC 2019..."
& $cmakeExe --build $build --config Release --target INSTALL -- /m:2
if ($LASTEXITCODE -ne 0) { Fail "MSVC build fallo con codigo $LASTEXITCODE" }

Write-Host "[7/8] Verificando binarios y copiando DLL runtime..."
$world = Get-ChildItem -Path $install -Filter "worldserver.exe" -Recurse -File | Select-Object -First 1
$bnet = Get-ChildItem -Path $install -Filter "bnetserver.exe" -Recurse -File | Select-Object -First 1

if (-not $world) { Fail "worldserver.exe no fue generado" }
if (-not $bnet) { Fail "bnetserver.exe no fue generado" }

$binDir = Split-Path -Parent $world.FullName
Write-Host "worldserver: $($world.FullName)"
Write-Host "bnetserver:  $($bnet.FullName)"

$mysqlDll = Get-ChildItem -Path $mysqlRoot -Filter "libmysql.dll" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
if ($mysqlDll) {
    Copy-Item $mysqlDll.FullName $binDir -Force
    Write-Host "Copiado: $($mysqlDll.Name)"
} else {
    Write-Warning "No encontre libmysql.dll automaticamente."
}

$sslDlls = Get-ChildItem -Path $opensslRoot -Filter "*.dll" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match "^(libssl|libcrypto)" }

foreach ($dll in $sslDlls) {
    Copy-Item $dll.FullName $binDir -Force
    Write-Host "Copiado: $($dll.Name)"
}

$info = @"
Thorignir Legion V3 7.3.5 build 26972
Compilado en AppVeyor
Toolchain: Visual Studio 2019 x64
Boost: 1.64.0 / lib64-msvc-14.1
CMake: 3.16.4
OpenSSL: 1.1.1 x64
MySQL client headers/libs: MySQL 5.7 x64

SOURCE: Thorignir-7.3.5-Updated.zip ORIGINAL
No se aplicaron los parches Linux/GCC usados en intentos anteriores.
"@
Set-Content -LiteralPath (Join-Path $install "BUILD-INFO.txt") -Value $info -Encoding UTF8

Write-Host "[8/8] Empaquetando artifact..."
$artifact = Join-Path $repo "Thorignir-26972-Windows-x64.zip"
if (Test-Path $artifact) { Remove-Item $artifact -Force }

Compress-Archive -Path (Join-Path $install "*") -DestinationPath $artifact -CompressionLevel Optimal

Require-Path $artifact "Artifact final"
$sizeMb = [Math]::Round((Get-Item $artifact).Length / 1MB, 2)

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " OK - THORIGNIR COMPILADO" -ForegroundColor Green
Write-Host " Artifact: $artifact" -ForegroundColor Green
Write-Host " Tamano:   $sizeMb MB" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green

