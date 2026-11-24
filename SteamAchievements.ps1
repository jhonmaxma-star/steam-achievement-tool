[CmdletBinding()]
param(
    [uint32]$OpenAppId,
    [string]$ApiDll,
    [string]$OpenGameName,

    [string]$PreviewPng,

    [string]$CheckOwnership,
    [string]$OwnershipOutput
)
$ErrorActionPreference = 'Stop'

$LaunchLog = Join-Path $env:LOCALAPPDATA 'SteamAchievementSelector\启动日志.txt'
$LaunchMode = if ($CheckOwnership) { '核对' } elseif ($OpenAppId) { "成就 $OpenAppId" } else { '游戏列表' }
function Write-LaunchLog([string]$Message) {
    if ($PreviewPng) { return }
    try {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $LaunchLog))
        $line = '{0:yyyy-MM-dd HH:mm:ss.fff} [{1} {2}] {3}' -f (Get-Date), $PID, $LaunchMode, $Message
        [IO.File]::AppendAllText($LaunchLog, $line + "`r`n", (New-Object Text.UTF8Encoding $true))
        if ((Get-Item -LiteralPath $LaunchLog).Length -gt 200KB) {
            $keep = @([IO.File]::ReadAllLines($LaunchLog) | Select-Object -Last 500)
            [IO.File]::WriteAllLines($LaunchLog, [string[]]$keep, (New-Object Text.UTF8Encoding $true))
        }
    } catch { }
}
Write-LaunchLog "启动，64 位进程=$([Environment]::Is64BitProcess)，STA=$([Threading.Thread]::CurrentThread.ApartmentState -eq 'STA')"

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
} catch {
    Write-LaunchLog "加载 WPF 失败：$($_.Exception.Message)"
    exit 1
}

trap {
    Write-LaunchLog "未处理的错误：$($_.Exception.Message)"
    if (!$PreviewPng) { try { [void][System.Windows.MessageBox]::Show($_.Exception.Message, '出错了', 'OK', 'Error') } catch { } }
    exit 1
}
function Show-Error([string]$Message, [string]$Title = '出错了') {
    if ($PreviewPng) { Add-Content -LiteralPath "$PreviewPng.error.txt" -Value $Message -Encoding UTF8; return }
    [void][System.Windows.MessageBox]::Show($Message, $Title, 'OK', 'Error')
}

$ExcludedAppIds = @(228980)
$ExcludedNamePattern = '^(Proton\b|Steam Linux Runtime|Steamworks Common Redistributables)'
$DataDirectory = Join-Path $env:LOCALAPPDATA 'SteamAchievementSelector'

$CacheFile = Join-Path $DataDirectory 'steam_api_path.txt'

$HistoryFile = Join-Path $DataDirectory '操作记录.csv'

$AppInfoReaderSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace SteamGui {
    public class AppInfo {
        public uint AppId;
        public string Name = "";
        public string Type = "";
        public string ChineseName = "";
    }

    public static class AppInfoReader {
        public static Dictionary<uint, AppInfo> Read(string path) {
            var result = new Dictionary<uint, AppInfo>();
            byte[] data = File.ReadAllBytes(path);
            int pos = 0;
            uint magic = U32(data, ref pos);
            pos += 4;
            bool v29 = magic == 0x07564429;
            bool v28 = magic == 0x07564428;
            if (!v29 && !v28 && magic != 0x07564427) return result;
            string[] table = null;
            if (v29) {
                long tableOffset = BitConverter.ToInt64(data, pos);
                pos += 8;
                int tpos = (int)tableOffset;
                uint count = U32(data, ref tpos);
                table = new string[count];
                for (int i = 0; i < count; i++) table[i] = CString(data, ref tpos);
            }
            while (pos + 4 <= data.Length) {
                uint appId = U32(data, ref pos);
                if (appId == 0) break;
                uint size = U32(data, ref pos);
                int end = pos + (int)size;
                pos += 4 + 4 + 8 + 20 + 4;
                if (v29 || v28) pos += 20;
                var info = new AppInfo { AppId = appId };
                try { ReadSection(data, ref pos, table, info, 0, false, false); } catch { }
                result[appId] = info;
                pos = end;
            }
            return result;
        }

        private static void ReadSection(byte[] d, ref int pos, string[] table, AppInfo info, int depth, bool inCommon, bool inLocalized) {
            while (true) {
                byte type = d[pos++];
                if (type == 8) return;
                string key = table != null ? table[U32(d, ref pos)] : CString(d, ref pos);
                switch (type) {
                    case 0:
                        bool common = depth == 1 && key == "common";
                        bool localized = inCommon && key == "name_localized";
                        ReadSection(d, ref pos, table, info, depth + 1, common, localized);
                        break;
                    case 1:
                        string value = CString(d, ref pos);
                        if (inCommon && depth == 2) {
                            if (key == "name") info.Name = value;
                            else if (key == "type") info.Type = value;
                        } else if (inLocalized && key == "schinese") {
                            info.ChineseName = value;
                        }
                        break;
                    case 2: case 3: case 4: case 6: pos += 4; break;
                    case 7: case 10: pos += 8; break;
                    case 5: CString(d, ref pos); break;
                    default: throw new InvalidDataException("unknown type " + type);
                }
            }
        }

        private static uint U32(byte[] d, ref int pos) { uint v = BitConverter.ToUInt32(d, pos); pos += 4; return v; }

        private static string CString(byte[] d, ref int pos) {
            int start = pos;
            while (d[pos] != 0) pos++;
            string s = Encoding.UTF8.GetString(d, start, pos - start);
            pos++;
            return s;
        }
    }
}
'@

