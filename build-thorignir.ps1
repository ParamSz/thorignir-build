$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

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
$lastLog = Join-Path $repo "thorignir-build-last.log"

Write-Host "============================================================"
Write-Host " THORIGNIR 7.3.5 26972 - FINAL AUTOFIX / MSVC 2017"
Write-Host "============================================================"

# -----------------------------------------------------------------
# Mantener /build para cache incremental de AppVeyor.
# Limpiamos solamente source + install.
# -----------------------------------------------------------------
Write-Host "[1/9] Preparando area de trabajo..."
New-Item -ItemType Directory -Path $work -Force | Out-Null
if (Test-Path $src) { Remove-Item $src -Recurse -Force }
if (Test-Path $install) { Remove-Item $install -Recurse -Force }
New-Item -ItemType Directory -Path $install -Force | Out-Null

Write-Host "[2/9] Extrayendo source ORIGINAL..."
Expand-Archive -LiteralPath $sourceZip -DestinationPath $work -Force
Require-Path (Join-Path $src "CMakeLists.txt") "CMakeLists.txt de Thorignir"

# -----------------------------------------------------------------
# Helpers de parcheo. El source tiene ficheros antiguos no UTF-8.
# Windows-1252 conserva los bytes de esos fuentes.
# -----------------------------------------------------------------
$SourceEncoding = [System.Text.Encoding]::GetEncoding(1252)

function Read-Source([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, $SourceEncoding)
}

function Write-Source([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, $SourceEncoding)
}

function Ensure-After([string]$Path, [string]$Needle, [string]$Insert, [string]$Label) {
    $txt = Read-Source $Path
    if ($txt.Contains($Insert.Trim())) {
        Write-Host "  OK: $Label"
        return
    }

    if (-not $txt.Contains($Needle)) {
        Fail "AUTOFIX no encontro ancla para $Label en $Path"
    }

    $txt = $txt.Replace($Needle, $Needle + $Insert)
    Write-Source $Path $txt
    Write-Host "  FIX: $Label"
}

Write-Host "[3/9] Aplicando AUTOFIX completo..."

# 1. FunctionProcessor: headers que faltan
$fp = Join-Path $src "src\common\Utilities\FunctionProcessor.h"
Ensure-After $fp "#include <map>`r`n" "#include <functional>`r`n#include <atomic>`r`n" "FunctionProcessor functional/atomic"

# 2. Windows.h redefine GetMessage -> GetMessageA y rompe protobuf
$pbjson = Join-Path $src "src\server\shared\JSON\ProtobufJSON.cpp"
$txt = Read-Source $pbjson
if (-not $txt.Contains("#undef GetMessage")) {
    if ($txt.Contains("#include <stack>`r`n")) {
        $txt = $txt.Replace(
            "#include <stack>`r`n",
            "#include <stack>`r`n`r`n#ifdef GetMessage`r`n#undef GetMessage`r`n#endif`r`n"
        )
    } else {
        $txt = "#ifdef GetMessage`r`n#undef GetMessage`r`n#endif`r`n" + $txt
    }
    Write-Source $pbjson $txt
    Write-Host "  FIX: ProtobufJSON GetMessageA"
} else {
    Write-Host "  OK: ProtobufJSON GetMessageA"
}

# 3. ObjectGuid usa std::map pero no incluye <map>
$objectGuid = Join-Path $src "src\server\game\Entities\Object\ObjectGuid.h"
Ensure-After $objectGuid "#include <list>`r`n" "#include <map>`r`n" "ObjectGuid <map>"

# 4. HashFuctor instancia std::hash<ObjectGuid> con ObjectGuid incompleto.
#    Hacemos el header autosuficiente; esto elimina la cascada LootMgr/libcds.
$hashFuctor = Join-Path $src "src\common\Utilities\HashFuctor.h"
Ensure-After $hashFuctor "#include `"Define.h`"`r`n" "#include `"ObjectGuid.h`"`r`n" "HashFuctor ObjectGuid completo"

# 5. GridObject dependia de includes transitivos del PCH
$gridObject = Join-Path $src "src\server\game\Entities\Object\GridObject.h"
Ensure-After $gridObject "#define GridObject_h__`r`n" "`r`n#include <algorithm>`r`n#include <cstddef>`r`n#include <vector>`r`n" "GridObject STL"

