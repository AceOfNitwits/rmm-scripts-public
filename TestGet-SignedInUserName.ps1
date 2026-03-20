# This script is intended to be run as a Datto RMM job.
# This script tests running a child process as the currently logged-on user from a parent process running as SYSTEM.
# It is designed to be run in two phases: the parent phase (run as SYSTEM) and the user phase (run as the logged-on user).
# The parent phase creates a scheduled task to run the user phase, waits for it to complete, and captures the output and exit code from the user phase.
# The output is also optionally saved to a user-defined field for use in Datto RMM.
# Note that a PowerShell window will briefly flash on the screen when the scheduled task is triggered to run the user phase, but the script is designed to run with a hidden window style to minimize this as much as possible.

# The customisable portion of the script that runs in the user phase is where you would put code to do work. The parent phase will handle writing the output to the appropriate registry location for user-defined fields based on the value of $UDF that you set in the user phase.

[CmdletBinding()]
param(
    [switch]$UserPhase # This switch indicates whether the script is running the user phase. It should be passed when the scheduled task runs the script for the user phase in order to prevent accidental recursion of the parent phase when the scheduled task executes the script.
)

$ErrorActionPreference = 'Stop'

# -------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------
$basePath         = "$($env:ProgramData)\RMM"
$AutomationPath   = "$basePath\Automation"
$LogPath          = "$basePath\Logs"
$dropPath         = "$basePath\Temp"
$baseScriptName   = 'Run-As-LoggedOnUser' # Base name for the script, used to construct the copied script name and log file names. Changing this is not necessary, but it allows for multiple similar scripts to coexist without stepping on each other's logs or copied scripts.
$ScriptName       = "$baseScriptName.ps1" # The name of this script file. This is used to copy the script to the automation folder and to construct the scheduled task action. It is important that this matches the actual file name of the script.
$dropFileName     = "$baseScriptName-DattoDrop.xml" # Temporary file used to pass data from the user phase back to the parent phase for writing to user-defined fields in Datto RMM. The user phase writes the desired UDF values to this file, and the parent phase reads it and writes the values to the registry. This is necessary because the user phase runs in a non-privileged context and cannot write directly to the registry location for UDFs.

$dropFilePath     = Join-Path -Path $dropPath -ChildPath $dropFileName
$CopiedScriptPath = Join-Path $AutomationPath $ScriptName
$ChildLogPath     = Join-Path $LogPath "$baseScriptName-child.log"
$ChildExitPath    = Join-Path $LogPath "$baseScriptName-child.exitcode"
$ParentLogPath    = Join-Path $LogPath "$baseScriptName-parent.log"
$EnvVarsJsonPath  = Join-Path $AutomationPath "$baseScriptName-envvars.json"

$TaskPrefix     = 'RunRMMJobAsUser' # Prefix for the scheduled task name. The actual task name will have a GUID appended to ensure uniqueness. This allows for multiple instances of this script to run without name collisions in the scheduled tasks.
$TaskTimeoutSec = 120 # Number of seconds to wait for the scheduled task to complete before timing out. Adjust as needed based on expected runtime of the user phase.