function Get-SteamLibraries {
    try {
        $steam = Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Valve\Steam' -Name SteamPath
    } catch {
        throw '没有检测到 Steam，请先安装并登录 Steam 客户端。'
    }
    $candidates = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        $text = Get-Content -LiteralPath $vdf -Raw -Encoding UTF8
        foreach ($match in [regex]::Matches($text, '(?m)^\s*"path"\s*"([^"]+)"')) {
            $candidates += $match.Groups[1].Value.Replace('\\', '\')
        }
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        $full = [IO.Path]::GetFullPath($candidate).TrimEnd('\')
        if ($seen.Add($full)) { $full }
    }
}

function Get-InstalledSteamApps {
    $seen = @{}
    foreach ($library in Get-SteamLibraries) {
        $steamApps = [IO.Path]::Combine($library, 'steamapps')
        if (![IO.Directory]::Exists($steamApps)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $steamApps -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue) {
            $manifest = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
            $id = [regex]::Match($manifest, '(?m)^\s*"appid"\s*"(\d+)"').Groups[1].Value
            $name = [regex]::Match($manifest, '(?m)^\s*"name"\s*"([^"]+)"').Groups[1].Value
            $installDir = [regex]::Match($manifest, '(?m)^\s*"installdir"\s*"([^"]+)"').Groups[1].Value
            if (!$id -or !$name -or !$installDir -or $seen.ContainsKey($id)) { continue }
            if ($ExcludedAppIds -contains [uint32]$id -or $name -match $ExcludedNamePattern) { continue }
            $directory = [IO.Path]::Combine($steamApps, 'common', $installDir)
            if (!(Test-Path -LiteralPath $directory -PathType Container)) { continue }
            $seen[$id] = $true
            [pscustomobject]@{ AppId = [uint32]$id; Name = $name; DisplayName = $name; Directory = $directory }
        }
    }
}

function Get-SteamUserDirectory {
    try { $steam = Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Valve\Steam' -Name SteamPath } catch { return $null }
    $root = [IO.Path]::Combine($steam, 'userdata')
    if (![IO.Directory]::Exists($root)) { return $null }
    $active = 0
    try { $active = [uint32](Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Valve\Steam\ActiveProcess' -Name ActiveUser) } catch { }
    if ($active) {
        $directory = [IO.Path]::Combine($root, [string]$active)
        if ([IO.Directory]::Exists($directory)) { return $directory }
    }

    Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+$' -and $_.Name -ne '0' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'config\librarycache')) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { $_.FullName }
}

function Get-HiddenAppIds([string]$UserDirectory) {
    $ids = New-Object 'System.Collections.Generic.HashSet[uint32]'
    if (!$UserDirectory) { return , $ids }
    $best = $null
    foreach ($name in 'cloud-storage-namespace-1.json', 'cloud-storage-namespace-1.modified.json') {
        $file = [IO.Path]::Combine($UserDirectory, 'config', 'cloudstorage', $name)
        if (![IO.File]::Exists($file)) { continue }
        try {
            foreach ($entry in (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                if ($entry[0] -ne 'user-collections.hidden' -or !$entry[1].value) { continue }
                if (!$best -or [long]$entry[1].timestamp -gt [long]$best.timestamp) { $best = $entry[1] }
            }
        } catch { }
    }
    if ($best) {
        $collection = $best.value | ConvertFrom-Json
        foreach ($id in @($collection.added)) { [void]$ids.Add([uint32]$id) }
        foreach ($id in @($collection.removed)) { [void]$ids.Remove([uint32]$id) }
    }
    return , $ids
}

function Get-SteamAppInfo {
    $result = @{}
    try { $steam = Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Valve\Steam' -Name SteamPath } catch { return $result }
    $file = [IO.Path]::Combine($steam, 'appcache', 'appinfo.vdf')
    if (![IO.File]::Exists($file)) { return $result }
    if (!('SteamGui.AppInfoReader' -as [type])) { Add-Type -TypeDefinition $AppInfoReaderSource }
    try {
        $all = [SteamGui.AppInfoReader]::Read($file)
        foreach ($key in $all.Keys) { $result[[uint32]$key] = $all[$key] }
    } catch { }
    $result
}

function Format-GameName([string]$Name, [string]$ChineseName) {
    $cjk = '[぀-ヿ㐀-鿿豈-﫿]'
    $ChineseName = "$ChineseName".Trim()
    if (!$ChineseName -or $ChineseName -eq $Name -or $ChineseName -notmatch $cjk) { return $Name }
    if ($Name -match $cjk -or $ChineseName.Contains($Name)) { return $ChineseName }
    "$ChineseName（$Name）"
}

function Get-LibraryGames {
    $appInfo = Get-SteamAppInfo
    $userDirectory = Get-SteamUserDirectory
    $hidden = Get-HiddenAppIds $userDirectory
    $nonGameTypes = @('tool', 'config', 'music', 'dlc', 'video', 'series', 'episode', 'beta')
    $games = @{}

    foreach ($game in Get-InstalledSteamApps) {
        $info = $appInfo[[uint32]$game.AppId]
        if ($info -and $nonGameTypes -contains $info.Type.ToLowerInvariant()) { continue }
        $chinese = if ($info) { $info.ChineseName } else { '' }
        $games[[uint32]$game.AppId] = [pscustomobject]@{
            AppId = [uint32]$game.AppId; Name = $game.Name; DisplayName = (Format-GameName $game.Name $chinese)
            Directory = $game.Directory; Installed = $true; Hidden = $hidden.Contains([uint32]$game.AppId)
        }
    }

    if ($userDirectory) {
        $libraryCache = [IO.Path]::Combine($userDirectory, 'config', 'librarycache')
        foreach ($file in Get-ChildItem -LiteralPath $libraryCache -Filter '*.json' -File -ErrorAction SilentlyContinue) {
            [uint32]$id = 0
            if (![uint32]::TryParse($file.BaseName, [ref]$id) -or !$id -or $games.ContainsKey($id)) { continue }
            $info = $appInfo[$id]
            if (!$info -or !$info.Name) { continue }
            if (@('game', 'demo', 'application') -notcontains $info.Type.ToLowerInvariant()) { continue }
            if ($ExcludedAppIds -contains $id -or $info.Name -match $ExcludedNamePattern) { continue }
            $games[$id] = [pscustomobject]@{
                AppId = $id; Name = $info.Name; DisplayName = (Format-GameName $info.Name $info.ChineseName)
                Directory = $null; Installed = $false; Hidden = $hidden.Contains($id)
            }
        }
    }
    $games.Values
}

function Test-Export([string]$Text, [string]$Name) {

    [regex]::IsMatch($Text, '(?<!\w)' + [regex]::Escape($Name) + '\x00')
}

function Get-LatestAccessor([string]$Text, [string]$Interface) {
    $best = $null
    foreach ($match in [regex]::Matches($Text, '(?<!\w)SteamAPI_' + $Interface + '_v(\d{3})\x00')) {
        if (!$best -or [int]$match.Groups[1].Value -gt [int]$best.Groups[1].Value) { $best = $match }
    }
    if ($best) { 'SteamAPI_{0}_v{1}' -f $Interface, $best.Groups[1].Value }
}

function Get-SteamApiInfo([string]$Path) {
    try {
        $file = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($file.PSIsContainer -or $file.Name -notin @('steam_api.dll', 'steam_api64.dll')) { return $null }
        $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($file.FullName))
    } catch {
        return $null
    }
    $required = @(
        'SteamAPI_RunCallbacks', 'SteamAPI_Shutdown',
        'SteamAPI_ISteamUtils_GetAppID', 'SteamAPI_ISteamUser_GetSteamID',
        'SteamAPI_ISteamUserStats_GetNumAchievements', 'SteamAPI_ISteamUserStats_GetAchievementName',
        'SteamAPI_ISteamUserStats_GetAchievementDisplayAttribute', 'SteamAPI_ISteamUserStats_GetAchievement',
        'SteamAPI_ISteamUserStats_GetAchievementAndUnlockTime',
        'SteamAPI_ISteamUserStats_SetAchievement', 'SteamAPI_ISteamUserStats_ClearAchievement',
        'SteamAPI_ISteamUserStats_StoreStats'
    )
    foreach ($name in $required) { if (!(Test-Export $text $name)) { return $null } }

    $userStats = Get-LatestAccessor $text 'SteamUserStats'
    $user = Get-LatestAccessor $text 'SteamUser'
    $utils = Get-LatestAccessor $text 'SteamUtils'
    if (!$userStats -or !$user -or !$utils) { return $null }

    $initKind = $null
    foreach ($kind in @('InitFlat', 'Init', 'InitSafe')) {
        if (Test-Export $text ('SteamAPI_' + $kind)) { $initKind = $kind; break }
    }
    if (!$initKind) { return $null }

    [pscustomobject]@{
        Path            = $file.FullName
        Is64Bit         = $file.Name -eq 'steam_api64.dll'
        UserStats       = $userStats
        User            = $user
        Utils           = $utils
        InitKind        = $initKind

        HasRequestStats = Test-Export $text 'SteamAPI_ISteamUserStats_RequestCurrentStats'

        HasIcons        = (Test-Export $text 'SteamAPI_ISteamUserStats_GetAchievementIcon') -and
                          (Test-Export $text 'SteamAPI_ISteamUtils_GetImageSize') -and
                          (Test-Export $text 'SteamAPI_ISteamUtils_GetImageRGBA')

        Friends         = Get-LatestAccessor $text 'SteamFriends'

        Apps            = Get-LatestAccessor $text 'SteamApps'
        HasSubscribed   = Test-Export $text 'SteamAPI_ISteamApps_BIsSubscribedApp'
        HasPersonaName  = Test-Export $text 'SteamAPI_ISteamFriends_GetPersonaName'
        HasPercent      = (Test-Export $text 'SteamAPI_ISteamUserStats_RequestGlobalAchievementPercentages') -and
                          (Test-Export $text 'SteamAPI_ISteamUserStats_GetAchievementAchievedPercent') -and
                          (Test-Export $text 'SteamAPI_ISteamUtils_IsAPICallCompleted')
    }
}

function Get-PowerShellPath([bool]$Is64Bit) {
    if ($Is64Bit -eq [Environment]::Is64BitProcess) {
        return (Join-Path $PSHOME 'powershell.exe')
    }
    if ($Is64Bit) { $engine = Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe' }
    else { $engine = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe' }
    if (!(Test-Path -LiteralPath $engine)) { throw '找不到对应位数的 Windows PowerShell。' }
    $engine
}

function Find-SteamApiFiles([string]$Directory, [int]$Depth = -1) {
    $options = @{ LiteralPath = $Directory; Filter = 'steam_api*.dll'; File = $true; Recurse = $true; ErrorAction = 'SilentlyContinue' }
    if ($Depth -ge 0) { $options.Depth = $Depth }
    Get-ChildItem @options |
        Where-Object { $_.Name -eq 'steam_api.dll' -or ($_.Name -eq 'steam_api64.dll' -and [Environment]::Is64BitOperatingSystem) } |
        Sort-Object @{ Expression = { $_.Name -eq 'steam_api64.dll' }; Descending = $true }, @{ Expression = { $_.FullName.Length } }
}

function Save-SteamApiCache([string]$Path) {
    try {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $CacheFile))
        [IO.File]::WriteAllText($CacheFile, $Path)
    } catch { }
}

function Resolve-SteamApi($Game, $Games) {
    if (Test-Path -LiteralPath $CacheFile) {
        $info = Get-SteamApiInfo ([IO.File]::ReadAllText($CacheFile).Trim())
        if ($info) { return $info }
    }

    $order = @()
    if ($Game) { $order += $Game }
    $order += @($Games | Where-Object { !$Game -or $_.AppId -ne $Game.AppId })

    if ($Game) { Write-Host "正在检测 $($Game.Name) 的 Steam API 文件……" }
    $announced = $false
    foreach ($candidateGame in $order) {
        if ($candidateGame -ne $Game -and !$announced) {
            Write-Host '正在从其他已安装的游戏中查找兼容的 Steam API 文件……'
            $announced = $true
        }

        foreach ($file in Find-SteamApiFiles $candidateGame.Directory 3) {
            $info = Get-SteamApiInfo $file.FullName
            if ($info) { Save-SteamApiCache $info.Path; return $info }
        }
    }

    if ($Game) {
        Write-Host '快速检测没有找到，正在完整扫描游戏目录，可能需要一会儿……'
        foreach ($file in Find-SteamApiFiles $Game.Directory) {
            $info = Get-SteamApiInfo $file.FullName
            if ($info) { Save-SteamApiCache $info.Path; return $info }
        }
    }
    throw '没有找到兼容的 Steam API 文件。请再安装一个带 Steam 成就的游戏后重试。'
}

function Import-SteamApi($Api) {
    $key = '{0}|{1}|{2}|{3}|{4}|{5}' -f $Api.Path, $Api.UserStats, $Api.User, $Api.Utils, $Api.Friends, $Api.Apps
    $typeName = 'SteamAchievements_' + ($key.GetHashCode() -band 0x7fffffff)
    $existing = $typeName -as [type]
    if ($existing) { return $existing }

    $source = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class __CLASS__ {
    private const string Library = @"__DLL__";
    private const CallingConvention Cc = CallingConvention.Cdecl;

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_InitFlat")]
    private static extern int InitFlat(byte[] errorMessage);

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_Init")]
    [return: MarshalAs(UnmanagedType.I1)]
    private static extern bool InitClassic();

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_InitSafe")]
    [return: MarshalAs(UnmanagedType.I1)]
    private static extern bool InitSafe();

    public static string Init(string kind) {
        if (kind == "InitFlat") {
            byte[] buffer = new byte[1024];
            int result = InitFlat(buffer);
            if (result == 0) return null;
            int length = Array.IndexOf(buffer, (byte)0);
            if (length < 0) length = buffer.Length;
            string message = Encoding.UTF8.GetString(buffer, 0, length);
            return "(" + result + ") " + message;
        }
        bool ok = kind == "Init" ? InitClassic() : InitSafe();
        return ok ? null : String.Empty;
    }

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_Shutdown")]
    public static extern void Shutdown();

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_RunCallbacks")]
    public static extern void RunCallbacks();

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "__UTILS__")]
    public static extern IntPtr Utils();

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_ISteamUtils_GetAppID")]
    public static extern uint GetAppId(IntPtr utils);

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "__USER__")]
    public static extern IntPtr User();

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_ISteamUser_GetSteamID")]
    public static extern ulong GetSteamId(IntPtr user);

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "__USERSTATS__")]
    public static extern IntPtr Stats();

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_ISteamUserStats_RequestCurrentStats")]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool RequestStats(IntPtr stats);

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_ISteamUserStats_GetNumAchievements")]
    public static extern uint Count(IntPtr stats);

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_ISteamUserStats_GetAchievementName")]
    public static extern IntPtr GetId(IntPtr stats, uint index);

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_ISteamUserStats_GetAchievementDisplayAttribute")]
    public static extern IntPtr GetAttribute(IntPtr stats, string id, string key);

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_ISteamUserStats_GetAchievement")]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool GetAchievement(IntPtr stats, string id, out byte unlocked);

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_ISteamUserStats_GetAchievementAndUnlockTime")]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool GetUnlockTime(IntPtr stats, string id, out byte unlocked, out uint unixTime);

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_ISteamUserStats_SetAchievement")]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool Unlock(IntPtr stats, string id);

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_ISteamUserStats_ClearAchievement")]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool Clear(IntPtr stats, string id);

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_ISteamUserStats_StoreStats")]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool Store(IntPtr stats);

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "__FRIENDS__")]
    public static extern IntPtr Friends();

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "__APPS__")]
    public static extern IntPtr Apps();

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_ISteamApps_BIsSubscribedApp")]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool IsSubscribedApp(IntPtr apps, uint appId);

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_ISteamFriends_GetPersonaName")]
    public static extern IntPtr GetPersonaName(IntPtr friends);

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_ISteamUserStats_GetAchievementIcon")]
    public static extern int GetIcon(IntPtr stats, string id);

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_ISteamUtils_GetImageSize")]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool GetImageSize(IntPtr utils, int image, out uint width, out uint height);

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_ISteamUtils_GetImageRGBA")]
    [return: MarshalAs(UnmanagedType.I1)]
    private static extern bool GetImageRGBA(IntPtr utils, int image, byte[] buffer, int size);

    public static byte[] GetImageBgra(IntPtr utils, int image, int width, int height) {
        byte[] pixels = new byte[width * height * 4];
        if (!GetImageRGBA(utils, image, pixels, pixels.Length)) return null;
        for (int i = 0; i < pixels.Length; i += 4) {
            byte red = pixels[i]; pixels[i] = pixels[i + 2]; pixels[i + 2] = red;
        }
        return pixels;
    }

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_ISteamUserStats_RequestGlobalAchievementPercentages")]
    public static extern ulong RequestGlobalPercentages(IntPtr stats);

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_ISteamUtils_IsAPICallCompleted")]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool IsCallCompleted(IntPtr utils, ulong call, out byte failed);

    [DllImport(Library, CallingConvention = Cc, EntryPoint = "SteamAPI_ISteamUserStats_GetAchievementAchievedPercent")]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool GetPercent(IntPtr stats, string id, out float percent);

    public static string ReadUtf8(IntPtr pointer) {
        if (pointer == IntPtr.Zero) return String.Empty;
        int length = 0;
        while (Marshal.ReadByte(pointer, length) != 0) length++;
        byte[] bytes = new byte[length];
        Marshal.Copy(pointer, bytes, 0, length);
        return Encoding.UTF8.GetString(bytes);
    }
}
'@
    $source = $source.Replace('__CLASS__', $typeName).Replace('__DLL__', $Api.Path).
        Replace('__UTILS__', $Api.Utils).Replace('__USER__', $Api.User).Replace('__USERSTATS__', $Api.UserStats).
        Replace('__FRIENDS__', $(if ($Api.Friends) { $Api.Friends } else { 'SteamAPI_SteamFriends_v017' })).
        Replace('__APPS__', $(if ($Api.Apps) { $Api.Apps } else { 'SteamAPI_SteamApps_v008' }))
    Add-Type -TypeDefinition $source
    return ($typeName -as [type])
}