# 6. EventMap usa Seconds/Minutes + macros PAIR64 sin incluir sus headers
$eventMap = Join-Path $src "src\server\game\AI\EventMap.h"
Ensure-After $eventMap "#include `"Common.h`"`r`n" "#include `"Duration.h`"`r`n#include `"ObjectDefines.h`"`r`n" "EventMap Duration/ObjectDefines"

# 7. AreaTrigger usa tipos por puntero que no estaban declarados
$areaTrigger = Join-Path $src "src\server\game\Entities\AreaTrigger\AreaTrigger.h"
$txt = Read-Source $areaTrigger
if (-not $txt.Contains("class Aura;")) {
    $txt = $txt.Replace("class AreaTriggerAI;`r`n", "class AreaTriggerAI;`r`nclass Aura;`r`nstruct SpellValue;`r`n")
}
if (-not $txt.Contains("class MoveSpline;")) {
    $txt = $txt.Replace("namespace Movement`r`n{`r`n", "namespace Movement`r`n{`r`n    class MoveSpline;`r`n")
}
Write-Source $areaTrigger $txt
Write-Host "  FIX: AreaTrigger forwards"

# 8. UnitAI hace static_cast Player* -> Unit* y llama metodos de Player:
#    Player debe ser un tipo completo.
$unitAI = Join-Path $src "src\server\game\AI\CoreAI\UnitAI.h"
Ensure-After $unitAI "#include `"Unit.h`"`r`n" "#include `"Player.h`"`r`n" "UnitAI Player completo"

# 9. bnet Session usa sConfigMgr
$session = Join-Path $src "src\server\bnetserver\Server\Session.cpp"
Ensure-After $session "#include `"Database/DatabaseEnv.h`"`r`n" "#include `"Configuration/Config.h`"`r`n" "bnet Session ConfigMgr"

# 10. Thorignir trae includes internos del CRT de otra version de Windows SDK.
#     Solo se usan M_PI/M_PI_2/M_PI_4, asi que los hacemos portables.
$mathCompat = @"
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#ifndef M_PI_2
#define M_PI_2 1.57079632679489661923
#endif
#ifndef M_PI_4
#define M_PI_4 0.785398163397448309616
#endif
"@

Get-ChildItem -Path $src -Recurse -File -Include *.cpp,*.h | ForEach-Object {
    $p = $_.FullName
    $t = Read-Source $p
    if ($t.Contains("#include <corecrt_math_defines.h>")) {
        $t = $t.Replace("#include <corecrt_math_defines.h>", $mathCompat.Trim())
        Write-Source $p $t
        Write-Host "  FIX: CRT math -> $($_.Name)"
    }
}

# 11. Hay solo unas pocas anotaciones C++17 metidas en un core C++14.
#     Quitarlas es menos invasivo que forzar TODO el core antiguo a C++17.
Get-ChildItem -Path $src -Recurse -File -Include *.cpp,*.h | ForEach-Object {
    $p = $_.FullName
    $t = Read-Source $p
    if ($t.Contains("[[nodiscard]]")) {
        $t = $t.Replace("[[nodiscard]] ", "")
        $t = $t.Replace("[[nodiscard]]", "")
        Write-Source $p $t
        Write-Host "  FIX: nodiscard C++17 -> $($_.Name)"
    }
}

Write-Host "  AUTOFIX completo."

# -----------------------------------------------------------------
# Toolchain que corresponde a este core
# -----------------------------------------------------------------
$boostRoot = "C:\Libraries\boost_1_64_0"
$boostLib = Join-Path $boostRoot "lib64-msvc-14.1"
Require-Path (Join-Path $boostRoot "boost\version.hpp") "Boost 1.64 headers"
Require-Path $boostLib "Boost 1.64 MSVC 14.1 x64 libs"

$mysqlRoot = "C:\Program Files\MySQL\MySQL Server 5.7"
$mysqlInclude = Join-Path $mysqlRoot "include"
$mysqlLibrary = Join-Path $mysqlRoot "lib\libmysql.lib"
Require-Path (Join-Path $mysqlInclude "mysql.h") "MySQL 5.7 headers"
Require-Path $mysqlLibrary "MySQL 5.7 libmysql.lib"

