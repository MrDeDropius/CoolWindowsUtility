<#
.SYNOPSIS
    WinCleanAI — безопасное отключение ИИ-функций и телеметрии Windows 10/11.

.DESCRIPTION
    Что делает:
      * Отключает Copilot, Recall, Click to Do, ИИ в Блокноте/Paint (политики реестра)
      * Снижает телеметрию до минимума, отключает рекламный ID, CEIP, историю действий,
        Bing-подсказки в поиске, отправку отчётов об ошибках
      * Отключает (НЕ удаляет) службы DiagTrack и dmwappushservice
      * Отключает задачи планировщика, которые только собирают телеметрию
      * По желанию (-RemoveApps) удаляет приложения Copilot/Cortana

    Чего НЕ трогает (специально):
      Защитник Windows, Центр обновления, брандмауэр, драйверы, Microsoft Store,
      системные службы, магазин приложений, Edge как браузер, сеть, загрузчик.

    Всё обратимо: перед изменениями сохраняется исходное состояние, откат — флагом -Undo.
    (Единственное исключение — удалённые приложения: их можно поставить заново из Microsoft Store.)

.PARAMETER DryRun
    Только показать, что будет сделано. Ничего не меняет.

.PARAMETER Undo
    Вернуть всё, как было до запуска скрипта.

.PARAMETER RemoveApps
    Дополнительно удалить приложения Copilot и Cortana.

.PARAMETER NoRestorePoint
    Не создавать точку восстановления.

.EXAMPLE
    .\WinCleanAI.ps1 -DryRun
    .\WinCleanAI.ps1
    .\WinCleanAI.ps1 -RemoveApps
    .\WinCleanAI.ps1 -Undo
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Undo,
    [switch]$RemoveApps,
    [switch]$NoRestorePoint
)

$ErrorActionPreference = 'Stop'
$StateDir  = Join-Path $env:ProgramData 'WinCleanAI'
$StateFile = Join-Path $StateDir 'state.json'

# ---------------------------------------------------------------- утилиты ----
function Log  { param($m, $c = 'Gray') Write-Host $m -ForegroundColor $c }
function Head { param($m) Write-Host "`n== $m ==" -ForegroundColor Cyan }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Log 'Нужны права администратора. Запустите PowerShell от имени администратора.' Red
    exit 1
}
if ($PSVersionTable.PSEdition -eq 'Core') {
    Log 'Запускайте в Windows PowerShell 5.1 (powershell.exe), а не в PowerShell 7.' Red
    exit 1
}

$build = [Environment]::OSVersion.Version.Build
$isWin11 = $build -ge 22000
Log "Windows build $build ($(if ($isWin11) {'Windows 11'} else {'Windows 10'}))"
if ($DryRun) { Log '*** РЕЖИМ ПРОВЕРКИ: ничего не изменяется ***' Yellow }

# ------------------------------------------------------------ состояние ------
$script:State = [ordered]@{ Reg = New-Object System.Collections.ArrayList
                            Services = New-Object System.Collections.ArrayList
                            Tasks = New-Object System.Collections.ArrayList
                            Features = New-Object System.Collections.ArrayList }
$script:Seen = New-Object 'System.Collections.Generic.HashSet[string]'

function Load-State {
    if (-not (Test-Path $StateFile)) { return $null }
    return Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
}
function Save-State {
    if ($DryRun) { return }
    if (-not (Test-Path $StateDir)) { New-Item $StateDir -ItemType Directory -Force | Out-Null }
    $script:State | ConvertTo-Json -Depth 5 | Set-Content $StateFile -Encoding UTF8
}
function AsArray($x) { if ($null -eq $x) { ,@() } else { ,@($x) } }