function Invoke-SteamCallbacks($S, [int]$Milliseconds) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($Milliseconds)
    do {
        $S::RunCallbacks()
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
}

function Format-UnlockTime([uint32]$UnixTime) {
    if ($UnixTime -eq 0) { return '' }
    [DateTimeOffset]::FromUnixTimeSeconds($UnixTime).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
}

function Get-ToolUnlockedIds([string]$SteamId, [string]$AppId) {
    $ids = New-Object 'System.Collections.Generic.HashSet[string]'
    if (Test-Path -LiteralPath $HistoryFile) {
        try {
            foreach ($row in Import-Csv -LiteralPath $HistoryFile -Encoding UTF8) {
                if ($row.'Steam账号' -ne $SteamId -or $row.'AppID' -ne $AppId) { continue }
                if ($row.'操作' -eq '解锁') { [void]$ids.Add($row.'成就ID') } else { [void]$ids.Remove($row.'成就ID') }
            }
        } catch {
            Write-Warning "读取操作记录失败：$($_.Exception.Message)"
        }
    }
    return , $ids
}

function Get-LastHistoryBatch([string]$SteamId, [string]$AppId) {
    if (!(Test-Path -LiteralPath $HistoryFile)) { return $null }
    $rows = @(Import-Csv -LiteralPath $HistoryFile -Encoding UTF8 |
        Where-Object { $_.'Steam账号' -eq $SteamId -and $_.'AppID' -eq $AppId })
    if (!$rows.Count) { return $null }
    $last = $rows[-1]
    $batch = New-Object System.Collections.Generic.List[object]
    for ($i = $rows.Count - 1; $i -ge 0; $i--) {
        if ($rows[$i].'时间' -ne $last.'时间' -or $rows[$i].'操作' -ne $last.'操作') { break }
        $batch.Insert(0, $rows[$i])
    }
    [pscustomobject]@{ Time = $last.'时间'; Action = $last.'操作'; Ids = @($batch | ForEach-Object { $_.'成就ID' }) }
}

function Get-GameImagePath([uint32]$AppId, [string]$Kind = 'header') {
    try {
        $steam = Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Valve\Steam' -Name SteamPath
    } catch { return $null }
    $cache = [IO.Path]::Combine($steam, 'appcache', 'librarycache')

    $names = @("${Kind}_schinese.jpg", "$Kind.jpg", "library_${Kind}_schinese.jpg", "library_$Kind.jpg")
    $appDirectory = [IO.Path]::Combine($cache, [string]$AppId)
    if ([IO.Directory]::Exists($appDirectory)) {
        $directories = @($appDirectory) + @([IO.Directory]::GetDirectories($appDirectory))
        foreach ($name in $names) {
            foreach ($directory in $directories) {
                $candidate = [IO.Path]::Combine($directory, $name)
                if ([IO.File]::Exists($candidate)) { return [IO.Path]::GetFullPath($candidate) }
            }
        }
    }

    $candidate = [IO.Path]::Combine($cache, "${AppId}_$Kind.jpg")
    if ([IO.File]::Exists($candidate)) { return [IO.Path]::GetFullPath($candidate) }
    $null
}

function Add-HistoryRecords([string]$SteamId, [string]$AppId, [string]$GameName, [string]$Action, $Achievements) {
    try {
        [void][IO.Directory]::CreateDirectory($DataDirectory)
        $time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $Achievements | ForEach-Object {
            [pscustomobject][ordered]@{
                '时间' = $time; 'Steam账号' = $SteamId; 'AppID' = $AppId; '游戏' = $GameName
                '操作' = $Action; '成就ID' = $_.Id; '成就' = $_.Name
            }
        } | Export-Csv -LiteralPath $HistoryFile -Append -NoTypeInformation -Encoding UTF8
    } catch {
        Write-Warning "操作已提交，但写入操作记录失败：$($_.Exception.Message)"
    }
}

if (!('SteamGui.AchievementRow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace SteamGui {
    public static class NativeWindow {
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, IntPtr processId);
        [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint from, uint to, bool attach);
        [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
        [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr window);
        [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);

        public static bool IsForeground(IntPtr window) { return GetForegroundWindow() == window; }
        public static bool IsVisible(IntPtr window) { return IsWindowVisible(window); }

        public static bool ForceForeground(IntPtr window) {
            if (window == IntPtr.Zero) return false;
            IntPtr foreground = GetForegroundWindow();
            uint foregroundThread = foreground == IntPtr.Zero ? 0 : GetWindowThreadProcessId(foreground, IntPtr.Zero);
            uint current = GetCurrentThreadId();
            bool attached = foregroundThread != 0 && foregroundThread != current && AttachThreadInput(foregroundThread, current, true);
            try {
                ShowWindow(window, IsIconic(window) ? 9 : 5);
                BringWindowToTop(window);
                SetForegroundWindow(window);
            } finally {
                if (attached) AttachThreadInput(foregroundThread, current, false);
            }
            return GetForegroundWindow() == window;
        }
    }

    public class GameRow : INotifyPropertyChanged {
        public event PropertyChangedEventHandler PropertyChanged;
        private object image;
        public uint AppId { get; set; }
        public string Name { get; set; }
        public string DisplayName { get; set; }
        public string Directory { get; set; }
        public bool Installed { get; set; }
        public bool Hidden { get; set; }
        public string ImagePath { get; set; }
        public bool ImageLoaded { get; set; }
        public object Image {
            get { return image; }
            set { image = value; PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs("Image")); }
        }
        public string AppIdText { get { return "App ID " + AppId + (Installed ? "" : " · 未下载"); } }
    }

    public class AchievementRow : INotifyPropertyChanged {
        public event PropertyChangedEventHandler PropertyChanged;
        private void Raise(string name) {
            PropertyChangedEventHandler handler = PropertyChanged;
            if (handler != null) handler(this, new PropertyChangedEventArgs(name));
        }

        private bool selected, unlocked, fromTool;
        private string unlockTime = "";
        private double percent = -1;
        private object icon;

        public int Number { get; set; }
        public string Id { get; set; }
        public string Name { get; set; }
        public string Description { get; set; }
        public bool IconLoaded { get; set; }

        public bool Selected { get { return selected; } set { if (selected != value) { selected = value; Raise("Selected"); } } }
        public bool Unlocked { get { return unlocked; } set { if (unlocked != value) { unlocked = value; Raise("Unlocked"); Raise("StatusText"); } } }
        public string StatusText { get { return unlocked ? "已解锁" : "未解锁"; } }
        public bool FromTool { get { return fromTool; } set { if (fromTool != value) { fromTool = value; Raise("FromTool"); Raise("SourceText"); } } }
        public string SourceText { get { return fromTool ? "工具" : ""; } }
        public string UnlockTime { get { return unlockTime; } set { if (unlockTime != value) { unlockTime = value; Raise("UnlockTime"); } } }
        public double Percent { get { return percent; } set { percent = value; Raise("Percent"); Raise("PercentText"); } }
        public string PercentText { get { return percent < 0 ? "" : percent.ToString("0.0") + "%"; } }
        public object Icon { get { return icon; } set { icon = value; Raise("Icon"); } }
    }
}
'@
}

