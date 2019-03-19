
# PSake makes variables declared here available in other scriptblocks
# Init some things
Properties {

    # S3 bucket used to store placeholder (empty) lambda used for stack creation
    # Overridable from psake command line
    $PlaceholderBucket = "lm-placeholder-$([Amazon.Runtime.FallbackRegionFactory]::GetRegionEndpoint().SystemName)-040d48ff"

    # Find the build folder based on build system
    $ProjectRoot = $ENV:BHProjectPath
    if (-not $ProjectRoot)
    {
        $ProjectRoot = $PSScriptRoot
    }
    $ProjectRoot = Convert-Path $ProjectRoot

    try
    {
        $script:IsWindows = (-not (Get-Variable -Name IsWindows -ErrorAction Ignore)) -or $IsWindows
        $script:IsLinux = (Get-Variable -Name IsLinux -ErrorAction Ignore) -and $IsLinux
        $script:IsMacOS = (Get-Variable -Name IsMacOS -ErrorAction Ignore) -and $IsMacOS
        $script:IsCoreCLR = $PSVersionTable.ContainsKey('PSEdition') -and $PSVersionTable.PSEdition -eq 'Core'
    }
    catch { }

    $Timestamp = Get-date -uformat "%Y%m%d-%H%M%S"##
    $PSVersion = $PSVersionTable.PSVersion.Major
    $TestFile = "TestResults_PS$PSVersion`_$TimeStamp.xml"
    $lines = '----------------------------------------------------------------------'

    $Verbose = @{}
    if ($ENV:BHCommitMessage -match "!verbose")
    {
        $Verbose = @{Verbose = $True}
    }

    $DefaultLocale = 'en-US'
    $DocsRootDir = Join-Path $PSScriptRoot docs
    $LambdaScriptsDir = Join-Path  $PSSCriptRoot $env:BHProjectName

    $DeploymentProperties = (Get-Content (Join-Path $ProjectRoot deploy.json) -Raw) | ConvertFrom-Json
}

Task Init {
    $lines

    # Check we are authenticated with AWS
    if (-not (Test-Path -Path variable:StoredAWSCredentials))
    {
        throw "No AWS credential found. Please authenticate first."
    }

    Set-Location $ProjectRoot
    "Build System Details:"
    Get-Item ENV:BH*
    Write-Host "`n"

    # Add the stack if it exists as a deployment property
    $DeploymentProperties | Add-Member -MemberType NoteProperty -Name Stack -Value $(

        try
        {
            Get-CFNStack -StackName $DeploymentProperties.StackName
        }
        catch
        {
            $null
        }
    )

    # Determine what updates we will need to do
    $DeploymentProperties.Lambdas |
        ForEach-Object {

        $functionName = $_.Name

        $_ |
            Add-Member -PassThru -MemberType NoteProperty -Name CfnFunctionName -Value $null |
            Add-Member -PassThru -MemberType NoteProperty -Name SourceCode -Value ([IO.Path]::Combine($env:BHProjectPath, $env:BHProjectName, "$FunctionName.ps1")) |
            Add-Member -MemberType NoteProperty -Name Package -Value ([IO.Path]::Combine($env:BHBuildOutput, "$FunctionName.zip"))

        $sourceCode = Get-Item $_.SourceCode
        $package = Get-Item $_.Package -ErrorAction SilentlyContinue

        $_ | Add-Member -MemberType NoteProperty -Name RequiresUpdating -Value (-not ($package -and $DeploymentProperties.Stack) -or $sourceCode.LastWriteTimeUtc -gt $package.LastWriteTimeUtc)

        if ($DeploymentProperties.Stack)
        {
            $_.CfnFunctionName = $DeploymentProperties.Stack.Outputs |
                Where-Object {
                $_.OutputKey -ieq $functionName
            } |
                Select-Object -ExpandProperty OutputValue
        }
    }

    if (-not (Test-Path -Path $env:BHBuildOutput -PathType Container))
    {
        New-Item -Path $env:BHBuildOutput -ItemType Directory | Out-Null
    }
}

