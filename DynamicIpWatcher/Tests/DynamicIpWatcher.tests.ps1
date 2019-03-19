Import-Module AWSPowerShell.NetCore

<#
    .SYNOPSIS
        Class that mocks the SSM parameter store.
#>
class MockParameterStore
{
    [hashtable]$Parameters = @{}

    MockParameterStore()
    {
    }

    [object]GetParameter([string]$name)
    {
        if ($this.Parameters.ContainsKey($name))
        {
            return New-Object PSObject -Property @{
                Name  = $name
                Value = $this.Parameters[$name]
            }
        }

        throw "ParameterNotFound"
    }

    [int64]PutParameter([string]$name, [string]$value)
    {
        $this.Parameters[$name] = $value

        # Version number - not relevant in context of these tests
        return 1
    }
}


# Dot source Lambda script.
. (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..', 'DynamicIpWatcher', 'DynamicIpWatcherLambda.ps1'))).Path

$parameterStore = [MockParameterStore]::new()

Describe 'Dynamic IP Watcher' {

    Mock 'Publish-SNSMessage' -MockWith {}

    Mock 'Get-SSMParameter' -MockWith {

        $parameterStore.GetParameter($Name)
    }

    Mock 'Write-SSMParameter' -MockWith {

        $parameterStore.PutParameter($Name, $Value)
    }

    Mock 'Write-Host' -MockWith {

        # Capture Write-Host so we can assert what it will log to CloudWatch
        if (-not [string]::IsNullOrEmpty($global:writeHostBuffer))
        {
            $global:writeHostBuffer += [Environment]::NewLine
        }

        $global:writeHostBuffer += [string]$Object
    }

    Mock 'Write-Warning' -MockWith {

        # Capture Write-Warning so we can assert what it will log to CloudWatch
        if (-not [string]::IsNullOrEmpty($global:writeWarningBuffer))
        {
            $global:writeWarningBuffer += [Environment]::NewLine
        }

        $global:writeWarningBuffer += $Message
    }

    BeforeEach {

        # Clear message capture buffers
        $global:writeHostBuffer = [string]::Empty
        $global:writeWarningBuffer = [string]::Empty
    }

    Context 'Lambda environment' {

        It 'Returns nothing for undefined variable' {

            -not (Get-ParametersFromEnvironment -EnvironmentVariable DOES_NOT_EXIST) | Should -Be $true
        }

        It 'Returns nothing for defined variable with no value' {

            $env:EMPTY_VAR = [string]::Empty
            -not (Get-ParametersFromEnvironment -EnvironmentVariable EMPTY_VAR) | Should -Be $true
        }

        It 'Should throw if undefined variable is required' {

            { Get-ParametersFromEnvironment -EnvironmentVariable DOES_NOT_EXIST -Required } | Should Throw
        }

        It 'Should throw if defined variable with no value is required' {

            { Get-ParametersFromEnvironment -EnvironmentVariable EMPTY_VAR -Required } | Should Throw
        }

        It 'Should return a single arn from TOPIC_ARN variable' {

            $expected = 'arn:aws:sns:eu-west-1:123456789012:my-topic'
            $env:TOPIC_ARNS = $expected
            Get-ParametersFromEnvironment -EnvironmentVariable TOPIC_ARNS -Required | Should -Be $expected
        }

        It 'Should return a list of arns from TOPIC_ARN variable' {

            $expected = @('arn:aws:sns:eu-west-1:123456789012:my-topic', 'arn:aws:sns:eu-west-1:123456789012:my-other-topic')
            $env:TOPIC_ARNS = $expected -join ','
            Get-ParametersFromEnvironment -EnvironmentVariable TOPIC_ARNS -Required | Should -Be $expected
        }

        It 'Should return a single host from HOST_NAMES variable' {

            $expected = 'my.dynamichost.com'
            $env:HOST_NAMES = $expected
            Get-ParametersFromEnvironment -EnvironmentVariable HOST_NAMES -Required | Should -Be $expected
        }

        It 'Should return a list of hosts from HOST_NAMES variable' {

            $expected = @('my.dynamichost.com', 'my.otherdynamichost.com')
            $env:HOST_NAMES = $expected -join ','
            Get-ParametersFromEnvironment -EnvironmentVariable HOST_NAMES -Required | Should -Be $expected
        }

        AfterAll {

            'EMPTY_VAR', 'HOST_NAMES', 'TOPIC_ARNS', 'SSM_KEY_PATH' |
            ForEach-Object {

                $p = "env:$_"

                if (Test-Path -Path $p)
                {
                    Remove-Item $p
                }
            }
        }
    }

    Context 'Single existing host' {

        Mock 'Get-IpAddressFromDns' -MockWith {

            if ($HostName -ieq 'host.exists.com')
            {
                return '1.1.1.1'
            }

            if ($HostName -ieq 'host2.exists.com')
            {
                return '2.2.2.2'
            }

            $null
        }

        It 'Adds new host to parameter store' {

            $parameterStore.Parameters.Count | Should -Be 0
            Watch-DynamicIp -DnsHostName 'host.exists.com' -NotificationTopicArns 'arn:aws:sns:us-west-2:111122223333:MyTopic'
            $writeHostBuffer | Should -Be "NEW_HOST: host.exists.com, IP: 1.1.1.1"
            Assert-MockCalled Publish-SNSMessage -Times 0
        }

        It 'Retrieves existing host from parameter store' {

            $parameterStore.Parameters.Count | Should -Be 1
            Watch-DynamicIp -DnsHostName 'host.exists.com' -NotificationTopicArns 'arn:aws:sns:us-west-2:111122223333:MyTopic'
            $writeHostBuffer | Should -Be "NO_CHANGE: host.exists.com, IP: 1.1.1.1"
            Assert-MockCalled Publish-SNSMessage -Times 0
        }
    }

    Context "Host that doesn't exist" {

        It "Warns when host doesn't exist" {

            Watch-DynamicIp -DnsHostName 'host.doesnotexist.com' -NotificationTopicArns 'arn:aws:sns:us-west-2:111122223333:MyTopic'
            $writeWarningBuffer | Should -Be "Unknown host 'host.doesnotexist.com'"
            Assert-MockCalled Publish-SNSMessage -Times 0
        }
    }

    Context 'Multiple existing hosts' {

        Mock 'Get-IpAddressFromDns' -MockWith {

            if ($HostName -ieq 'host.exists.com')
            {
                return '1.1.1.1'
            }

            if ($HostName -ieq 'host2.exists.com')
            {
                return '2.2.2.2'
            }

            $null
        }

        $parameterStore = [MockParameterStore]::new()

        It 'Adds new hosts to parameter store' {

            $parameterStore.Parameters.Count | Should -Be 0
            Watch-DynamicIp -DnsHostName 'host.exists.com','host2.exists.com' -NotificationTopicArns 'arn:aws:sns:us-west-2:111122223333:MyTopic'
            $writeHostBuffer | Should -Be ("NEW_HOST: host.exists.com, IP: 1.1.1.1" + [Environment]::NewLine + "NEW_HOST: host2.exists.com, IP: 2.2.2.2")
            Assert-MockCalled Publish-SNSMessage -Times 0
        }

        It 'Retrieves existing hosts from parameter store' {

            $parameterStore.Parameters.Count | Should -Be 2
            Watch-DynamicIp -DnsHostName 'host.exists.com','host2.exists.com' -NotificationTopicArns 'arn:aws:sns:us-west-2:111122223333:MyTopic'
            $writeHostBuffer | Should -Be ("NO_CHANGE: host.exists.com, IP: 1.1.1.1" + [Environment]::NewLine + "NO_CHANGE: host2.exists.com, IP: 2.2.2.2")
            Assert-MockCalled Publish-SNSMessage -Times 0
        }
    }

    Context 'Detects IP Change' {

        # Re-mock to return a different IP to that currently stored in SSM
        Mock 'Get-IpAddressFromDns' -MockWith {

            if ($HostName -ieq 'host.exists.com')
            {
                # Return a new IP for this host
                return '1.1.1.2'
            }

            if ($HostName -ieq 'host2.exists.com')
            {
                return '2.2.2.2'
            }

            $null
        }

        It 'Detects IP change' {

            Watch-DynamicIp -DnsHostName 'host.exists.com' -NotificationTopicArns 'arn:aws:sns:us-west-2:111122223333:MyTopic','arn:aws:sns:us-west-2:111122223333:MyOtherTopic'
            $resultOutput = $writeHostBuffer -split ([Environment]::NewLine)

            $resultOutput[0] | Should -Be "NEW_IP: host.exists.com, IP: 1.1.1.2"
            $resultOutput[1] | Should -Be "Notified arn:aws:sns:us-west-2:111122223333:MyTopic"
            $resultOutput[2] | Should -Be "Notified arn:aws:sns:us-west-2:111122223333:MyOtherTopic"

            # Publish-SNSMessage should be called once for each notification ARN
            Assert-MockCalled Publish-SNSMessage -Times 2 -Exactly
        }
    }
}
