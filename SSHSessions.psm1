#requires -version 3


<#
.SYNOPSIS
    A set of functions for dealing with SSH connections from PowerShell, using the SSH.NET
    library found here on CodePlex: http://sshnet.codeplex.com/

    See further documentation at:
    http://www.powershelladmin.com/wiki/SSH_from_PowerShell_using_the_SSH.NET_library

    Copyright (c) 2012-2017, Joakim Borger Svendsen.
    All rights reserved.
    Svendsen Tech.
    Author: Joakim Borger Svendsen.

    MIT license.

.DESCRIPTION
    See:
    Get-Help New-SshSession
    Get-Help Get-SshSession
    Get-Help Invoke-SshCommand
    Get-Help Enter-SshSession
    Get-Help Remove-SshSession

    http://www.powershelladmin.com/wiki/SSH_from_PowerShell_using_the_SSH.NET_library

2017-01-26: Rewriting a bit (about damn time). Not fixing completely.
            No concurrency for now either. Preparing to publish to PS gallery.

#>


function New-SshSession {
    <#
    .SYNOPSIS
        Creates SSH sessions to remote SSH-compatible hosts, such as Linux
        or Unix computers or network equipment. You can later issue commands
        to be executed on one or more of these hosts.

    .DESCRIPTION
        Once you've created a session, you can use Invoke-SshCommand or Enter-SshSession
        to send commands to the remote host or hosts.

        The authentication is done here. If you specify -KeyFile, that will be used.
        If you specify a password and no key, that will be used. If you do not specify
        a key nor a password, you will be prompted for a password, and you can enter
        it securely with asterisks displayed in place of the characters you type in.

    .PARAMETER ComputerName
        Required. DNS names or IP addresses for target hosts to establish
        a connection to using the provided username and key/password.
    .PARAMETER KeyFile
        Optional. Specify the path to a private key file for authenticating.
        Overrides a specified password.
    .PARAMETER KeyCredential
        Optional PSCredentials object (help Get-Credential) with the key file password
        in the password field.
    .PARAMETER Credential
        PSCredentials object containing a username and an encrypted password.
    .PARAMETER Port
        Optional. Default 22. Target port the SSH server uses.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ValueFromPipeline,ValueFromPipelineByPropertyName)]
        [String[]]$ComputerName,
        [Parameter(ValueFromPipelineByPropertyName)]
        [String]$KeyFile,
        [Parameter(ValueFromPipelineByPropertyName)]
        [PSCredential]$KeyCredential,
        [Parameter(ValueFromPipelineByPropertyName)]
        [PSCredential]$Credential=[PSCredential]::Empty,
        [Parameter(ValueFromPipelineByPropertyName)]
        [Int32]$Port=22,
        [Parameter(ValueFromPipelineByPropertyName)]
        [Switch]$Reconnect
    )

    begin {
        if ($KeyFile) {
            Write-Verbose -Message "Key file specified. Will override password. Trying to read key file..."
            # TODO: Test this and fix it.  I'm sure it broke when I removed plain text credentials.
            if (Test-Path -PathType Leaf -Path $Keyfile) {
                if (-not $KeyCredential) {
                    $Key = New-Object -TypeName Renci.SshNet.PrivateKeyFile -ArgumentList $Keyfile -ErrorAction Stop
                }
                else {
                    $Key = New-Object -TypeName Renci.SshNet.PrivateKeyFile -ArgumentList $Keyfile,$KeyCredential.GetNetworkCredential().Password -ErrorAction Stop
                }
            }
            else {
                Write-Error -Message "Specified keyfile does not exist: '$KeyFile'." -ErrorAction Stop
                break
            }
        }
        else {
            $Key = $null
        }
    }
    process {
        # Let's start creating sessions and storing them in $Global:SshSessions
        foreach ($Computer in $ComputerName) {
            if ($Global:SshSessions.ContainsKey($Computer) -and $Reconnect) {
                Write-Verbose -Message "[$Computer] Reconnecting."
                try {
                    $Null = Remove-SshSession -ComputerName $Computer -ErrorAction Stop
                }
                catch {
                    Write-Warning -Message "[$Computer] Unable to disconnect SSH session. Skipping connect attempt."
                    continue
                }
            }
            elseif ($Global:SshSessions.ContainsKey($Computer) -and $Global:SshSessions.$Computer.IsConnected) {
                Write-Verbose -Message "[$Computer] You are already connected." -Verbose
                continue
            }
            try {
                if ($Key) {
                    $SshClient = New-Object -TypeName Renci.SshNet.SshClient -ArgumentList $Computer, $Port, $Credential.Username, $Key
                }
                else {
                    $SshClient = New-Object -TypeName Renci.SshNet.SshClient -ArgumentList $Computer, $Port, $Credential.Username, $Credential.GetNetworkCredential().Password
                }
            }
            catch {
                Write-Warning -Message "[$Computer] Unable to create SSH client object: $_"
                continue
            }
            try {
                $SshClient.Connect()
            }
            catch {
                Write-Warning -Message "[$Computer] Unable to connect: $_"
                continue
            }
            if ($SshClient -and $SshClient.IsConnected) {
                Write-Verbose -Message "[$Computer] Successfully connected."
                $Global:SshSessions.$Computer = $SshClient
                Get-SshSession -ComputerName $Computer
            }
            else {
                Write-Warning -Message "[$Computer] Unable to connect."
                continue
            }
        } # end of foreach
    }
    end {
        # Shrug... Can't hurt although I guess they should go out of scope here anyway.
        $KeyPass, $SecurePassword, $Password = $null, $null, $null
        [System.GC]::Collect()
    }
}

