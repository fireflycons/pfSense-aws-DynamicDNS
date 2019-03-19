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

    # An SNS Subscription can receive multiple SNS records in a single execution.
    foreach ($record in $LambdaInput.Records)
    {
        $changes = $record.Sns.Message.Replace('\"', '"') | ConvertFrom-Json

        $changes.DynamicIpChanges | Publish-IPChanges
    }
}

function Publish-IPChanges
{
    [CmdletBinding()]
    param
    (
        [Parameter(ValueFromPipeline = $true)]
        [PSObject[]]$IPChanges
    )

    begin
    {
    }

    process
    {
        Write-Host "Old IP: $($IPChanges.PreviousAddress), New IP: $($IPChanges.NewAddress)"

        $previousCidr = "$($IPChanges.PreviousAddress)/32"
        $newCidr = "$($IPChanges.NewAddress)/32"

        # Find all security groups in the account that have the ingress CIDR we want to change
        (Get-EC2SecurityGroup -Filter @{
                Name   = 'ip-permission.cidr'
                Values = $previousCidr
            }
        ) | Where-Object {
            $null -ne $_
        } |
            ForEach-Object {

            $ingressRulesUpdated = 0

            $groupId = $_.GroupId
            Write-Host "Updating $($groupId)"

            # Find existing IPPermissions with required CIDR
            ($_.IpPermissions |
                    Where-Object {
                    $_.IPv4Ranges.CidrIp -eq $previousCidr
                }) |
                Foreach-Object {

                $ipp = $_

                # Revoke it
                Revoke-EC2SecurityGroupIngress -GroupId $groupId -IpPermission $ipp

                # Change it
                $ipp.Ipv4Ranges |
                    Where-Object {
                    $_.CidrIp -eq $previousCidr
                } |
                    Foreach-Object {
                    $_.CidrIp = $newCidr
                }

                # Re-grant it
                Grant-EC2SecurityGroupIngress -GroupId $groupId -IpPermission $ipp
                ++$ingressRulesUpdated
            }

            Write-Host " - $ingressRulesUpdated ingress rules updated"
        }

        # Find all security groups in the account that have the egress CIDR we want to change
        (Get-EC2SecurityGroup -Filter @{
                Name   = 'egress.ip-permission.cidr'
                Values = $previousCidr
            }
        ) | Where-Object {
            $null -ne $_
        } |
            ForEach-Object {

            $egressRulesUpdated = 0

            $groupId = $_.GroupId
            Write-Host "Updating $($groupId)"

            # Find existing egress IPPermissions with required CIDR
            ($_.IpPermissionsEgress |
                    Where-Object {
                    $_.IPv4Ranges.CidrIp -eq $previousCidr
                }) |
                Foreach-Object {

                $ipp = $_

                # Revoke it
                Revoke-EC2SecurityGroupEgress -GroupId $groupId -IpPermission $ipp

                # Change it
                $ipp.Ipv4Ranges |
                    Where-Object {
                    $_.CidrIp -eq $previousCidr
                } |
                    Foreach-Object {
                    $_.CidrIp = $newCidr
                }

                # Re-grant it
                Grant-EC2SecurityGroupEgress -GroupId $groupId -IpPermission $ipp
                ++$egressRulesUpdated
            }

            Write-Host " - $egressRulesUpdated egress rules updated"
        }


    }

    end
    {
    }
}