# Environment Variables Manifest
# This section defines which environment variables should be passed from the system phase (running as SYSTEM)
# to the user phase (running as the logged-on user). Datto RMM sets environment variables in the SYSTEM context,
# but these are not accessible in the user context. This mechanism allows passing arbitrary environment variables.
#
# Instructions for developers:
# - Add the names of environment variables you want to pass as strings in the array below.
# - Example: $EnvironmentVariableManifest = @('VAR1', 'VAR2')
# - YOU MUST INCLUDE ANY SITE OR GLOBAL VARIABLES YOU WANT TO USE IN THE USER PHASE IN THIS MANIFEST, OTHERWISE THEY WILL NOT BE AVAILABLE IN THE USER PHASE.
# - If no variables need to be passed, leave the array empty: $EnvironmentVariableManifest = @()
# - The system phase will read these variables (if they exist) and write them to a JSON file in the automation folder.
# - The user phase will read the JSON file and set the environment variables in the user context.
# - If the manifest is empty, an empty JSON file is still written, and the user phase will attempt to read it (harmless if empty).
$EnvironmentVariableManifest = @(
    'UDF'   # The 'UDF' environment variable is required if you want to use the Datto Drop Sweeper functionality to write values to user-defined fields in Datto RMM. Set this environment variable to the number of the user-defined field you want to write to (e.g. '1' for Custom1, '2' for Custom2, etc.) in order for the user phase to write the desired output to the drop file for the parent phase to read and write to the registry for user-defined fields in Datto RMM.
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
                    Write-ChildLog "Set env:$varName from JSON file for user phase."
                }
            }
            catch {
                Write-ChildLog "Failed to load environment variables from JSON: $($_.Exception.Message)"
            }
        } else {
            Write-ChildLog "Environment variables JSON file not found: $EnvVarsJsonPath"
        }

        Write-ChildLog "Child phase started."
        Write-ChildLog "Security context: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

        $UDF = $env:UDF # This is included for Datto RMM use. It designates which user-defined field to store the output in.

        # -------------------------------------------------------------------
        # Your code to run as the logged-on user goes here.
        # If you have output that you want to capture and write to user-defined fields in Datto RMM, set the $myOutput variable to that output, and set the $UDF variable to the number of the user-defined field you want to write to (e.g. '1' for Custom1, '2' for Custom2, etc.). The script will handle writing the output to the appropriate registry location for the user-defined field when it returns to the parent phase.

        $myOutput = $env:USERNAME
        Write-ChildLog "env:USERNAME = $myOutput"

        # End of custom code.
        # -------------------------------------------------------------------

        # Check if udf ouput is desired
        if ($UDF -ne "none" -and $null -ne $UDF){
            Write-ChildLog "UDF environment variable is set to '$UDF', preparing to write output to '$dropFilePath'."
            $dattoDrop = @{} # Initialize the hashtable to store UDF values. This will be written to the drop file for the parent phase to read and write to the registry for Datto RMM user-defined fields.
            Ensure-Folder -Path $dropPath # Make sure the folder for the drop file exists.
            $dattoDrop[$UDF] = $myOutput # Store the audit output in the hashtable with the key being the UDF name. The parent phase will read this and write it to the appropriate registry location for Datto RMM user-defined fields.
            $dattoDrop | Export-Clixml -Path $dropFilePath -Encoding UTF8 # Write the hashtable to the drop file as XML for the parent phase to read. XML is used here instead of JSON because ConvertFrom-Json in PowerShell 5.x does not have the -AsHashtable parameter, which is needed to preserve the hashtable structure when writing and reading the drop file.
            # Check to see if the file was written successfully
            if (Test-Path -Path $dropFilePath) {
                Write-ChildLog "Successfully wrote UDF output to drop file: $dropFilePath"
            } else {
                Write-ChildLog "Failed to write UDF output to drop file: $dropFilePath"
            }
        }

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

    # Clean up any existing parent log to avoid confusion with previous runs. The first write to the parent log will create a new file, so we can be sure that all entries in the log are from the current run.
    if (Test-Path -LiteralPath $ParentLogPath) {
        Remove-Item -LiteralPath $ParentLogPath -Force -ErrorAction SilentlyContinue
    }

    Write-ParentLog "Parent phase started."
    Write-ParentLog "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-ParentLog "Original script path: $PSCommandPath"

    if (-not $PSCommandPath) {
        throw 'PSCommandPath is empty. This script must be run from a .ps1 file.'
    }

    Copy-Item -LiteralPath $PSCommandPath -Destination $CopiedScriptPath -Force
    Write-ParentLog "Copied script to: $CopiedScriptPath"

    # Clean up any existing log or exit code files from previous runs to avoid confusion. The user phase will create new ones when it runs.
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
            Write-ParentLog "Captured env:$varName"
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

        # -------------------------------------------------------------------
        # Datto Drop Sweeper 
        # This portion of the script is to get around a limitation in Datto RMM, where scritps run in the context of a non-privileged user cannot write to the appropriate registry location to populate Datto RMM user-defined fields.

        $dattoDrop = @{}
        # Check for existence of drop file
        If(Test-Path -Path $dropFilePath){
            $dattoDrop = Import-Clixml -Path $dropFilePath -ErrorAction Stop # Import the drop file as XML to get the hashtable of UDF values from the user phase.
            Remove-Item -Path $dropFilePath
        }

        # Write values to registry
        $dattoDrop.Keys | ForEach-Object {
            $myUDF = $_ # The number of the user-defined field to write to, which is the key in the dattoDrop hashtable.
            $myValue = $dattoDrop[$_] # The value to write to the user-defined field, which is the value in the dattoDrop hashtable.
            REG ADD "HKEY_LOCAL_MACHINE\SOFTWARE\CentraStage" /v Custom$myUDF /t REG_SZ /d "$myValue" /f # Write the value to the registry location for Datto RMM user-defined fields. The parent phase runs with enough privileges to write to this location, which allows the user phase to indirectly set user-defined field values by writing them to the drop file for the parent phase to read and write to the registry.
            Write-ParentLog "$myValue was saved to udf $myUDF"
        }
        
        # End of Datto Drop Sweeper
        # -------------------------------------------------------------------

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
        try {
            if (Test-Path -LiteralPath $CopiedScriptPath) {
                Remove-Item -LiteralPath $CopiedScriptPath -Force -ErrorAction SilentlyContinue
                Write-ParentLog "Removed copied script: $CopiedScriptPath"
            }
        }
        catch {
            Write-ParentLog "Failed to remove copied script: $($_.Exception.Message)"
        }
        try {
            if (Test-Path -LiteralPath $EnvVarsJsonPath) {
                Remove-Item -LiteralPath $EnvVarsJsonPath -Force -ErrorAction SilentlyContinue
                Write-ParentLog "Removed environment variables JSON file: $EnvVarsJsonPath"
            }
        }
        catch {
            Write-ParentLog "Failed to remove environment variables JSON file: $($_.Exception.Message)"
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