$SharedResources = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <SolidColorBrush x:Key="Bg" Color="#14171B"/>
  <SolidColorBrush x:Key="Panel" Color="#1C2026"/>
  <SolidColorBrush x:Key="PanelHover" Color="#242A31"/>
  <SolidColorBrush x:Key="Line" Color="#2C333B"/>
  <SolidColorBrush x:Key="Text" Color="#E6E8EB"/>
  <SolidColorBrush x:Key="Muted" Color="#8B949E"/>
  <SolidColorBrush x:Key="Accent" Color="#3D8BFD"/>
  <SolidColorBrush x:Key="AccentHover" Color="#5A9DFF"/>
  <SolidColorBrush x:Key="Good" Color="#3FB950"/>
  <SolidColorBrush x:Key="Danger" Color="#E5534B"/>
  <SolidColorBrush x:Key="DangerHover" Color="#F06B63"/>
  <BooleanToVisibilityConverter x:Key="BoolToVis"/>

  <Style x:Key="Btn" TargetType="Button">
    <Setter Property="Foreground" Value="{StaticResource Text}"/>
    <Setter Property="Background" Value="{StaticResource Panel}"/>
    <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
    <Setter Property="Padding" Value="14,7"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                  BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="B" Property="Background" Value="{StaticResource PanelHover}"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False">
              <Setter TargetName="B" Property="Opacity" Value="0.4"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="PrimaryBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Background" Value="{StaticResource Accent}"/>
    <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
    <Setter Property="Foreground" Value="White"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="B" Background="{StaticResource Accent}" CornerRadius="6" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="B" Property="Background" Value="{StaticResource AccentHover}"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False">
              <Setter TargetName="B" Property="Opacity" Value="0.35"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="DangerBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Foreground" Value="White"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="B" Background="{StaticResource Danger}" CornerRadius="6" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="B" Property="Background" Value="{StaticResource DangerHover}"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False">
              <Setter TargetName="B" Property="Opacity" Value="0.35"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="Field" TargetType="TextBox">
    <Setter Property="Background" Value="{StaticResource Panel}"/>
    <Setter Property="Foreground" Value="{StaticResource Text}"/>
    <Setter Property="CaretBrush" Value="{StaticResource Text}"/>
    <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
    <Setter Property="Padding" Value="8,6"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="TextBox">
          <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                  BorderThickness="1" CornerRadius="6">
            <Grid>
              <TextBlock x:Name="P" Text="{TemplateBinding Tag}" Foreground="#6E7681" Margin="{TemplateBinding Padding}"
                         Padding="2,0,0,0" VerticalAlignment="Center" Visibility="Collapsed" IsHitTestVisible="False"/>
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Grid>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="Text" Value="">
              <Setter TargetName="P" Property="Visibility" Value="Visible"/>
            </Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True">
              <Setter TargetName="B" Property="BorderBrush" Value="{StaticResource Accent}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="ScrollThumb" TargetType="Thumb">
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Thumb">
          <Border x:Name="T" Background="#3A424C" CornerRadius="4"/>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="T" Property="Background" Value="#4E5864"/>
            </Trigger>
            <Trigger Property="IsDragging" Value="True">
              <Setter TargetName="T" Property="Background" Value="#5E6A78"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="ScrollBar">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Width" Value="10"/>
    <Setter Property="MinWidth" Value="10"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Track x:Name="PART_Track" IsDirectionReversed="True" Margin="2,2">
            <Track.Thumb>
              <Thumb Style="{StaticResource ScrollThumb}"/>
            </Track.Thumb>
          </Track>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="Orientation" Value="Horizontal">
        <Setter Property="Width" Value="Auto"/>
        <Setter Property="MinWidth" Value="0"/>
        <Setter Property="Height" Value="10"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="ScrollBar">
              <Track x:Name="PART_Track" IsDirectionReversed="False" Margin="2,2">
                <Track.Thumb>
                  <Thumb Style="{StaticResource ScrollThumb}"/>
                </Track.Thumb>
              </Track>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Trigger>
    </Style.Triggers>
  </Style>

  <Style x:Key="Tab" TargetType="RadioButton">
    <Setter Property="Foreground" Value="{StaticResource Muted}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Grid Background="Transparent">
            <ContentPresenter Margin="6,6,6,12" VerticalAlignment="Center"/>
            <Border x:Name="Line" Height="2" VerticalAlignment="Bottom" Background="Transparent" CornerRadius="1"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter Property="Foreground" Value="{StaticResource Text}"/>
            </Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter Property="Foreground" Value="{StaticResource Text}"/>
              <Setter TargetName="Line" Property="Background" Value="{StaticResource Accent}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="Seg" TargetType="RadioButton">
    <Setter Property="Foreground" Value="{StaticResource Muted}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border x:Name="B" Background="Transparent" CornerRadius="5" Padding="12,5" Margin="2">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="B" Property="Background" Value="{StaticResource PanelHover}"/>
            </Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="B" Property="Background" Value="#2B3A52"/>
              <Setter Property="Foreground" Value="{StaticResource Text}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
</ResourceDictionary>
'@

function New-Window([string]$Xaml) {
    [Windows.Markup.XamlReader]::Parse($Xaml.Replace('{{RESOURCES}}', "<Window.Resources>$SharedResources</Window.Resources>"))
}

function New-BitmapImage([string]$Path, [int]$DecodeWidth = 0) {
    if (!$Path) { return $null }
    try {
        $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.UriSource = New-Object Uri($Path)
        if ($DecodeWidth) { $bitmap.DecodePixelWidth = $DecodeWidth }
        $bitmap.EndInit()
        $bitmap.Freeze()
        $bitmap
    } catch { $null }
}

function Set-WindowToFront($Window) {
    if ($PreviewPng) { return }
    $Window.Add_Loaded({
        param($sender)
        Write-LaunchLog '窗口已加载'
        $sender.Topmost = $true
        [void]$sender.Activate()
    })
    $Window.Add_ContentRendered({
        param($sender)
        $handle = (New-Object System.Windows.Interop.WindowInteropHelper($sender)).Handle
        $wasVisible = [SteamGui.NativeWindow]::IsVisible($handle)
        $wasForeground = [SteamGui.NativeWindow]::IsForeground($handle)
        $nowForeground = $wasForeground
        if (!$wasForeground) { $nowForeground = [SteamGui.NativeWindow]::ForceForeground($handle) }
        $sender.Topmost = $false
        Write-LaunchLog "窗口已显示：可见=$wasVisible，原本在前台=$wasForeground，处理后在前台=$nowForeground"
    })
}

function Invoke-Safe([scriptblock]$Action) {
    try { & $Action } catch { Show-Error $_.Exception.Message }
}

function ConvertTo-ArgumentString([string[]]$Arguments) {
    ($Arguments | ForEach-Object { if ($_ -match '[\s"]' -or !$_) { '"' + $_.Replace('"', '') + '"' } else { $_ } }) -join ' '
}

function Enable-Preview($Window) {
    if (!$PreviewPng) { return }
    $Window.WindowStartupLocation = 'Manual'
    $Window.Left = -20000; $Window.Top = 0
    $Window.ShowInTaskbar = $false
    $script:previewWindow = $Window
    $script:previewTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:previewTimer.Interval = [TimeSpan]::FromSeconds(3)
    $script:previewTimer.Add_Tick({
        $script:previewTimer.Stop()
        $w = $script:previewWindow
        $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$w.ActualWidth, [int]$w.ActualHeight, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($w)
        $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream = [IO.File]::Create($PreviewPng)
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
        $w.Close()
    })
    $Window.Add_ContentRendered({ $script:previewTimer.Start() })
}

function Start-OwnershipCheck([uint32[]]$AppIds, $Api, [uint32[]]$InitAppIds) {
    $work = Join-Path ([IO.Path]::GetTempPath()) ('steam-ownership-' + [guid]::NewGuid())
    [void][IO.Directory]::CreateDirectory($work)
    $inputFile = Join-Path $work 'input.txt'
    $output = Join-Path $work 'output.txt'
    [IO.File]::WriteAllLines($inputFile, [string[]]@(($InitAppIds -join ','), ($AppIds -join ',')))
    $engine = Get-PowerShellPath $Api.Is64Bit
    $arguments = ConvertTo-ArgumentString @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', $PSCommandPath, '-ApiDll', $Api.Path, '-CheckOwnership', $inputFile, '-OwnershipOutput', $output)
    $process = Start-Process -FilePath $engine -ArgumentList $arguments -WindowStyle Hidden -PassThru
    [pscustomobject]@{ Process = $process; Output = $output; Directory = $work; Started = [DateTime]::UtcNow }
}

function Invoke-OwnershipCheck([string]$InputPath, [string]$OutputPath, $Api) {
    $lines = [IO.File]::ReadAllLines($InputPath)
    $initIds = @($lines[0] -split ',' | Where-Object { $_ })
    $appIds = @($lines[1] -split ',' | Where-Object { $_ })
    if (!$Api.HasSubscribed -or !$Api.Apps) { [IO.File]::WriteAllText($OutputPath, "error`n这个 Steam API 文件不支持核对所有权。"); return }
    $S = Import-SteamApi $Api
    $scratch = Split-Path -Parent $InputPath
    [Environment]::CurrentDirectory = $scratch
    $initialized = $false
    foreach ($initId in $initIds) {
        [IO.File]::WriteAllText((Join-Path $scratch 'steam_appid.txt'), $initId)
        $env:SteamAppId = $initId
        $env:SteamGameId = $initId
        if ($null -eq $S::Init($Api.InitKind)) { $initialized = $true; break }
    }
    if (!$initialized) { [IO.File]::WriteAllText($OutputPath, "error`nSteam 没有运行，无法核对已退款的游戏。"); return }
    try {
        $apps = $S::Apps()
        if ($apps -eq [IntPtr]::Zero) { [IO.File]::WriteAllText($OutputPath, "error`n无法查询 Steam。"); return }
        $owned = @(foreach ($id in $appIds) { if ($S::IsSubscribedApp($apps, [uint32]$id)) { $id } })
        [IO.File]::WriteAllText($OutputPath, "ok`n" + ($owned -join ','))
    } finally {
        $S::Shutdown()
    }
}

function Start-AchievementWindow([uint32]$TargetAppId, [string]$Name, $Api) {
    $engine = Get-PowerShellPath $Api.Is64Bit
    $arguments = ConvertTo-ArgumentString @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', $PSCommandPath, '-OpenAppId', [string]$TargetAppId, '-ApiDll', $Api.Path, '-OpenGameName', $Name)
    Start-Process -FilePath $engine -ArgumentList $arguments -WindowStyle Hidden
}

