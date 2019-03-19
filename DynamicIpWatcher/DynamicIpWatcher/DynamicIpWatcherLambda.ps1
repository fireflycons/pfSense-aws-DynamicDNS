# PowerShell script file to be executed as a AWS Lambda function.
#
# To include PowerShell modules with your Lambda function, like the AWSPowerShell.NetCore module, add a "#Requires" statement
# indicating the module and version.

# Require modules that should be loaded prior to execution
#Requires -Modules @{ModuleName='AWSPowerShell.NetCore';ModuleVersion='3.3.450.0'}

$ErrorActionPreference = 'Stop'

<#
    .SYNOPSIS
        Entry point for Lambda

    .PARAMETER LambdaInput
        A PSObject that contains the Lambda function input data.

    .PARAMETER LambdaContext
        An Amazon.Lambda.Core.ILambdaContext object that contains information about the currently running Lambda environment.

    .OUTPUTS
        The last item in the PowerShell pipeline will be returned as the result of the Lambda function.

    .NOTES
        You must tell Lambda to execute this function by defining the following variable in the Lambda environment
        AWS_POWERSHELL_FUNCTION_HANDLER=Invoke-Lambda

        Modifying the default template created by New-AWSPowerShellLambda in this way facilitates splitting
        the work into separate functions that are testable with Pester.
#>
function Invoke-Lambda
{
    param
    (
        [PSObject]$LambdaInput,
        [Amazon.Lambda.Core.ILambdaContext]$LambdaContext
    )

    try
    {
        # Get parameters from lambda environment

        # HOST_NAMES - Comma-separtated list of DNS host names to look up
        $hostNames = Get-ParametersFromEnvironment -EnvironmentVariable HOST_NAMES -Required

        # TOPIC_ARNS - Comma-separated list of topic ARNS to publish change notifications to.
        $topicArns = Get-ParametersFromEnvironment -EnvironmentVariable TOPIC_ARNS

        # SSM_KEY_PATH - Path in SSM parameter store under which persistent data for this function will be stored, e.g. /DynamicIp
        $ssmKeyPath = Get-ParametersFromEnvironment -EnvironmentVariable SSM_KEY_PATH -Required

        Watch-DynamicIp -DnsHostName $hostNames -NotificationTopicArns $topicArns -SSMKeyPath $ssmKeyPath
    }
    catch
    {
        Write-Host $_.ScriptStackTrace
        throw
    }
}

function Get-ParametersFromEnvironment
{
    <#
    .SYNOPSIS
        Get a value from lambda environment.
        Comma separated values are returned as an array.

    .PARAMETER EnvironmentVariable
        Environment variable to read

    .PARAMETER Required
        If set, the environment variable must exist and have a value

    .OUTPUTS
        The value of the variable

#>
    param
    (
        [string]$EnvironmentVariable,
        [switch]$Required
    )

    # Provider path to environment variable
    $path = "env:$EnvironmentVariable"

    # Is it defined
    if (-not (Test-Path -Path $path))
    {
        # Is it required
        if ($Required)
        {
            throw "Required environment variable $EnvironmentVariable is not present"
        }

        return
    }

    # It is defined, get its value
    $value = (Get-Item -Path $Path |
            Select-Object -ExpandProperty Value
    ) -split ',' |
        ForEach-Object {
        $_.Trim()
    }

    # Check it has a value if it's required
    if (-not $value -and $Required)
    {
        throw "Required environment variable $EnvironmentVariable does not have a value"
    }

    $value
}

function Get-IpAddressFromDns
{
    <#
    .SYNOPSIS
        Get first IP for given host

    .PARAMETER HostName
        Host to look up in DNS

    .OUTPUTS
        First IP address of given host; else $null if not found

    .NOTES
        Broken out into separate function to facilitate mocking
#>
    param
    (
        [string]$HostName
    )

    try
    {
        $hostEntry = [System.Net.Dns]::GetHostEntry($thisHost)
    }
    catch
    {
        # Host not found
        return $null
    }

    $hostEntry.AddressList |
        Select-Object -First 1 |
        Select-Object -ExpandProperty IPAddressToString
}

function Watch-DynamicIp
{
    <#
    .SYNOPSIS
        Checks to see if IP addresses of the given hosts have changed,
        and sends notification to the given topics if any have

    .PARAMETER DnsHostName
        Array of host names to check

    .PARAMETER NotificationTopicArns
        Array of topic ARNs to send notification to if any IP has changed.

    .PARAMETER SSMKeyPath
        Path in SSM parameter store under which persistent data for this function will be stored.
#>
    param
    (
        [string[]]$DnsHostName,

        [string[]]$NotificationTopicArns,

        [string]$SSMKeyPath = '/DynamicIP'
    )

    # This object forms the message that will be published to the SNS topic if anything has changed since last execution.
    $changes = New-Object PSObject -Property @{
        default = "AWS account $(Get-IAMAccountAlias): At least one dynamic IP has changed"
        lambda  = [string]::Empty
        email   = [string]::Empty
    }

    $dynamicIpChanges = @()

    # For each host that was defined in the environment
    foreach ($thisHost in $DnsHostName)
    {
        # Path to SSM key where we store the current IP address
        $parameterName = "$SSMKeyPath/$thisHost"

        $lastKnownIp = $null

        try
        {
            # Try to get stored IP address for this host
            $param = Get-SSMParameter -Name $parameterName
            $lastKnownIp = $param | Select-Object -ExpandProperty Value
        }
        catch
        {
            if ($_.Exception.Message -inotlike '*ParameterNotFound*')
            {
                # This is a real error
                throw
            }

            # Parameter doesn't exist, so this is a first time run
        }

        # Look up DNS for the current IP of this host
        $currentIp = Get-IpAddressFromDns -HostName $thisHost

        if ($null -eq $currentIp)
        {
            # Unknown host
            Write-Warning "Unknown host '$thisHost'"
            continue
        }

        if ($lastKnownIp -ne $currentIp)
        {
            # IP has changed since we last looked.
            # Set/Update the parameter store
            Write-SSMParameter -Name $parameterName -Type String -Value $currentIp -Overwrite $true -Force | Out-Null

            if ($null -ne $lastKnownIp)
            {
                # This is an update.
                # Store the change in the SNS message object
                Write-Host "NEW_IP: $($thisHost), IP: $currentIp"
                $dynamicIpChanges += New-Object PSObject -Property @{
                    Host            = $thisHost
                    PreviousAddress = $lastKnownIp
                    NewAddress      = $currentIp
                }
            }
            else
            {
                # It is a new host
                Write-Host "NEW_HOST: $($thisHost), IP: $currentIp"
            }
        }
        else
        {
            # The IP hasn't changed since last run
            Write-Host "NO_CHANGE: $($thisHost), IP: $currentIp"
        }
    }

    if (($dynamicIpChanges | Measure-Object).Count -gt 0)
    {
        # We saved some changes, now to publish them
        $changes.lambda = New-Object PSObject -Property @{
            DynamicIpChanges = $dynamicIpChanges
        } |
            ConvertTo-Json -Compress

        $json = $changes | ConvertTo-Json

        # Send any changes to subscribers
        $NotificationTopicArns |
            Where-Object {
            $null -ne $_
        } |
            ForEach-Object {

            Publish-SNSMessage -TopicArn $_ -MessageStructure json -Message $json -Subject "Dynamic IP Change, AWS account $(Get-IAMAccountAlias)" -Force
            Write-Host "Notified $_"
        }

        Write-Host $json
    }
}