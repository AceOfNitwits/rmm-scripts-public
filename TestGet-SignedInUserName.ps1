# This script is intended to be run as a Datto RMM job.
# This script tests running a child process as the currently logged-on user from a parent process running as SYSTEM.
# It is designed to be run in two phases: the parent phase (run as SYSTEM) and the user phase (run as the logged-on user).
# The parent phase creates a scheduled task to run the user phase, waits for it to complete, and captures the output and exit code from the user phase.

[CmdletBinding()]
param(
    [switch]$UserPhase # This switch indicates whether the script is running the user phase. It should be passed when the scheduled task runs the script for the user phase in order to prevent accidental recursion of the parent phase when the scheduled task executes the script.
)

$ErrorActionPreference = 'Stop'

# -------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------
$basePath        = "$($env:SystemDrive)\ProgramData\MspName" # Change this path to your desired location for the files to be written.
$AutomationPath = "$basePath\Automation"
$LogPath        = "$basePath\Logs"
$ScriptName     = 'Run-As-LoggedOnUser-Test.ps1'

$CopiedScriptPath = Join-Path $AutomationPath $ScriptName
$ChildLogPath     = Join-Path $LogPath 'Run-As-LoggedOnUser-Test-child.log'
$ChildExitPath    = Join-Path $LogPath 'Run-As-LoggedOnUser-Test-child.exitcode'
$ParentLogPath    = Join-Path $LogPath 'Run-As-LoggedOnUser-Test-parent.log'
$EnvVarsJsonPath  = Join-Path $AutomationPath 'Run-As-LoggedOnUser-Test-envvars.json'

$TaskPrefix     = 'RunAsUser'
$TaskTimeoutSec = 120

# Environment Variables Manifest
# This section defines which environment variables should be passed from the system phase (running as SYSTEM)
# to the user phase (running as the logged-on user). Datto RMM sets environment variables in the SYSTEM context,
# but these are not accessible in the user context. This mechanism allows passing arbitrary environment variables.
#
# Instructions for developers:
# - Add the names of environment variables you want to pass as strings in the array below.
# - Example: $EnvironmentVariableManifest = @('VAR1', 'VAR2')
# - If no variables need to be passed, leave the array empty: $EnvironmentVariableManifest = @()
# - The system phase will read these variables (if they exist) and write them to a JSON file in the automation folder.
# - The user phase will read the JSON file and set the environment variables in the user context.
# - If the manifest is empty, an empty JSON file is still written, and the user phase will attempt to read it (harmless if empty).
$EnvironmentVariableManifest = @(
    'TEST_ENV_VAR'
)

# -------------------------------------------------------------------
# Logging
# -------------------------------------------------------------------
function Write-ParentLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    Add-Content -Path $ParentLogPath -Value $line
}

function Write-ChildLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $ChildLogPath -Value $line
}

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------
function Test-IsSystem {
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    return $currentIdentity.User.Value -eq 'S-1-5-18'
}

function Get-LoggedOnUser {
    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        if (-not [string]::IsNullOrWhiteSpace($cs.UserName)) {
            return $cs.UserName
        }
    }
    catch {
        Write-ParentLog "Failed to query logged-on user: $($_.Exception.Message)"
    }

    return $null
}