# Если скрипт уже запускали — сохраняем ПЕРВОНАЧАЛЬНОЕ состояние, а не перезаписываем его.
if (-not $Undo) {
    $prev = Load-State
    if ($prev) {
        foreach ($k in 'Reg','Services','Tasks','Features') {
            foreach ($e in (AsArray $prev.$k)[0]) { [void]$script:State[$k].Add($e) }
        }
        foreach ($e in $script:State.Reg)      { [void]$script:Seen.Add("R|$($e.Path)|$($e.Name)") }
        foreach ($e in $script:State.Services) { [void]$script:Seen.Add("S|$($e.Name)") }
        foreach ($e in $script:State.Tasks)    { [void]$script:Seen.Add("T|$($e.Path)$($e.Name)") }
        foreach ($e in $script:State.Features) { [void]$script:Seen.Add("F|$($e.Name)") }
    }
}

# ------------------------------------------------------------- действия ------
function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord', [string]$Why = '')
    $cur = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    $existed = $null -ne $cur
    $old = if ($existed) { $cur.$Name } else { $null }
    if ($existed -and $old -eq $Value) { Log "  [уже есть] $Why" DarkGray; return }
    Log "  [реестр]   $Why" Green
    if ($DryRun) { return }
    $key = "R|$Path|$Name"
    if ($script:Seen.Add($key)) {
        [void]$script:State.Reg.Add([pscustomobject]@{ Path = $Path; Name = $Name; Existed = $existed; Old = $old; Type = $Type })
    }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Disable-Svc {
    param([string]$Name, [string]$Why)
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $s) { return }
    if ($s.StartType -eq 'Disabled') { Log "  [уже выкл] служба $Name" DarkGray; return }
    Log "  [служба]   $Name — $Why" Green
    if ($DryRun) { return }
    if ($script:Seen.Add("S|$Name")) {
        [void]$script:State.Services.Add([pscustomobject]@{ Name = $Name; StartType = [string]$s.StartType; WasRunning = ($s.Status -eq 'Running') })
    }
    try { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue } catch {}
    Set-Service -Name $Name -StartupType Disabled
}

function Disable-Task {
    param([string]$Path, [string]$Name)
    $t = Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction SilentlyContinue
    if (-not $t -or $t.State -eq 'Disabled') { return }
    Log "  [задача]   $Path$Name" Green
    if ($DryRun) { return }
    if ($script:Seen.Add("T|$Path$Name")) {
        [void]$script:State.Tasks.Add([pscustomobject]@{ Path = $Path; Name = $Name })
    }
    Disable-ScheduledTask -TaskPath $Path -TaskName $Name | Out-Null
}

# ===================================================================== UNDO ===
if ($Undo) {
    $s = Load-State
    if (-not $s) { Log 'Файл состояния не найден — откатывать нечего.' Yellow; exit 0 }
    Head 'Откат изменений'
    foreach ($e in (AsArray $s.Reg)[0]) {
        try {
            if ($e.Existed) {
                if (-not (Test-Path $e.Path)) { New-Item $e.Path -Force | Out-Null }
                New-ItemProperty -Path $e.Path -Name $e.Name -Value $e.Old -PropertyType $e.Type -Force | Out-Null
            } else {
                Remove-ItemProperty -Path $e.Path -Name $e.Name -ErrorAction SilentlyContinue
            }
            Log "  реестр восстановлен: $($e.Path) \ $($e.Name)" Green
        } catch { Log "  не удалось: $($e.Path) \ $($e.Name): $_" Yellow }
    }
    foreach ($e in (AsArray $s.Services)[0]) {
        try {
            Set-Service -Name $e.Name -StartupType $e.StartType
            if ($e.WasRunning) { Start-Service -Name $e.Name -ErrorAction SilentlyContinue }
            Log "  служба восстановлена: $($e.Name) ($($e.StartType))" Green
        } catch { Log "  не удалось: служба $($e.Name): $_" Yellow }
    }
    foreach ($e in (AsArray $s.Tasks)[0]) {
        try { Enable-ScheduledTask -TaskPath $e.Path -TaskName $e.Name | Out-Null
              Log "  задача включена: $($e.Path)$($e.Name)" Green
        } catch { Log "  не удалось: задача $($e.Name): $_" Yellow }
    }
    foreach ($e in (AsArray $s.Features)[0]) {
        try { Enable-WindowsOptionalFeature -Online -FeatureName $e.Name -NoRestart | Out-Null
              Log "  компонент включён: $($e.Name)" Green
        } catch { Log "  не удалось: компонент $($e.Name): $_" Yellow }
    }
    Move-Item $StateFile "$StateFile.undone-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force
    Log "`nГотово. Перезагрузите компьютер." Cyan
    exit 0
}

