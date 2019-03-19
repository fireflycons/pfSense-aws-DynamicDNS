param
(
    $Task = 'Default'
)

$currentLocation = Get-Location
try
{
    if ($PSVersionTable.PSEdition -ine 'Core')
    {
        throw "Canmot build in PowerShell $($PSVersionTable.PSEdition). PowerShell Core required."
    }

    Set-Location $PSScriptRoot

    # Grab nuget bits, install modules, set build variables, start build.
    Write-Host 'Setting up build environment'
    Get-PackageProvider -Name NuGet -ForceBootstrap | Out-Null

    $loadedModules = Get-Module | Select-Object -ExpandProperty Name
    $requiredModules = @(
        'psake'
        'BuildHelpers'
        'Pester',
        'AWSPowerShell.netcore'
        'AWSLambdaPSCore'
    )

    # List of modules not already loaded
    $missingModules = Compare-Object -ReferenceObject $requiredModules -DifferenceObject $loadedModules |
        Where-Object {
        $_.SideIndicator -eq '<='
    } |
        Select-Object -ExpandProperty InputObject

    if ($missingModules)
    {
        $installedModules = Get-Module -ListAvailable | Select-Object -ExpandProperty Name

        $neededModules = $requiredModules |
            Where-Object {
            -not ($installedModules -icontains $_)
        }

        if (($neededModules | Measure-Object).Count -gt 0)
        {
            Write-Host "Installing modules: $($neededModules -join ',')"
            Install-Module $neededModules -Force -AllowClobber -SkipPublisherCheck -Scope CurrentUser
        }

        Write-Host "Importing modules: $($missingModules -join ',')"
        Import-Module $missingModules
    }

    Set-BuildEnvironment -ErrorAction SilentlyContinue

    try
    {
        Invoke-psake -buildFile "$PSScriptRoot\psake.ps1" -taskList $Task -nologo
    }
    catch
    {
        $_.ScriptStackTrace
        throw
    }
    exit ( [int]( -not $psake.build_success ) )
}
catch
{
    Write-Error $_.Exception.Message

    # Make AppVeyor fail the build if this setup borks
    exit 1
}
finally
{
    Set-Location $currentLocation
}