function Show-GamePicker {
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Steam 成就工具" Width="640" Height="760" MinWidth="500" MinHeight="460"
        WindowStartupLocation="CenterScreen" Background="#14171B" Foreground="#E6E8EB"
        FontFamily="Microsoft YaHei UI" FontSize="13" UseLayoutRounding="True">
  {{RESOURCES}}
  <Grid Margin="20,18,20,14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Margin="0,0,0,12">
      <TextBlock Text="选择游戏" FontSize="22" FontWeight="SemiBold"/>
      <TextBlock x:Name="Subtitle" Text="正在读取 Steam 游戏库……" Foreground="#8B949E" Margin="0,4,0,0"/>
    </StackPanel>

    <Border Grid.Row="1" BorderBrush="#2C333B" BorderThickness="0,0,0,1" Margin="0,0,0,12">
      <StackPanel Orientation="Horizontal">
        <RadioButton x:Name="TabVisible" GroupName="Tab" IsChecked="True" Style="{DynamicResource Tab}" ToolTip="Steam 库里没有隐藏的游戏">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE8F1;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="18" VerticalAlignment="Center"/>
            <TextBlock Text="游戏库" FontSize="15" Margin="8,0,0,0" VerticalAlignment="Center"/>
            <TextBlock x:Name="CountVisible" FontSize="13" Foreground="#8B949E" Margin="6,1,0,0" VerticalAlignment="Center"/>
          </StackPanel>
        </RadioButton>
        <RadioButton x:Name="TabHidden" GroupName="Tab" Style="{DynamicResource Tab}" Margin="8,0,0,0" ToolTip="在 Steam 库里设成「隐藏」的游戏">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xED1A;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="18" VerticalAlignment="Center"/>
            <TextBlock Text="已隐藏" FontSize="15" Margin="8,0,0,0" VerticalAlignment="Center"/>
            <TextBlock x:Name="CountHidden" FontSize="13" Foreground="#8B949E" Margin="6,1,0,0" VerticalAlignment="Center"/>
          </StackPanel>
        </RadioButton>
      </StackPanel>
    </Border>

    <Grid Grid.Row="2" Margin="0,0,0,10">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBox x:Name="Search" Style="{DynamicResource Field}" Height="36" Tag="搜索游戏名（中英文都可以）或 App ID"/>
      <Border Grid.Column="1" Background="#1C2026" CornerRadius="7" Margin="10,0,0,0" BorderBrush="#2C333B" BorderThickness="1">
        <StackPanel Orientation="Horizontal">
          <RadioButton x:Name="ShowInstalled" GroupName="Install" IsChecked="True" Style="{DynamicResource Seg}" ToolTip="已下载到这台电脑的游戏">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE896;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="14" VerticalAlignment="Center"/>
              <TextBlock x:Name="InstalledText" Text="已下载" Margin="6,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
          </RadioButton>
          <RadioButton x:Name="ShowRemote" GroupName="Install" Style="{DynamicResource Seg}" ToolTip="账号里有、但没下载的游戏（也能查看和修改成就）">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE753;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="14" VerticalAlignment="Center"/>
              <TextBlock x:Name="RemoteText" Text="未下载" Margin="6,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
          </RadioButton>
        </StackPanel>
      </Border>
    </Grid>

    <Grid Grid.Row="3">
      <ListBox x:Name="Games" Background="Transparent" BorderThickness="0"
               ScrollViewer.HorizontalScrollBarVisibility="Disabled"
               VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.ScrollUnit="Pixel">
        <ListBox.ItemContainerStyle>
          <Style TargetType="ListBoxItem">
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Foreground" Value="#E6E8EB"/>
            <Setter Property="Template">
              <Setter.Value>
                <ControlTemplate TargetType="ListBoxItem">
                  <Border x:Name="B" Background="Transparent" CornerRadius="8" Padding="8" Margin="0,0,0,4">
                    <ContentPresenter/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                      <Setter TargetName="B" Property="Background" Value="#1C2026"/>
                    </Trigger>
                    <Trigger Property="IsSelected" Value="True">
                      <Setter TargetName="B" Property="Background" Value="#22324A"/>
                    </Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </Setter.Value>
            </Setter>
          </Style>
        </ListBox.ItemContainerStyle>
        <ListBox.ItemTemplate>
          <DataTemplate>
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="128"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border x:Name="Cover" Width="128" Height="60" CornerRadius="5" Background="#1C2026">
                <Border.Clip>
                  <RectangleGeometry Rect="0,0,128,60" RadiusX="5" RadiusY="5"/>
                </Border.Clip>
                <Grid>
                  <TextBlock Text="&#xE7FC;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="22" Foreground="#3A424C"
                             HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  <Image Source="{Binding Image}" Stretch="UniformToFill" RenderOptions.BitmapScalingMode="HighQuality"/>
                </Grid>
              </Border>
              <StackPanel Grid.Column="1" Margin="14,0,0,0" VerticalAlignment="Center">
                <TextBlock Text="{Binding DisplayName}" FontSize="14" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                <TextBlock Text="{Binding AppIdText}" Foreground="#8B949E" FontSize="12" Margin="0,3,0,0"/>
              </StackPanel>
            </Grid>
            <DataTemplate.Triggers>
              <DataTrigger Binding="{Binding Installed}" Value="False">
                <Setter TargetName="Cover" Property="Opacity" Value="0.55"/>
              </DataTrigger>
            </DataTemplate.Triggers>
          </DataTemplate>
        </ListBox.ItemTemplate>
      </ListBox>
      <TextBlock x:Name="Empty" Text="这里没有游戏" Foreground="#6E7681" FontSize="14"
                 HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
    </Grid>

    <Grid Grid.Row="4" Margin="0,12,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="140"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock Text="按 App ID 打开：" Foreground="#8B949E" VerticalAlignment="Center"/>
      <TextBox x:Name="AppIdBox" Grid.Column="1" Style="{DynamicResource Field}" Height="34" Tag="输入 App ID"/>
      <Button x:Name="OpenById" Grid.Column="2" Content="打开" Style="{DynamicResource Btn}" Margin="8,0,0,0"/>
      <Button x:Name="Open" Grid.Column="4" Content="查看成就" Style="{DynamicResource PrimaryBtn}" IsEnabled="False"/>
    </Grid>

    <TextBlock x:Name="Status" Grid.Row="5" Foreground="#8B949E" FontSize="12" Margin="2,10,0,0" TextTrimming="CharacterEllipsis"/>
  </Grid>
</Window>
'@
    $window = New-Window $xaml
    $ui = @{}
    foreach ($name in 'Subtitle', 'TabVisible', 'TabHidden', 'CountVisible', 'CountHidden', 'Search', 'ShowInstalled', 'ShowRemote',
        'InstalledText', 'RemoteText', 'Games', 'Empty', 'AppIdBox', 'OpenById', 'Open', 'Status') { $ui[$name] = $window.FindName($name) }

    $script:pickerGames = @()
    $script:pickerRows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $ui.Games.ItemsSource = $script:pickerRows
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:pickerRows)
    $view.Filter = [Predicate[object]]{
        param($row)
        if ($row.Hidden -ne [bool]$ui.TabHidden.IsChecked) { return $false }
        if ($row.Installed -ne [bool]$ui.ShowInstalled.IsChecked) { return $false }
        $text = $ui.Search.Text.Trim()
        if (!$text) { return $true }
        ($row.DisplayName.IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
        ($row.Name.IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
        ([string]$row.AppId -eq $text)
    }

    $refreshView = {
        $view.Refresh()
        $rows = $script:pickerRows
        $hiddenTab = [bool]$ui.TabHidden.IsChecked
        $ui.CountVisible.Text = [string]@($rows | Where-Object { !$_.Hidden }).Count
        $ui.CountHidden.Text = [string]@($rows | Where-Object { $_.Hidden }).Count
        $ui.InstalledText.Text = "已下载 $(@($rows | Where-Object { $_.Hidden -eq $hiddenTab -and $_.Installed }).Count)"
        $ui.RemoteText.Text = "未下载 $(@($rows | Where-Object { $_.Hidden -eq $hiddenTab -and !$_.Installed }).Count)"
        $ui.Empty.Visibility = if ($view.IsEmpty -and $rows.Count) { 'Visible' } else { 'Collapsed' }
        $ui.Open.IsEnabled = $null -ne $ui.Games.SelectedItem
    }

    $script:imageTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:imageTimer.Interval = [TimeSpan]::FromMilliseconds(30)
    $script:imageTimer.Add_Tick({
        $pending = @($view | Where-Object { !$_.ImageLoaded } | Select-Object -First 10)
        if (!$pending.Count) { $pending = @($script:pickerRows | Where-Object { !$_.ImageLoaded } | Select-Object -First 10) }
        if (!$pending.Count) { $script:imageTimer.Stop(); return }
        foreach ($row in $pending) {
            $row.ImageLoaded = $true
            $row.Image = New-BitmapImage $row.ImagePath 256
        }
    })

    $updateSubtitle = {
        $installedCount = @($script:pickerGames | Where-Object Installed).Count
        $ui.Subtitle.Text = "账号里共 $($script:pickerGames.Count) 个游戏，已下载 $installedCount 个。双击打开成就列表"
        if (!$script:pickerGames.Count) { $ui.Subtitle.Text = '没有读取到 Steam 游戏，可以在下方用 App ID 打开' }
    }

    $script:ownershipTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ownershipTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:ownershipTimer.Add_Tick({
        $check = $script:ownership
        if (!$check) { $script:ownershipTimer.Stop(); return }
        $timedOut = ([DateTime]::UtcNow - $check.Started).TotalSeconds -gt 25
        if (!$check.Process.HasExited -and !$timedOut) { return }
        $script:ownershipTimer.Stop()
        if (!$check.Process.HasExited) { try { $check.Process.Kill() } catch { } }
        $lines = @()
        if (Test-Path -LiteralPath $check.Output) { $lines = @([IO.File]::ReadAllLines($check.Output)) }
        if ($lines.Count -and $lines[0] -eq 'ok') {
            $owned = New-Object 'System.Collections.Generic.HashSet[string]'
            if ($lines.Count -gt 1) { foreach ($id in ($lines[1] -split ',')) { if ($id) { [void]$owned.Add($id) } } }
            $removed = @($script:pickerRows | Where-Object { !$_.Installed -and !$owned.Contains([string]$_.AppId) })
            foreach ($row in $removed) { [void]$script:pickerRows.Remove($row) }
            $script:pickerGames = @($script:pickerGames | Where-Object { $_.Installed -or $owned.Contains([string]$_.AppId) })
            & $updateSubtitle
            & $refreshView
            $ui.Status.Text = if ($removed.Count) { "已去掉 $($removed.Count) 个已退款或不再拥有的游戏" } else { '' }
        } else {
            $ui.Status.Text = if ($lines.Count -gt 1) { $lines[1] } else { '核对已退款的游戏超时，列表里可能包含已退款的游戏。' }
        }
        Remove-Item -LiteralPath $check.Directory -Recurse -Force -ErrorAction SilentlyContinue
        $script:ownership = $null
    })

    $openGame = {
        param([uint32]$TargetAppId, [string]$Name)
        $window.Cursor = [System.Windows.Input.Cursors]::Wait
        $ui.Status.Text = "正在准备 $Name ……"
        $window.Dispatcher.Invoke([action]{ }, 'Render')
        try {
            $installed = @($script:pickerGames | Where-Object Installed)
            $game = $installed | Where-Object AppId -eq $TargetAppId | Select-Object -First 1
            $api = Resolve-SteamApi $game $installed
            Start-AchievementWindow $TargetAppId $Name $api
            $ui.Status.Text = "已打开「$Name」的成就窗口（可以同时打开多个游戏）"
        } finally {
            $window.Cursor = $null
        }
    }
    $openSelected = { Invoke-Safe { $row = $ui.Games.SelectedItem; if ($row) { & $openGame $row.AppId $row.DisplayName } } }

    foreach ($control in $ui.TabVisible, $ui.TabHidden, $ui.ShowInstalled, $ui.ShowRemote) { $control.Add_Checked({ & $refreshView }) }
    $ui.Search.Add_TextChanged({ & $refreshView })
    $ui.Games.Add_SelectionChanged({ $ui.Open.IsEnabled = $null -ne $ui.Games.SelectedItem })
    $ui.Games.Add_MouseDoubleClick($openSelected)
    $ui.Games.Add_KeyDown({ param($sender, $e) if ($e.Key -eq 'Return') { & $openSelected } })
    $ui.Open.Add_Click($openSelected)
    $openById = {
        Invoke-Safe {
            $text = $ui.AppIdBox.Text.Trim()
            [uint32]$id = 0
            if (![uint32]::TryParse($text, [ref]$id) -or $id -eq 0) { throw '请输入数字 App ID，例如 550。可以在游戏商店页网址的 /app/ 后面找到。' }
            $game = $script:pickerGames | Where-Object AppId -eq $id | Select-Object -First 1
            $name = if ($game) { $game.DisplayName } else { "App ID $id" }
            & $openGame $id $name
        }
    }
    $ui.OpenById.Add_Click($openById)
    $ui.AppIdBox.Add_KeyDown({ param($sender, $e) if ($e.Key -eq 'Return') { & $openById } })

    $window.Add_ContentRendered({
        Invoke-Safe {
            $script:pickerGames = @(Get-LibraryGames)
            foreach ($game in @($script:pickerGames | Sort-Object DisplayName)) {
                $row = New-Object SteamGui.GameRow
                $row.AppId = $game.AppId; $row.Name = $game.Name; $row.DisplayName = $game.DisplayName
                $row.Directory = $game.Directory; $row.Installed = $game.Installed; $row.Hidden = $game.Hidden
                $row.ImagePath = Get-GameImagePath $game.AppId 'header'
                $script:pickerRows.Add($row)
            }
            & $updateSubtitle
            & $refreshView
            $script:imageTimer.Start()
            $ui.Search.Focus() | Out-Null

            $installed = @($script:pickerGames | Where-Object Installed)
            $remoteIds = [uint32[]]@($script:pickerGames | Where-Object { !$_.Installed } | ForEach-Object { $_.AppId })
            if ($remoteIds.Count -and $installed.Count) {
                try {
                    $api = Resolve-SteamApi $null $installed
                    $initIds = [uint32[]](@(480) + @($installed | Select-Object -First 3 | ForEach-Object { $_.AppId }))
                    $script:ownership = Start-OwnershipCheck $remoteIds $api $initIds
                    $ui.Status.Text = '正在向 Steam 核对已退款的游戏……'
                    $script:ownershipTimer.Start()
                } catch {
                    $ui.Status.Text = "无法核对已退款的游戏：$($_.Exception.Message)"
                }
            }
        }
    })
    $window.Add_Closed({
        $script:imageTimer.Stop()
        $script:ownershipTimer.Stop()
    })
    Set-WindowToFront $window
    Enable-Preview $window
    [void]$window.ShowDialog()
}

function Show-AchievementWindow([uint32]$TargetAppId, $Api, [string]$GameName) {
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="成就" Width="1060" Height="760" MinWidth="760" MinHeight="480"
        WindowStartupLocation="CenterScreen" Background="#14171B" Foreground="#E6E8EB"
        FontFamily="Microsoft YaHei UI" FontSize="13" UseLayoutRounding="True">
  {{RESOURCES}}
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Grid Grid.Row="0" Height="128" ClipToBounds="True">
      <Image x:Name="Hero" Stretch="UniformToFill" VerticalAlignment="Center" Opacity="0.45"/>
      <Rectangle>
        <Rectangle.Fill>
          <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#3314171B" Offset="0"/>
            <GradientStop Color="#FF14171B" Offset="1"/>
          </LinearGradientBrush>
        </Rectangle.Fill>
      </Rectangle>
      <StackPanel VerticalAlignment="Bottom" Margin="24,0,24,14">
        <TextBlock x:Name="GameTitle" FontSize="24" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="Account" Foreground="#AEB5BD" Margin="0,4,0,8"/>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="320"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <ProgressBar x:Name="Progress" Height="6" Background="#2C333B" Foreground="#3FB950" BorderThickness="0" Maximum="1" VerticalAlignment="Center"/>
          <TextBlock x:Name="Summary" Grid.Column="1" Margin="12,0,0,0" Foreground="#AEB5BD" VerticalAlignment="Center"/>
        </Grid>
      </StackPanel>
    </Grid>

    <Grid Grid.Row="1" Margin="24,8,24,10">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="260"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBox x:Name="Search" Style="{DynamicResource Field}" Height="34" Tag="搜索成就名或说明"/>
      <Border Grid.Column="1" Background="#1C2026" CornerRadius="7" Margin="12,0,0,0" BorderBrush="#2C333B" BorderThickness="1">
        <StackPanel Orientation="Horizontal">
          <RadioButton x:Name="FilterAll" Content="全部" GroupName="F" IsChecked="True" Style="{DynamicResource Seg}"/>
          <RadioButton x:Name="FilterLocked" Content="未解锁" GroupName="F" Style="{DynamicResource Seg}"/>
          <RadioButton x:Name="FilterUnlocked" Content="已解锁" GroupName="F" Style="{DynamicResource Seg}"/>
          <RadioButton x:Name="FilterTool" Content="工具解锁的" GroupName="F" Style="{DynamicResource Seg}"/>
        </StackPanel>
      </Border>
      <StackPanel Grid.Column="3" Orientation="Horizontal">
        <Button x:Name="SelectVisible" Content="全选当前列表" Style="{DynamicResource Btn}"/>
        <Button x:Name="ClearSelection" Content="清除勾选" Style="{DynamicResource Btn}" Margin="8,0,0,0"/>
      </StackPanel>
    </Grid>

    <Grid Grid.Row="2" Margin="24,0,24,0">
      <DataGrid x:Name="Grid" AutoGenerateColumns="False" CanUserAddRows="False" CanUserDeleteRows="False"
                CanUserResizeRows="False" IsReadOnly="True" HeadersVisibility="Column" GridLinesVisibility="Horizontal"
                HorizontalGridLinesBrush="#232930" Background="Transparent" RowBackground="Transparent"
                BorderBrush="#2C333B" BorderThickness="1" Foreground="#E6E8EB" SelectionMode="Extended"
                EnableRowVirtualization="True" VirtualizingPanel.ScrollUnit="Pixel">
        <DataGrid.ColumnHeaderStyle>
          <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#1C2026"/>
            <Setter Property="Foreground" Value="#8B949E"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="BorderBrush" Value="#2C333B"/>
            <Setter Property="BorderThickness" Value="0,0,0,1"/>
          </Style>
        </DataGrid.ColumnHeaderStyle>
        <DataGrid.RowStyle>
          <Style TargetType="DataGridRow">
            <Setter Property="Background" Value="Transparent"/>
            <Style.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="#1A1F25"/>
              </Trigger>
            </Style.Triggers>
          </Style>
        </DataGrid.RowStyle>
        <DataGrid.CellStyle>
          <Style TargetType="DataGridCell">
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="Template">
              <Setter.Value>
                <ControlTemplate TargetType="DataGridCell">
                  <Border Background="{TemplateBinding Background}" Padding="10,8">
                    <ContentPresenter VerticalAlignment="Center"/>
                  </Border>
                </ControlTemplate>
              </Setter.Value>
            </Setter>
            <Style.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter Property="Background" Value="#1E2A3A"/>
                <Setter Property="Foreground" Value="#E6E8EB"/>
              </Trigger>
            </Style.Triggers>
          </Style>
        </DataGrid.CellStyle>
        <DataGrid.Columns>
          <DataGridTemplateColumn Width="44" CanUserSort="False">
            <DataGridTemplateColumn.CellTemplate>
              <DataTemplate>
                <CheckBox IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                          HorizontalAlignment="Center" VerticalAlignment="Center" Cursor="Hand"/>
              </DataTemplate>
            </DataGridTemplateColumn.CellTemplate>
          </DataGridTemplateColumn>
          <DataGridTemplateColumn Width="60" CanUserSort="False">
            <DataGridTemplateColumn.CellTemplate>
              <DataTemplate>
                <Border Width="40" Height="40" CornerRadius="4" Background="#1C2026">
                  <Image Source="{Binding Icon}" RenderOptions.BitmapScalingMode="HighQuality"/>
                </Border>
              </DataTemplate>
            </DataGridTemplateColumn.CellTemplate>
          </DataGridTemplateColumn>
          <DataGridTemplateColumn Header="成就" Width="*" SortMemberPath="Name">
            <DataGridTemplateColumn.CellTemplate>
              <DataTemplate>
                <StackPanel>
                  <TextBlock Text="{Binding Name}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                  <TextBlock Text="{Binding Description}" Foreground="#8B949E" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,0"/>
                </StackPanel>
              </DataTemplate>
            </DataGridTemplateColumn.CellTemplate>
          </DataGridTemplateColumn>
          <DataGridTemplateColumn Header="全球解锁率" Width="96" SortMemberPath="Percent">
            <DataGridTemplateColumn.CellTemplate>
              <DataTemplate><TextBlock Text="{Binding PercentText}" Foreground="#AEB5BD"/></DataTemplate>
            </DataGridTemplateColumn.CellTemplate>
          </DataGridTemplateColumn>
          <DataGridTemplateColumn Header="解锁时间" Width="136" SortMemberPath="UnlockTime">
            <DataGridTemplateColumn.CellTemplate>
              <DataTemplate><TextBlock Text="{Binding UnlockTime}" Foreground="#AEB5BD"/></DataTemplate>
            </DataGridTemplateColumn.CellTemplate>
          </DataGridTemplateColumn>
          <DataGridTemplateColumn Header="来源" Width="64" SortMemberPath="FromTool">
            <DataGridTemplateColumn.CellTemplate>
              <DataTemplate><TextBlock Text="{Binding SourceText}" Foreground="#5A9DFF"/></DataTemplate>
            </DataGridTemplateColumn.CellTemplate>
          </DataGridTemplateColumn>
          <DataGridTemplateColumn Header="状态" Width="76" SortMemberPath="Unlocked">
            <DataGridTemplateColumn.CellTemplate>
              <DataTemplate>
                <TextBlock x:Name="T" Text="{Binding StatusText}" Foreground="#6E7681"/>
                <DataTemplate.Triggers>
                  <DataTrigger Binding="{Binding Unlocked}" Value="True">
                    <Setter TargetName="T" Property="Foreground" Value="#3FB950"/>
                  </DataTrigger>
                </DataTemplate.Triggers>
              </DataTemplate>
            </DataGridTemplateColumn.CellTemplate>
          </DataGridTemplateColumn>
        </DataGrid.Columns>
      </DataGrid>

      <Border x:Name="Loading" Background="#14171B">
        <TextBlock x:Name="LoadingText" Text="正在连接 Steam……" Foreground="#8B949E" FontSize="15"
                   HorizontalAlignment="Center" VerticalAlignment="Center" TextAlignment="Center"/>
      </Border>
    </Grid>

    <Grid Grid.Row="3" Margin="24,12,24,16">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock x:Name="Status" Foreground="#8B949E" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,0,12,0"/>
      <StackPanel Grid.Column="1" Orientation="Horizontal">
        <Button x:Name="Undo" Content="撤销上一次操作" Style="{DynamicResource Btn}" IsEnabled="False"/>
        <Button x:Name="Relock" Content="取消选中的成就" Style="{DynamicResource DangerBtn}" Margin="10,0,0,0" IsEnabled="False"/>
        <Button x:Name="Unlock" Content="解锁选中的成就" Style="{DynamicResource PrimaryBtn}" Margin="10,0,0,0" IsEnabled="False"/>
      </StackPanel>
    </Grid>
  </Grid>
</Window>
'@
    $window = New-Window $xaml
    $ui = @{}
    foreach ($name in 'Hero', 'GameTitle', 'Account', 'Progress', 'Summary', 'Search', 'FilterAll', 'FilterLocked',
        'FilterUnlocked', 'FilterTool', 'SelectVisible', 'ClearSelection', 'Grid', 'Loading', 'LoadingText',
        'Status', 'Undo', 'Relock', 'Unlock') { $ui[$name] = $window.FindName($name) }

    $window.Title = "$GameName - 成就"
    $ui.GameTitle.Text = $GameName
    $ui.Hero.Source = New-BitmapImage (Get-GameImagePath $TargetAppId 'library_hero') 1400
    foreach ($button in $ui.SelectVisible, $ui.ClearSelection) { $button.IsEnabled = $false }

    if (!$PreviewPng) { $script:S = Import-SteamApi $Api }
    $script:steam = @{
        Initialized = $false; Utils = [IntPtr]::Zero; User = [IntPtr]::Zero; Stats = [IntPtr]::Zero
        SteamId = 0; Phase = 'connecting'; Deadline = [DateTime]::MinValue; PercentCall = 0; LastStore = [DateTime]::MinValue
        Scratch = Join-Path ([IO.Path]::GetTempPath()) ('steam-achievements-' + [guid]::NewGuid())
    }
    $script:rows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $script:filterMode = 'all'
    $script:bulkUpdate = $false
    $ui.Grid.ItemsSource = $script:rows

    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:rows)
    $view.Filter = [Predicate[object]]{
        param($row)
        switch ($script:filterMode) {
            'locked' { if ($row.Unlocked) { return $false } }
            'unlocked' { if (!$row.Unlocked) { return $false } }
            'tool' { if (!$row.FromTool) { return $false } }
        }
        $text = $ui.Search.Text.Trim()
        if (!$text) { return $true }
        ($row.Name.IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
        ($row.Description.IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    }

    $updateButtons = {
        if ($script:bulkUpdate) { return }
        $toUnlock = @($script:rows | Where-Object { $_.Selected -and !$_.Unlocked }).Count
        $toRelock = @($script:rows | Where-Object { $_.Selected -and $_.Unlocked }).Count
        $ui.Unlock.Content = if ($toUnlock) { "解锁选中的成就（$toUnlock）" } else { '解锁选中的成就' }
        $ui.Relock.Content = if ($toRelock) { "取消选中的成就（$toRelock）" } else { '取消选中的成就' }
        $ui.Unlock.IsEnabled = $toUnlock -gt 0
        $ui.Relock.IsEnabled = $toRelock -gt 0
    }

    $updateSummary = {
        $total = $script:rows.Count
        $unlocked = @($script:rows | Where-Object Unlocked).Count
        $tool = @($script:rows | Where-Object FromTool).Count
        $ui.Progress.Value = if ($total) { $unlocked / $total } else { 0 }
        $percent = if ($total) { [math]::Round(100 * $unlocked / $total) } else { 0 }
        $ui.Summary.Text = "已解锁 $unlocked / $total（$percent%）· 其中工具解锁 $tool 个"

        $batch = $null
        try { $batch = Get-LastHistoryBatch ([string]$script:steam.SteamId) ([string]$TargetAppId) } catch { }
        $script:undoBatch = $batch
        if ($batch) {
            $actionText = $batch.Action
            $ui.Undo.Content = "撤销上一次$actionText（$($batch.Ids.Count)）"
            $ui.Undo.ToolTip = "$($batch.Time) $actionText 了 $($batch.Ids.Count) 个成就，点击恢复原状"
            $ui.Undo.IsEnabled = $true
        } else {
            $ui.Undo.Content = '撤销上一次操作'
            $ui.Undo.ToolTip = '还没有本工具对这个游戏的操作记录'
            $ui.Undo.IsEnabled = $false
        }
    }

    $refreshRowState = {
        param($row)
        [byte]$done = 0
        if ($script:S::GetAchievement($script:steam.Stats, $row.Id, [ref]$done)) { $row.Unlocked = $done -ne 0 }
        [byte]$ignored = 0
        [uint32]$time = 0
        if ($row.Unlocked -and $script:S::GetUnlockTime($script:steam.Stats, $row.Id, [ref]$ignored, [ref]$time)) {
            $row.UnlockTime = Format-UnlockTime $time
        } else {
            $row.UnlockTime = ''
        }
        $row.IconLoaded = $false
    }

    $loadIcons = {
        if (!$Api.HasIcons) { return }
        $budget = 24
        foreach ($row in $script:rows) {
            if ($row.IconLoaded) { continue }
            if ($budget-- -le 0) { break }
            $handle = $script:S::GetIcon($script:steam.Stats, $row.Id)
            if ($handle -eq -1) { continue }
            $row.IconLoaded = $true
            if ($handle -eq 0) { continue }
            [uint32]$width = 0; [uint32]$height = 0
            if (!$script:S::GetImageSize($script:steam.Utils, $handle, [ref]$width, [ref]$height) -or !$width -or !$height) { continue }
            $pixels = $script:S::GetImageBgra($script:steam.Utils, $handle, [int]$width, [int]$height)
            if (!$pixels) { continue }
            $bitmap = [System.Windows.Media.Imaging.BitmapSource]::Create([int]$width, [int]$height, 96, 96,
                [System.Windows.Media.PixelFormats]::Bgra32, $null, $pixels, [int]$width * 4)
            $bitmap.Freeze()
            $row.Icon = $bitmap
        }
    }

    $buildRows = {
        $count = [int]$script:S::Count($script:steam.Stats)
        $toolIds = Get-ToolUnlockedIds ([string]$script:steam.SteamId) ([string]$TargetAppId)
        $script:bulkUpdate = $true
        for ($index = 0; $index -lt $count; $index++) {
            $id = $script:S::ReadUtf8($script:S::GetId($script:steam.Stats, $index))
            if (!$id) { continue }
            $row = New-Object SteamGui.AchievementRow
            $row.Number = $index + 1
            $row.Id = $id
            $row.Name = $script:S::ReadUtf8($script:S::GetAttribute($script:steam.Stats, $id, 'name'))
            $row.Description = $script:S::ReadUtf8($script:S::GetAttribute($script:steam.Stats, $id, 'desc'))
            $hidden = $script:S::ReadUtf8($script:S::GetAttribute($script:steam.Stats, $id, 'hidden')) -eq '1'
            if (!$row.Name) { $row.Name = $id }
            if (!$row.Description -and $hidden) { $row.Description = '（隐藏成就）' }
            & $refreshRowState $row
            $row.FromTool = $row.Unlocked -and $toolIds.Contains($id)
            $row.add_PropertyChanged({ param($sender, $e) if ($e.PropertyName -eq 'Selected') { & $updateButtons } })
            $script:rows.Add($row)
        }
        $script:bulkUpdate = $false
        & $updateButtons
        & $updateSummary
        if ($Api.HasPercent) { $script:steam.PercentCall = $script:S::RequestGlobalPercentages($script:steam.Stats) }
    }

    $applyChange = {
        param($targets, [bool]$Relock, [string]$Label)
        $targets = @($targets)
        if (!$targets.Count) { return }
        $verb = if ($Relock) { '取消' } else { '解锁' }
        $names = @($targets | Select-Object -First 12 | ForEach-Object { '· ' + $_.Name })
        if ($targets.Count -gt 12) { $names += "……等共 $($targets.Count) 个" }
        $message = "即将$($verb)以下 $($targets.Count) 个成就：`n`n" + ($names -join "`n") +
            "`n`nSteam 账号：$($ui.Account.Text)"
        if ($Relock) { $message += "`n`n提示：取消后原来的解锁时间不会保留；按游戏内统计触发的成就，如果统计已达标，可能会被游戏重新解锁。" }
        $message += "`n`n确定继续吗？"
        $answer = [System.Windows.MessageBox]::Show($window, $message, "确认$Label", 'YesNo', 'Warning', 'No')
        if ($answer -ne 'Yes') { return }
        if ($script:S::GetSteamId($script:steam.User) -ne $script:steam.SteamId) { throw 'Steam 账号发生了变化，已停止提交。请关闭窗口重新打开。' }

        $accepted = @(foreach ($row in $targets) {
            $ok = if ($Relock) { $script:S::Clear($script:steam.Stats, $row.Id) } else { $script:S::Unlock($script:steam.Stats, $row.Id) }
            if ($ok) { $row }
        })
        if (!$accepted.Count) { throw 'Steam 没有接受任何选中的成就。' }
        if (!$script:S::Store($script:steam.Stats)) { throw 'Steam 没有接受这次提交。' }
        $script:steam.LastStore = [DateTime]::UtcNow
        Add-HistoryRecords ([string]$script:steam.SteamId) ([string]$TargetAppId) $GameName $verb $accepted

        $toolIds = Get-ToolUnlockedIds ([string]$script:steam.SteamId) ([string]$TargetAppId)
        $script:bulkUpdate = $true
        foreach ($row in $script:rows) {
            if ($accepted -contains $row) { & $refreshRowState $row }
            $row.FromTool = $row.Unlocked -and $toolIds.Contains($row.Id)
            $row.Selected = $false
        }
        $script:bulkUpdate = $false
        & $updateButtons
        & $updateSummary
        $view.Refresh()
        $skipped = $targets.Count - $accepted.Count
        $ui.Status.Foreground = $window.FindResource('Good')
        $ui.Status.Text = "已$verb $($accepted.Count) 个成就" + $(if ($skipped) { "，$skipped 个被 Steam 拒绝" } else { '' }) +
            '。可以在 Steam 成就页刷新核对。'
    }

    $tick = {
        try {
            $script:S::RunCallbacks()
            switch ($script:steam.Phase) {
                'stats' {
                    $count = $script:S::Count($script:steam.Stats)
                    $ready = $false
                    if ($count -gt 0) {
                        $firstId = $script:S::ReadUtf8($script:S::GetId($script:steam.Stats, 0))
                        [byte]$done = 0
                        $ready = $firstId -and $script:S::GetAchievement($script:steam.Stats, $firstId, [ref]$done)
                    }
                    if ($ready) {
                        $script:steam.Phase = 'ready'
                        & $buildRows
                        $ui.Loading.Visibility = 'Collapsed'
                        foreach ($button in $ui.SelectVisible, $ui.ClearSelection) { $button.IsEnabled = $true }
                        $ui.Status.Text = '勾选成就后，点右下角的按钮解锁或取消。'
                    } elseif ([DateTime]::UtcNow -gt $script:steam.Deadline) {
                        $script:steam.Phase = 'failed'
                        $ui.LoadingText.Text = if ($count -gt 0) { "Steam 在 15 秒内没有返回成就数据。`n请检查网络后关闭窗口重试。" }
                                               else { "没有读取到成就。`n这个游戏可能没有 Steam 成就，或者 Steam 没有返回数据。" }
                    }
                }
                'ready' {
                    if ($script:steam.PercentCall) {
                        [byte]$failed = 0
                        if ($script:S::IsCallCompleted($script:steam.Utils, $script:steam.PercentCall, [ref]$failed)) {
                            $script:steam.PercentCall = 0
                            if (!$failed) {
                                foreach ($row in $script:rows) {
                                    [float]$value = 0
                                    if ($script:S::GetPercent($script:steam.Stats, $row.Id, [ref]$value)) { $row.Percent = [double]$value }
                                }
                            }
                        }
                    }
                    & $loadIcons
                }
            }
        } catch {
            $script:timer.Stop()
            Show-Error $_.Exception.Message
        }
    }

    $connect = {
        [void][IO.Directory]::CreateDirectory($script:steam.Scratch)
        [IO.File]::WriteAllText((Join-Path $script:steam.Scratch 'steam_appid.txt'), [string]$TargetAppId)
        [Environment]::CurrentDirectory = $script:steam.Scratch
        $env:SteamAppId = [string]$TargetAppId
        $env:SteamGameId = [string]$TargetAppId

        $initError = $script:S::Init($Api.InitKind)
        if ($null -ne $initError) {
            $detail = if ($initError) { "（$initError）" } else { '' }
            throw "Steam 初始化失败$detail。`n请确认 Steam 已打开，并且当前账号拥有这个游戏。"
        }
        $script:steam.Initialized = $true
        $script:steam.Utils = $script:S::Utils()
        $script:steam.User = $script:S::User()
        $script:steam.Stats = $script:S::Stats()
        if ($script:steam.Utils -eq [IntPtr]::Zero -or $script:steam.User -eq [IntPtr]::Zero -or $script:steam.Stats -eq [IntPtr]::Zero) {
            throw '这个 Steam API 文件没有提供需要的接口。'
        }
        if ($script:S::GetAppId($script:steam.Utils) -ne $TargetAppId) { throw 'Steam 返回的 App ID 和所选游戏不一致。' }
        $script:steam.SteamId = $script:S::GetSteamId($script:steam.User)
        if ($script:steam.SteamId -eq 0) { throw '没有检测到已登录的 Steam 账号。' }

        $persona = ''
        if ($Api.Friends -and $Api.HasPersonaName) {
            try {
                $friends = $script:S::Friends()
                if ($friends -ne [IntPtr]::Zero) { $persona = $script:S::ReadUtf8($script:S::GetPersonaName($friends)) }
            } catch { }
        }
        $ui.Account.Text = if ($persona) { "$persona（$($script:steam.SteamId)）· App ID $TargetAppId" }
                           else { "Steam 账号 $($script:steam.SteamId) · App ID $TargetAppId" }

        if ($Api.HasRequestStats -and !$script:S::RequestStats($script:steam.Stats)) { throw '无法向 Steam 请求成就数据。' }
        $ui.LoadingText.Text = '正在读取成就……'
        $script:steam.Deadline = [DateTime]::UtcNow.AddSeconds(15)
        $script:steam.Phase = 'stats'
        $script:timer.Start()
    }

    $script:timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:timer.Interval = [TimeSpan]::FromMilliseconds(100)
    $script:timer.Add_Tick($tick)

    $setFilter = { param($mode) $script:filterMode = $mode; $view.Refresh() }
    $ui.FilterAll.Add_Checked({ & $setFilter 'all' })
    $ui.FilterLocked.Add_Checked({ & $setFilter 'locked' })
    $ui.FilterUnlocked.Add_Checked({ & $setFilter 'unlocked' })
    $ui.FilterTool.Add_Checked({ & $setFilter 'tool' })
    $ui.Search.Add_TextChanged({ $view.Refresh() })

    $ui.SelectVisible.Add_Click({
        $script:bulkUpdate = $true
        foreach ($row in $view) { $row.Selected = $true }
        $script:bulkUpdate = $false
        & $updateButtons
    })
    $ui.ClearSelection.Add_Click({
        $script:bulkUpdate = $true
        foreach ($row in $script:rows) { $row.Selected = $false }
        $script:bulkUpdate = $false
        & $updateButtons
    })

    $ui.Grid.Add_PreviewKeyDown({
        param($sender, $e)
        if ($e.Key -ne 'Space' -or !$ui.Grid.SelectedItems.Count) { return }
        $e.Handled = $true
        $items = @($ui.Grid.SelectedItems)
        $value = !($items | Where-Object Selected | Select-Object -First 1)
        $script:bulkUpdate = $true
        foreach ($row in $items) { $row.Selected = $value }
        $script:bulkUpdate = $false
        & $updateButtons
    })

    $ui.Unlock.Add_Click({
        Invoke-Safe { & $applyChange @($script:rows | Where-Object { $_.Selected -and !$_.Unlocked }) $false '解锁' }
    })
    $ui.Relock.Add_Click({
        Invoke-Safe { & $applyChange @($script:rows | Where-Object { $_.Selected -and $_.Unlocked }) $true '取消' }
    })
    $ui.Undo.Add_Click({
        Invoke-Safe {
            $batch = $script:undoBatch
            if (!$batch) { return }
            $wasUnlock = $batch.Action -eq '解锁'

            $targets = @($script:rows | Where-Object { $batch.Ids -contains $_.Id -and $_.Unlocked -eq $wasUnlock })
            if (!$targets.Count) { throw '上一次操作涉及的成就状态已经变了，没有需要撤销的。' }
            & $applyChange $targets $wasUnlock '撤销'
        }
    })

    $window.Add_ContentRendered({
        if ($PreviewPng) { & $fillDemo; return }
        try {
            & $connect
        } catch {
            $ui.LoadingText.Text = "无法读取成就。`n$($_.Exception.Message)"
            Show-Error $_.Exception.Message
        }
    })
    $window.Add_Closed({
        $script:timer.Stop()
        if ($script:steam.Initialized) {

            $wait = 1500 - ([DateTime]::UtcNow - $script:steam.LastStore).TotalMilliseconds
            if ($wait -gt 0) { Invoke-SteamCallbacks $script:S ([int]$wait) }
            try { $script:S::Shutdown() } catch { }
        }
        Remove-Item -LiteralPath $script:steam.Scratch -Recurse -Force -ErrorAction SilentlyContinue
    })

    Set-WindowToFront $window
    $fillDemo = {
            $ui.Account.Text = '示例玩家（76561190000000000）· App ID ' + $TargetAppId
            $samples = @(
                @('初次登场', '完成教程。', $true, $true, 92.4), @('收藏家', '收集 50 件道具。', $true, $false, 41.7),
                @('不眠之夜', '连续生存 10 个夜晚。', $false, $false, 12.3), @('完美主义者', '在困难难度下不受伤通关。', $false, $false, 2.1),
                @('（隐藏成就）', '（隐藏成就）', $true, $true, 7.8), @('老朋友', '与同一位好友完成 20 局游戏。', $false, $false, 25.0))
            $i = 0
            foreach ($s in $samples) {
                $i++
                $row = New-Object SteamGui.AchievementRow
                $row.Number = $i; $row.Id = "ACH_$i"; $row.Name = $s[0]; $row.Description = $s[1]
                $row.Unlocked = $s[2]; $row.FromTool = $s[3]; $row.Percent = $s[4]
                if ($row.Unlocked) { $row.UnlockTime = '2026-11-24 16:5' + $i }
                $row.Selected = ($i -eq 3 -or $i -eq 4)
                $script:rows.Add($row)
            }
            & $updateButtons
            & $updateSummary
            $ui.Loading.Visibility = 'Collapsed'
            foreach ($button in $ui.SelectVisible, $ui.ClearSelection) { $button.IsEnabled = $true }
            $ui.Status.Text = '勾选成就后，点右下角的按钮解锁或取消。'
    }
    Enable-Preview $window
    [void]$window.ShowDialog()
}

try {
    if ($CheckOwnership) {
        try {
            Invoke-OwnershipCheck $CheckOwnership $OwnershipOutput (Get-SteamApiInfo $ApiDll)
        } catch {
            [IO.File]::WriteAllText($OwnershipOutput, "error`n$($_.Exception.Message)")
        }
        exit 0
    }
    if (!$OpenAppId) {
        $created = $false
        $script:pickerMutex = New-Object System.Threading.Mutex($true, 'Local\SteamAchievementSelector.Picker', [ref]$created)
        if (!$created -and !$PreviewPng) {
            $existing = $null
            for ($attempt = 0; $attempt -lt 10 -and !$existing; $attempt++) {
                $existing = Get-Process -Name powershell -ErrorAction SilentlyContinue |
                    Where-Object { $_.Id -ne $PID -and $_.MainWindowTitle -eq 'Steam 成就工具' -and $_.MainWindowHandle -ne [IntPtr]::Zero } |
                    Select-Object -First 1
                if (!$existing) { Start-Sleep -Milliseconds 300 }
            }
            if ($existing) {
                $front = [SteamGui.NativeWindow]::ForceForeground($existing.MainWindowHandle)
                Write-LaunchLog "已有游戏列表窗口（进程 $($existing.Id)），切换过去，成功=$front"
                exit 0
            }
            Write-LaunchLog '检测到已有实例标记，但找不到它的窗口，照常打开新窗口'
        }
        Show-GamePicker
        Write-LaunchLog '游戏列表窗口已关闭'
        exit 0
    }

    if ($PreviewPng) {
        Show-AchievementWindow $OpenAppId ([pscustomobject]@{ HasIcons = $false; HasPercent = $false }) $OpenGameName
        exit 0
    }
    $api = $null
    if ($ApiDll) {
        $api = Get-SteamApiInfo $ApiDll
        if (!$api) { throw '指定的文件不是兼容的 steam_api.dll 或 steam_api64.dll。' }
    }
    $name = $OpenGameName
    if (!$api -or !$name) {
        $games = @(Get-InstalledSteamApps)
        $game = $games | Where-Object AppId -eq $OpenAppId | Select-Object -First 1
        if (!$name) { $name = if ($game) { $game.DisplayName } else { "App ID $OpenAppId" } }
        if (!$api) { $api = Resolve-SteamApi $game $games }
    }
    if ($api.Is64Bit -ne [Environment]::Is64BitProcess) {
        Start-AchievementWindow $OpenAppId $name $api
        exit 0
    }
    Show-AchievementWindow $OpenAppId $api $name
} catch {
    Write-LaunchLog "出错：$($_.Exception.Message)"
    Show-Error $_.Exception.Message
    exit 1
}