# ======================================================= ТОЧКА ВОССТАНОВЛЕНИЯ ==
if (-not $NoRestorePoint -and -not $DryRun) {
    Head 'Точка восстановления'
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description 'WinCleanAI' -RestorePointType MODIFY_SETTINGS
        Log '  создана' Green
    } catch {
        Log "  не удалось создать (Windows ограничивает частоту — раз в 24 ч): $($_.Exception.Message)" Yellow
        $a = Read-Host '  Продолжить без неё? (y/N)'
        if ($a -notmatch '^[yYдД]') { exit 1 }
    }
}

# ================================================================== ИИ ========
Head 'ИИ-функции'
$ai = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'
$aiU = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI'

Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 -Why 'Copilot (HKLM)'
Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 -Why 'Copilot (HKCU)'
Set-Reg $ai  'DisableAIDataAnalysis' 1 -Why 'Recall: запретить сохранение снимков экрана (HKLM)'
Set-Reg $aiU 'DisableAIDataAnalysis' 1 -Why 'Recall: запретить сохранение снимков экрана (HKCU)'
Set-Reg $ai  'AllowRecallEnablement' 0 -Why 'Recall: запретить включение'
Set-Reg $ai  'DisableClickToDo' 1 -Why 'Click to Do'
Set-Reg 'HKLM:\SOFTWARE\Policies\WindowsNotepad' 'DisableAIFeatures' 1 -Why 'ИИ в Блокноте'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Paint' 'DisableCocreator' 1 -Why 'Paint: Cocreator'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Paint' 'DisableGenerativeFill' 1 -Why 'Paint: генеративная заливка'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Paint' 'DisableImageCreator' 1 -Why 'Paint: Image Creator'
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowCopilotButton' 0 -Why 'Кнопка Copilot на панели задач'
# Edge: боковая панель (в ней живёт Copilot) и сбор данных
$edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
Set-Reg $edge 'HubsSidebarEnabled' 0 -Why 'Edge: боковая панель / Copilot'
Set-Reg $edge 'Microsoft365CopilotChatIconEnabled' 0 -Why 'Edge: значок Copilot Chat'
Set-Reg $edge 'DiagnosticData' 0 -Why 'Edge: диагностические данные'
Set-Reg $edge 'MetricsReportingEnabled' 0 -Why 'Edge: отправка метрик'
Set-Reg $edge 'PersonalizationReportingEnabled' 0 -Why 'Edge: персонализация по истории'

if ($isWin11) {
    $f = Get-WindowsOptionalFeature -Online -FeatureName Recall -ErrorAction SilentlyContinue
    if ($f -and $f.State -eq 'Enabled') {
        Log '  [компонент] Recall — отключаем' Green
        if (-not $DryRun) {
            if ($script:Seen.Add('F|Recall')) { [void]$script:State.Features.Add([pscustomobject]@{ Name = 'Recall' }) }
            Disable-WindowsOptionalFeature -Online -FeatureName Recall -NoRestart | Out-Null
        }
    }
}