function Invoke-SshCommand {
    <#
    .SYNOPSIS
        Invoke/run commands via SSH on target hosts to which you have already opened
        connections using New-SshSession. See Get-Help New-SshSession.

    .DESCRIPTION
        Execute/run/invoke commands via SSH.

        You are already authenticated and simply specify the target(s) and the command.

        Output is emitted to the pipeline, so you collect results by using:
        $Result = Invoke-SshCommand [...]

        $Result there would be either a System.String if you target a single host or a
        System.Array containing strings if you target multiple hosts.

    .PARAMETER ComputerName
        Target hosts to invoke command on.
    .PARAMETER Command
        Required unless you use -ScriptBlock. The Linux command to run on specified target computers.
    #>
    [CmdletBinding(DefaultParameterSetName = "String")]
    param(
        [Parameter(Mandatory,ValueFromPipeline,ValueFromPipelineByPropertyName,Position=0)]
        [String[]]$ComputerName,
        [Parameter(Mandatory,ParameterSetName="String",Position=1)]
        [String]$Command
        # TODO: Make reconnects happen.
        # TODO: Support expect-like constructs (e.g. for sudo).
    )
    begin {
    }
    process {
        foreach ($Computer in $ComputerName) {
            if (-not $Global:SshSessions.ContainsKey($Computer)) {
                #Write-Verbose -Message "No SSH session found for $Computer. See Get-Help New-SshSession. Skipping."
                Write-Warning -Message "[$Computer] No SSH session found. See Get-Help New-SshSession. Skipping."
                continue
            }
            if (-not $Global:SshSessions.$Computer.IsConnected) {
                #Write-Verbose -Message "You are no longer connected to $Computer. Skipping."
                Write-Warning -Message "[$Computer] You are no longer connected. Skipping."
                continue
            }
            $CommandObject = $Global:SshSessions.$Computer.RunCommand($Command)

            $Properties = @{
                ComputerName=$Computer
                Result=($CommandObject.Result -replace '[\r\n]+\z')
                ExitStatus=$CommandObject.ExitStatus
            }
            New-Object -Type PSObject -Property $Properties | Select-Object ComputerName,Result,ExitStatus
            if ($Properties["ExitStatus"] -ne 0) {
                Write-Warning "Error occurred with command for $Computer."
            }

            $CommandObject.Dispose()
            $CommandObject = $Null
        }
    }
    end {
        [System.GC]::Collect()
    }
}