Task Default -Depends Deploy

Task Test -Depends Init {

    Write-Host $lines
    Write-Host "`n`tSTATUS: Testing with PowerShell $PSVersion"

    # Gather test results. Store them in a variable and file
    $pesterParameters = @{
        Path         = "$ProjectRoot\Tests"
        PassThru     = $true
        OutputFormat = "NUnitXml"
        OutputFile   = "$ProjectRoot\$TestFile"
    }

    if (-Not $IsWindows) { $pesterParameters["ExcludeTag"] = "WindowsOnly" }
    $TestResults = Invoke-Pester @pesterParameters

    # In Appveyor?  Upload our tests! #Abstract this into a function?
    If ($ENV:BHBuildSystem -eq 'AppVeyor')
    {
        (New-Object 'System.Net.WebClient').UploadFile(
            "https://ci.appveyor.com/api/testresults/nunit/$($env:APPVEYOR_JOB_ID)",
            "$ProjectRoot\$TestFile" )
    }

    Remove-Item "$ProjectRoot\$TestFile" -Force -ErrorAction SilentlyContinue

    # Failed tests?
    # Need to tell psake or it will proceed to the deployment. Danger!
    if ($TestResults.FailedCount -gt 0)
    {
        Write-Error "Failed '$($TestResults.FailedCount)' tests, build failed"
    }

    Write-Host "`n"
}

Task Package -Depends Test {

    Write-Host $lines

    $script:LambdaPackageDetails = $DeploymentProperties.Lambdas |
        Foreach-Object {

        if (($_.RequiresUpdating))
        {
            try
            {
                # Workaround bug - Exception: Tool 'amazon.lambda.tools' is already installed.
                & dotnet tool uninstall -g Amazon.Lambda.Tools | Out-Null
            }
            catch
            {
            }

            Write-Host "`n`tSTATUS: Packaging $($_.Name)`n"

            New-AWSPowerShellLambdaPackage -ScriptPath $_.SourceCode -OutputPackage $_.Package |
                Add-Member -Passthru -MemberType NoteProperty -Name FunctionName -Value $_.Name

        }
        else
        {
            Write-Host "`n`tSkipping Packaging of $($_.Name) as package is up to date."
        }
    }

    Write-Host
}

Task DeployBaseStack {

    Write-Host $lines

    $templateBody = Get-Content -Raw ([IO.Path]::Combine($ProjectRoot, 'CloudFormation', 'cloudFormation.json'))

    # Build stack parameters
    $parameters = $DeploymentProperties.Lambdas |
        ForEach-Object {
        $lambdaSettings = $_

        ('MemorySize', 'Timeout') |
            ForEach-Object {
            New-Object Amazon.CloudFormation.Model.Parameter -Property @{
                ParameterKey   = "$($lambdaSettings.Name)$($_)"
                ParameterValue = $lambdaSettings.$_
            }
        }
    }

    if (-not $DeploymentProperties.Stack)
    {
        # Build initial stack to deploy lambda roles and empty topic
        $stackArn = New-CFNStack -StackName $DeploymentProperties.StackName -TemplateBody $templateBody -Capability CAPABILITY_IAM -Parameter $parameters

        Write-Host "`n`tSTATUS: Waiting for stack creation to complete"

        $stack = Wait-CFNStack -StackName $stackArn -Timeout ([TimeSpan]::FromMinutes(60).TotalSeconds) -Status @('CREATE_COMPLETE', 'ROLLBACK_IN_PROGRESS')

        if ($stack.StackStatus -like '*ROLLBACK*')
        {
            Write-Host -ForegroundColor Red -BackgroundColor Black "Create failed: $stackArn"
            Write-Host -ForegroundColor Red -BackgroundColor Black (Get-StackFailureEvents -StackName $stackArn | Sort-Object -Descending Timestamp | Out-String)

            throw $stack.StackStatusReason
        }

        $DeploymentProperties.Stack = $stack

        # Pull Lambda names from new stack
        $DeploymentProperties.Lambdas |
            ForEach-Object {

            $lambda = $_

            $lambda.CfnFunctionName = $DeploymentProperties.Stack.Outputs |
                Where-Object {
                $_.OutputKey -ieq $lambda.Name
            } |
                Select-Object -ExpandProperty OutputValue
        }
    }
    else
    {
        try
        {
            $stackArn = $DeploymentProperties.Stack.StackId
            Update-CFNStack -StackName $stackArn -Capability CAPABILITY_IAM -TemplateBody $templateBody -Parameter $parameters | Out-Null

            Write-Host "`n`tSTATUS: Waiting for stack update to complete"
            $stack = Wait-CFNStack -StackName $stackArn -Timeout ([TimeSpan]::FromMinutes(60).TotalSeconds) -Status @('UPDATE_COMPLETE', 'UPDATE_ROLLBACK_IN_PROGRESS')

            if ($stack.StackStatus -like '*ROLLBACK*')
            {
                Write-Host -ForegroundColor Red -BackgroundColor Black "Update failed: $stackArn"
                Write-Host -ForegroundColor Red -BackgroundColor Black (Get-StackFailureEvents -StackName $stackArn | Sort-Object -Descending Timestamp | Out-String)

                throw $stack.StackStatusReason
            }
        }
        catch
        {
            if ($_.Exception.Message -inotlike '*No updates are to be performed*')
            {
                throw
            }
            else
            {
                Write-Host "`n`tNo update to base stack."
            }
        }
    }
}