# =============================================================== ТЕЛЕМЕТРИЯ ===
Head 'Телеметрия и слежка'
$dc = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
Set-Reg $dc 'AllowTelemetry' 0 -Why 'Уровень телеметрии: минимум (Home/Pro = «обязательные»)'
Set-Reg $dc 'DoNotShowFeedbackNotifications' 1 -Why 'Запросы отзывов'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1 -Why 'Рекламный ID'
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0 -Why 'Рекламный ID (пользователь)'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows' 'CEIPEnable' 0 -Why 'Программа улучшения качества (CEIP)'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'AITEnable' 0 -Why 'Application Impact Telemetry'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisableInventory' 1 -Why 'Инвентаризация приложений'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1 -Why 'Отправка отчётов об ошибках'
$sys = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
Set-Reg $sys 'EnableActivityFeed' 0 -Why 'История действий (Timeline)'
Set-Reg $sys 'PublishUserActivities' 0 -Why 'История действий: публикация'
Set-Reg $sys 'UploadUserActivities' 0 -Why 'История действий: загрузка в облако'
Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' 'DisableTailoredExperiencesWithDiagnosticData' 1 -Why 'Персональные советы на основе диагностики'
Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1 -Why 'Bing/веб-подсказки в поиске Пуска'
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 0 -Why 'Рекомендации «Советы и подсказки»'
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 0 -Why 'Автоустановка рекламных приложений'

Head 'Службы (отключаются, не удаляются)'
Disable-Svc 'DiagTrack'        'Connected User Experiences and Telemetry'
Disable-Svc 'dmwappushservice' 'WAP Push (маршрутизация телеметрии)'

Head 'Задачи планировщика (только телеметрия)'
Disable-Task '\Microsoft\Windows\Application Experience\' 'Microsoft Compatibility Appraiser'
Disable-Task '\Microsoft\Windows\Application Experience\' 'ProgramDataUpdater'
Disable-Task '\Microsoft\Windows\Customer Experience Improvement Program\' 'Consolidator'
Disable-Task '\Microsoft\Windows\Customer Experience Improvement Program\' 'UsbCeip'
Disable-Task '\Microsoft\Windows\Customer Experience Improvement Program\' 'KernelCeipTask'
Disable-Task '\Microsoft\Windows\Feedback\Siuf\' 'DmClient'
Disable-Task '\Microsoft\Windows\Feedback\Siuf\' 'DmClientOnScenarioDownload'

# ============================================================ УДАЛЕНИЕ APPX ===
if ($RemoveApps) {
    Head 'Удаление приложений (необратимо скриптом; ставятся заново из Microsoft Store)'
    $apps = @('Microsoft.Copilot', 'Microsoft.Windows.Ai.Copilot.Provider', 'Microsoft.549981C3F5F10')  # последнее — Cortana
    foreach ($n in $apps) {
        foreach ($p in @(Get-AppxPackage -AllUsers -Name $n -ErrorAction SilentlyContinue)) {
            Log "  [приложение] $($p.Name)" Green
            if (-not $DryRun) {
                try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop }
                catch { Log "    не удалось: $($_.Exception.Message)" Yellow }
            }
        }
        foreach ($pp in @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $n })) {
            Log "  [шаблон]     $($pp.DisplayName) (не будет ставиться новым пользователям)" Green
            if (-not $DryRun) {
                try { Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName | Out-Null }
                catch { Log "    не удалось: $($_.Exception.Message)" Yellow }
            }
        }
    }
}

# ================================================================== ИТОГ ======
Save-State
Head 'Готово'
if ($DryRun) {
    Log 'Это была проверка. Для применения запустите без -DryRun.' Yellow
} else {
    Log "Исходное состояние сохранено: $StateFile" Gray
    Log 'Откат: .\WinCleanAI.ps1 -Undo' Gray
    Log 'Перезагрузите компьютер, чтобы изменения вступили в силу.' Cyan
    Log 'Примечание: крупные обновления Windows иногда сбрасывают часть настроек — просто запустите скрипт ещё раз.' DarkGray
}