function Enter-SshSession {
    <#
    .SYNOPSIS
        Enter a primitive interactive SSH session against a target host.
        Commands are executed on the remote host as you type them and you are
        presented with a Linux-like prompt.

    .DESCRIPTION
        Enter commands that will be executed by the host you specify and have already
        opened a connection to with New-SshSession.

        You can not permanently change the current working directory on the remote host.

    .PARAMETER ComputerName
        Required. Target host to connect with.
    .PARAMETER NoPwd
        Optional. Do not try to include the default remote working directory in the prompt.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,
        [Parameter()]
        [switch] $NoPwd
    )
    if (-not $Global:SshSessions.ContainsKey($ComputerName)) {
        Write-Error -Message "[$Computer] No SSH session found. See Get-Help New-SshSession. Skipping." `
            -ErrorAction Stop
        return
    }
    if (-not $Global:SshSessions.$ComputerName.IsConnected) {
        Write-Error -Message "[$Computer] The connection has been lost. See Get-Help New-SshSession and notice the -Reconnect parameter." `
            -ErrorAction Stop
        return
    }
    $SshPwd = ''
    # Get the default working dir of the user (won't be updated...)
    if (-not $NoPwd) {
        $SshPwdResult = $Global:SshSessions.$ComputerName.RunCommand('pwd')
        if ($SshPwdResult.ExitStatus -eq 0) {
            $SshPwd = $SshPwdResult.Result.TrimEnd()
        }
        else {
            $SshPwd = '(pwd failed)'
        }
    }
    $Command = ''
    while (1) {
        if (-not $Global:SshSessions.$ComputerName.IsConnected) {
            Write-Error -Message "[$Computer] Connection lost." -ErrorAction Stop
            return
        }
        $Command = Read-Host -Prompt "[$ComputerName]: $SshPwd # "
        # Break out of the infinite loop if they type "exit" or "quit"
        if ($Command -ieq 'exit' -or $Command -ieq 'quit') {
            break
        }
        $Result = $Global:SshSessions.$ComputerName.RunCommand($Command)
        if ($Result.ExitStatus -eq 0) {
            $Result.Result -replace '[\r\n]+\z', ''
        }
        else {
            $Result.Error -replace '[\r\n]+\z', ''
        }
    } # end of while
}

function Remove-SshSession {
    <#
    .SYNOPSIS
        Removes opened SSH connections. Use the parameter -RemoveAll to remove all connections.

    .DESCRIPTION
        Performs disconnect (if connected) and dispose on the SSH client object, then
        sets the $global:SshSessions hashtable value to $null and then removes it from
        the hashtable.

    .PARAMETER ComputerName
        The names of the hosts for which you want to remove connections/sessions.
    .PARAMETER RemoveAll
        Removes all open connections and effectively empties the hash table.
        Overrides -ComputerName, but you will be asked politely if you are sure,
        if you specify both.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline,ValueFromPipelineByPropertyName)]
        # TODO: Make a wildcard parameter.
        [String[]]$ComputerName, # can't have it mandatory due to -RemoveAll
        # TODO: Remove when previous is wildcard parameter.
        [Switch]$RemoveAll
    )
    begin {
        if ($RemoveAll) {
            if ($ComputerName) {
                $Answer = Read-Host -Prompt "You specified both -RemoveAll and -ComputerName. -RemoveAll overrides and removes all connections.`nAre you sure you want to continue? (y/n) [yes]"
                if ($Answer -imatch 'n') {
                    break
                }
            }
            if ($Global:SshSessions.Keys.Count -eq 0) {
                Write-Warning -Message "Parameter -RemoveAll specified, but no hosts found."
                # This terminates the calling script (I had noe clue it behaved like that, honestly, was surprised).
                # My workaround relies on that the process block will not be run when you pipe in an
                # "empty Get-SshSession".
                #break
            }
            # Get all computer names from the global SshSessions hashtable.
            $ComputerName = $Global:SshSessions.Keys | Sort-Object
        }
        <# The logic breaks with pipeline input from Get-SshSession
        if (-not $ComputerName) {
            "No computer names specified and -RemoveAll not specified. Can not continue."
            break
        }#>
    }
    process {
        foreach ($Computer in $ComputerName) {
            if (-not $Global:SshSessions.ContainsKey($Computer)) {
                Write-Warning -Message "[$Computer] The SSH client pool does not contain a session for this computer. Skipping."
                continue
            }
            $ErrorActionPreference = 'Continue'
            if ($Global:SshSessions.$Computer.IsConnected) { $Global:SshSessions.$Computer.Disconnect() }
            $Global:SshSessions.$Computer.Dispose()
            $Global:SshSessions.$Computer = $null
            $Global:SshSessions.Remove($Computer)
            $ErrorActionPreferene = $MyEAP
            Write-Verbose -Message "[$Computer] Now disconnected and disposed."
        }
    }
}