Task DeployLambdas {

    Write-Host $lines

    $stack = Get-CFNStack -StackName $DeploymentProperties.StackName

    # Deploy the lambdas
    $DeploymentProperties.Lambdas |
        Where-Object {
        $_.RequiresUpdating
    } |
        Foreach-Object {

        $lambda = $_

        $packageDetail = $script:LambdaPackageDetails |
            Where-Object {
            $_.FunctionName -eq $lambda.Name
        }

        Write-Host "`n`tSTATUS: Publishing $($lambda.Name)"

        # Build environment
        $env = @{}

        $lambda.Environment |
            ForEach-Object {

            if ($_.Value -imatch '\$\{Stack.Outputs.(?<output>\w+)\}')
            {
                $val = $stack.Outputs |
                    Where-Object {
                    $_.OutputKey -ieq $Matches.output
                } |
                    Select-Object -ExpandProperty OutputValue

                $env.Add($_.Name, $val)
            }
            else
            {
                $env.Add($_.Name, $_.Value)
            }
        }

        Write-Host "`t`tUpdating configuration: $($lambda.CfnFunctionName)"
        Update-LMFunctionConfiguration -FunctionName $lambda.CfnFunctionName `
            -Environment_Variable $env `
            -Handler $packageDetail.LambdaHandler `
            -Runtime 'dotnetcore2.1' `
            -Force |
            Out-Null


        Write-Host "`t`tUpdating code: $($lambda.CfnFunctionName)"
        Update-LMFunctionCode -FunctionName $lambda.CfnFunctionName `
            -ZipFilename $packageDetail.PathToPackage `
            -Publish `
            -Force |
            Out-Null
    }
}

Task Deploy -Depends Package, DeployBaseStack, DeployLambdas

function Get-StackFailureEvents
{
    <#
    .SYNOPSIS
        Gets failure event list from a briken stack
    #>
    param
    (
        [string]$StackName
    )

    Get-CFNStackEvent -StackName $StackName |
        Where-Object {
        $_.ResourceStatus -ilike '*FAILED*' -or $_.ResourceStatus -ilike '*ROLLBACK*'
    }

    Get-CFNStackResourceList -StackName $StackName |
        Where-Object {
        $_.ResourceType -ieq 'AWS::CloudFormation::Stack'
    } |
        ForEach-Object {

        if ($_ -and $_.PhysicalResourceId)
        {
            Get-StackFailureEvents -StackName $_.PhysicalResourceId -CredentialArguments
        }
    }
}