Write-Host "[4/9] Buscando OpenSSL..."
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
        if (-not $opensslRoot) {
            $opensslRoot = $candidate
        }
        if ($ver -match "^OpenSSL 1\.1\.1") {
            $opensslRoot = $candidate
            break
        }
    }
}
if (-not $opensslRoot) { Fail "No encontre OpenSSL x64." }

Write-Host "[5/9] Preparando CMake 3.16.4..."
$cmakeRoot = Join-Path $work "cmake-3.16.4-win64-x64"
$cmakeExe = Join-Path $cmakeRoot "bin\cmake.exe"

if (-not (Test-Path $cmakeExe)) {
    $cmakeZip = Join-Path $work "cmake-3.16.4-win64-x64.zip"
    $cmakeUrl = "https://github.com/Kitware/CMake/releases/download/v3.16.4/cmake-3.16.4-win64-x64.zip"
    Invoke-WebRequest -UseBasicParsing -Uri $cmakeUrl -OutFile $cmakeZip
    Expand-Archive -LiteralPath $cmakeZip -DestinationPath $work -Force
}
Require-Path $cmakeExe "CMake 3.16.4"

# VS2017 + Boost 1.64 msvc-14.1: pareja exacta ya validada por el build anterior.
$vsCandidates = @(
    "C:\Program Files (x86)\Microsoft Visual Studio\2017\Community",
    "C:\Program Files (x86)\Microsoft Visual Studio\2017\Professional",
    "C:\Program Files (x86)\Microsoft Visual Studio\2017\Enterprise"
)
$vs2017 = $vsCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $vs2017) { Fail "No encontre Visual Studio 2017 en la imagen AppVeyor." }

$env:BOOST_ROOT = $boostRoot
$env:BOOST_LIBRARYDIR = $boostLib
$env:MYSQL_ROOT = $mysqlRoot
$env:OPENSSL_ROOT_DIR = $opensslRoot

Write-Host ""
Write-Host "----- TOOLCHAIN FINAL -----"
& $cmakeExe --version
Write-Host "Visual Studio 2017 x64 / MSVC 14.1"
Write-Host "Boost 1.64: $boostRoot"
Write-Host "MySQL 5.7:  $mysqlRoot"
& (Join-Path $opensslRoot "bin\openssl.exe") version
Write-Host "PCH CORE:   ON"
Write-Host "PCH SCRIPT: ON"
Write-Host "C++:        14 (nodiscard custom eliminado)"
Write-Host "---------------------------"
Write-Host ""

Write-Host "[6/9] Configurando CMake con PCH ACTIVADO..."
New-Item -ItemType Directory -Path $build -Force | Out-Null

$configureArgs = @(
    "-S", $src,
    "-B", $build,
    "-G", "Visual Studio 15 2017 Win64",
    "-DCMAKE_INSTALL_PREFIX=$install",
    "-DCMAKE_CXX_STANDARD=14",
    "-DCMAKE_CXX_STANDARD_REQUIRED=ON",
    "-DCMAKE_CXX_EXTENSIONS=OFF",
    "-DBOOST_ROOT=$boostRoot",
    "-DBOOST_LIBRARYDIR=$boostLib",
    "-DBoost_NO_SYSTEM_PATHS=ON",
    "-DBoost_NO_BOOST_CMAKE=ON",
    "-DOPENSSL_ROOT_DIR=$opensslRoot",
    "-DMYSQL_INCLUDE_DIR=$mysqlInclude",
    "-DMYSQL_LIBRARY=$mysqlLibrary",
    "-DSERVERS=ON",
    "-DSCRIPTS=ON",
    "-DTOOLS=OFF",
    "-DUSE_COREPCH=ON",
    "-DUSE_SCRIPTPCH=ON",
    "-DWITHOUT_GIT=ON",
    "-DWITH_SOURCE_TREE=no"
)

$oldPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& $cmakeExe @configureArgs 2>&1 | ForEach-Object { Write-Host $_ }
$cmakeCode = $LASTEXITCODE
$ErrorActionPreference = $oldPreference
if ($cmakeCode -ne 0) { Fail "CMake configure fallo con codigo $cmakeCode" }

Write-Host "[7/9] Compilando con TODOS los cores (/m)..."
if (Test-Path $lastLog) { Remove-Item $lastLog -Force }

$oldPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& $cmakeExe --build $build --config Release --target INSTALL -- /m 2>&1 |
    Tee-Object -FilePath $lastLog |
    ForEach-Object { Write-Host $_ }
$buildCode = $LASTEXITCODE
$ErrorActionPreference = $oldPreference

if ($buildCode -ne 0) {
    Write-Host ""
    Write-Host "----- PRIMEROS ERRORES REALES -----" -ForegroundColor Yellow
    Select-String -Path $lastLog -Pattern "error C[0-9]+|fatal error|LNK[0-9]+" |
        Select-Object -First 35 |
        ForEach-Object { Write-Host $_.Line -ForegroundColor Yellow }
    Fail "MSVC build fallo con codigo $buildCode. Log guardado como thorignir-build-last.log"
}

Write-Host "[8/9] Verificando binarios..."
$world = Get-ChildItem -Path $install -Filter "worldserver.exe" -Recurse -File | Select-Object -First 1
$bnet = Get-ChildItem -Path $install -Filter "bnetserver.exe" -Recurse -File | Select-Object -First 1

if (-not $world) { Fail "worldserver.exe no fue generado" }
if (-not $bnet) { Fail "bnetserver.exe no fue generado" }

$binDir = Split-Path -Parent $world.FullName
Write-Host "  worldserver: $($world.FullName)"
Write-Host "  bnetserver:  $($bnet.FullName)"

$mysqlDll = Get-ChildItem -Path $mysqlRoot -Filter "libmysql.dll" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
if ($mysqlDll) {
    Copy-Item $mysqlDll.FullName $binDir -Force
    Write-Host "  DLL: $($mysqlDll.Name)"
}

$sslDlls = Get-ChildItem -Path $opensslRoot -Filter "*.dll" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match "^(libssl|libcrypto|ssleay|libeay)" }
foreach ($dll in $sslDlls) {
    Copy-Item $dll.FullName $binDir -Force
    Write-Host "  DLL: $($dll.Name)"
}

# Thorignir termina enlazando contra OpenSSL 1.0.2u de AppVeyor.
# worldserver.exe importa exactamente SSLEAY32.dll y LIBEAY32.dll.
$legacyOpenSsl = "C:\OpenSSL-Win64"
foreach ($dllName in @("SSLEAY32.dll", "LIBEAY32.dll")) {
    $dll = Get-ChildItem -Path $legacyOpenSsl -Filter $dllName -Recurse -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $dll) {
        Fail "Falta runtime OpenSSL requerido: $dllName"
    }
    Copy-Item $dll.FullName $binDir -Force
    Write-Host "  DLL legacy requerida: $($dll.Name)"
}

$info = @"
Thorignir Legion 7.3.5 build 26972
Source base: Thorignir-7.3.5-Updated.zip
Compiler: Visual Studio 2017 x64 / MSVC 14.1
Boost: 1.64
CMake: 3.16.4
MySQL headers/libs: 5.7
PCH core/scripts: ON
C++ standard: 14

Autofixes:
- FunctionProcessor functional/atomic
- Protobuf GetMessage/GetMessageA
- ObjectGuid <map>
- HashFuctor ObjectGuid complete type
- GridObject STL headers
- EventMap Duration/ObjectDefines
- AreaTrigger forward declarations
- UnitAI complete Player type
- bnet Session ConfigMgr
- portable M_PI/M_PI_2/M_PI_4 instead of corecrt_math_defines.h
- removed 4 custom [[nodiscard]] annotations that forced C++17
"@
Set-Content -LiteralPath (Join-Path $install "BUILD-INFO.txt") -Value $info -Encoding UTF8

Write-Host "[9/9] Empaquetando artifact..."
$artifact = Join-Path $repo "Thorignir-26972-Windows-x64.zip"
if (Test-Path $artifact) { Remove-Item $artifact -Force }
Compress-Archive -Path (Join-Path $install "*") -DestinationPath $artifact -CompressionLevel Optimal
Require-Path $artifact "Artifact final"

$sizeMb = [Math]::Round((Get-Item $artifact).Length / 1MB, 2)

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " OK - THORIGNIR 26972 COMPILADO" -ForegroundColor Green
Write-Host " worldserver.exe + bnetserver.exe generados" -ForegroundColor Green
Write-Host " Artifact: Thorignir-26972-Windows-x64.zip ($sizeMb MB)" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green