function Get-SshSession {
    <#
    .SYNOPSIS
        Shows all, or the specified, SSH sessions in the global $SshSessions variable,
        along with the connection status.

    .DESCRIPTION
        It checks if they're still reported as connected and reports that too. However,
        they can have a status of "connected" even if the remote computer has rebooted.
        Seems like an issue with the SSH.NET library and how it maintains this status.

        If you specify hosts with -ComputerName, which don't exist in the $SshSessions
        variable, the "Connected" value will be "NULL" for these hosts.

        Also be aware that with the version of the SSH.NET library at the time of writing,
        the host will be reported as connected even if you use the .Disconnect() method
        on it. When you invoke the .Dispose() method, it does report the connection status
        as false.

    .PARAMETER ComputerName
        Optional. The default behavior is to list all hosts alphabetically, but this
        lets you specify hosts to target specifically. NULL is returned as the connection
        status if a non-existing host name/IP is passed in.
    #>
    
    [CmdletBinding()]
    param(
        [string[]]$ComputerName
    )
    
    begin {
        # Just exit with a message if there aren't any connections.
        if ($Global:SshSessions.Count -eq 0) {
            Write-Warning -Message "No connections found."
            # This terminates the calling script too (so I learned today, at least in v5.1). Removing.
            #break
        }
    }
    process {
        if (-not $ComputerName) { $ComputerName = $Global:SshSessions.Keys | Sort-Object -Property @{
            Expression = {
                # Intent: Sort IP addresses correctly.
                [Regex]::Replace($_, '(\d+)', { '{0:D16}' -f [int] $args[0].Value }) }
            }, @{ Expression = { $_ } }
        }
        foreach ($Computer in $ComputerName) {        
            # Unless $ComputerName is specified, use all hosts in the global variable, sorted alphabetically.
            $Properties =
                @{n='ComputerName';e={$_}},
                @{n='Connected';e={
                    # Ok, this isn't too pretty... Populate non-existing objects'
                    # "connected" value with $null
                    if ($Global:SshSessions.ContainsKey($_)) {
                        $Global:SshSessions.$_.IsConnected
                    }
                    else {
                        $Null
                    }
                }}
            # Process the hosts and emit output to the pipeline.
            $Computer | Select-Object -Property $Properties
        }
    }
}
######## END OF FUNCTIONS ########
Set-StrictMode -Version Latest
$MyEAP = 'Stop'
$ErrorActionPreference = $MyEAP
$Global:SshSessions = @{}
#Export-ModuleMember New-SshSession, Invoke-SshCommand, Enter-SshSession, `
#                    Remove-SshSession, Get-SshSession