function Ensure-Folder {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

# -------------------------------------------------------------------
# User phase
# -------------------------------------------------------------------
function Invoke-UserPhase {
    try {
        Ensure-Folder -Path $LogPath

        if (Test-Path -LiteralPath $ChildLogPath) {
            Remove-Item -LiteralPath $ChildLogPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $ChildExitPath) {
            Remove-Item -LiteralPath $ChildExitPath -Force -ErrorAction SilentlyContinue
        }

        # Load environment variables from JSON file
        # This reads the JSON file created by the system phase and sets the environment variables in the user context.
        # If the JSON file doesn't exist or is empty, no variables are set (which is fine).
        if (Test-Path -LiteralPath $EnvVarsJsonPath) {
            try {
                $envVars = Get-Content -LiteralPath $EnvVarsJsonPath -Raw | ConvertFrom-Json
                foreach ($varName in $envVars.PSObject.Properties.Name) {
                    [Environment]::SetEnvironmentVariable($varName, $envVars.$varName, 'Process')
                    Write-ChildLog "Set env:$varName = $($envVars.$varName)"
                }
            }
            catch {
                Write-ChildLog "Failed to load environment variables from JSON: $($_.Exception.Message)"
            }
        } else {
            Write-ChildLog "Environment variables JSON file not found: $EnvVarsJsonPath"
        }

        Write-ChildLog "Child phase started."

        # -------------------------------------------------------------------
        # Your code to run as the logged-on user goes here.

        Write-ChildLog "Security context: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        Write-ChildLog "env:USERNAME = $env:USERNAME"
        Write-ChildLog "env:TEST_ENV_VAR = $env:TEST_ENV_VAR"

        # End of custom code.
        # -------------------------------------------------------------------

        Set-Content -Path $ChildExitPath -Value '0' -Encoding ascii
        exit 0
    }
    catch {
        try {
            Write-ChildLog "ERROR: $($_.Exception.Message)"
            Set-Content -Path $ChildExitPath -Value '1' -Encoding ascii
        }
        catch {
        }

        exit 1
    }
}

# -------------------------------------------------------------------
# System phase
# -------------------------------------------------------------------
function Invoke-SystemPhase {
    Ensure-Folder -Path $AutomationPath
    Ensure-Folder -Path $LogPath

    Write-ParentLog "Parent phase started."
    Write-ParentLog "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-ParentLog "Original script path: $PSCommandPath"

    if (-not $PSCommandPath) {
        throw 'PSCommandPath is empty. This script must be run from a .ps1 file.'
    }

    Copy-Item -LiteralPath $PSCommandPath -Destination $CopiedScriptPath -Force
    Write-ParentLog "Copied script to: $CopiedScriptPath"

    if (Test-Path -LiteralPath $ChildLogPath) {
        Remove-Item -LiteralPath $ChildLogPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $ChildExitPath) {
        Remove-Item -LiteralPath $ChildExitPath -Force -ErrorAction SilentlyContinue
    }

    # Prepare environment variables JSON file
    # This reads the environment variables listed in EnvironmentVariableManifest and writes them to a JSON file
    # that the user phase can read. This allows passing environment variables from SYSTEM context to user context.
    $envVars = @{}
    foreach ($varName in $EnvironmentVariableManifest) {
        if (Test-Path "env:$varName") {
            $envVars[$varName] = [Environment]::GetEnvironmentVariable($varName)
            Write-ParentLog "Captured env:$varName = $($envVars[$varName])"
        } else {
            Write-ParentLog "Environment variable '$varName' not found, skipping."
        }
    }
    $envVars | ConvertTo-Json | Set-Content -Path $EnvVarsJsonPath -Encoding UTF8
    Write-ParentLog "Wrote environment variables to: $EnvVarsJsonPath"

    $loggedOnUser = Get-LoggedOnUser
    if (-not $loggedOnUser) {
        throw 'No interactive logged-on user found.'
    }

    Write-ParentLog "Detected logged-on user: $loggedOnUser"

    $taskName = '{0}-{1}' -f $TaskPrefix, ([guid]::NewGuid().ToString())

    $taskArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$CopiedScriptPath`" -UserPhase"

    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument $taskArgs

    $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1))

    $principal = New-ScheduledTaskPrincipal `
        -UserId $loggedOnUser `
        -LogonType Interactive `
        -RunLevel Limited

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

    try {
        Write-ParentLog "Registering scheduled task: $taskName"

        Register-ScheduledTask `
            -TaskName $taskName `
            -Action $action `
            -Trigger $trigger `
            -Principal $principal `
            -Settings $settings `
            -Force | Out-Null

        Write-ParentLog "Starting scheduled task."
        Start-ScheduledTask -TaskName $taskName

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $completed = $false
        $lastTaskInfo = $null

        do {
            Start-Sleep -Seconds 2

            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
            $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
            $lastTaskInfo = $taskInfo

            Write-ParentLog "Task state: $($task.State); LastRunTime: $($taskInfo.LastRunTime); LastTaskResult: $($taskInfo.LastTaskResult)"

            if ($taskInfo.LastRunTime -ne [datetime]::MinValue -and $task.State -ne 'Running') {
                $completed = $true
                break
            }
        }
        while ($stopwatch.Elapsed.TotalSeconds -lt $TaskTimeoutSec)

        if (-not $completed) {
            throw "Timed out waiting for scheduled task after $TaskTimeoutSec seconds."
        }

        Start-Sleep -Seconds 2

        if (Test-Path -LiteralPath $ChildLogPath) {
            Write-ParentLog '----- Begin child output -----'
            Get-Content -LiteralPath $ChildLogPath | ForEach-Object { Write-Output $_ }
            Write-ParentLog '----- End child output -----'
        }
        else {
            Write-ParentLog 'Child log file was not created.'
        }

        if (-not (Test-Path -LiteralPath $ChildExitPath)) {
            throw 'Child exit code file was not created.'
        }

        $childExitCode = (Get-Content -LiteralPath $ChildExitPath -ErrorAction Stop | Select-Object -First 1).Trim()
        Write-ParentLog "Child exit code file says: $childExitCode"

        if ($childExitCode -ne '0') {
            throw "Child phase reported failure with exit code $childExitCode."
        }

        Write-ParentLog 'Parent phase completed successfully.'
        exit 0
    }
    finally {
        try {
            if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
                Write-ParentLog "Removed scheduled task: $taskName"
            }
        }
        catch {
            Write-ParentLog "Failed to remove scheduled task: $($_.Exception.Message)"
        }
    }
}

# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------
$isSystem = Test-IsSystem

if ($UserPhase) {
    if ($isSystem) {
        throw 'Script was started with -UserPhase but is still running as SYSTEM.'
    }

    Invoke-UserPhase
}
else {
    if (-not $isSystem) {
        throw 'Launcher phase must be run as SYSTEM.'
    }

    Invoke-SystemPhase
}
