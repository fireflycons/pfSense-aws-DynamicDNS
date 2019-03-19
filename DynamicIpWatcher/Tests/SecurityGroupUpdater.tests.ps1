Import-Module AWSPowerShell.NetCore

# Dot source Lambda script.
. (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..', 'DynamicIpWatcher', 'SecurityGroupUpdaterLambda.ps1'))).Path

<#
    .SYNOPSIS
        Mock up how security groups are managed - sufficient for purpose of these tests
#>
class MockSecurityGroups
{
    static [int]$sgId = 0

    [System.Collections.Generic.List[Amazon.EC2.Model.SecurityGroup]]$groups = [System.Collections.Generic.List[Amazon.EC2.Model.SecurityGroup]]::new()

    MockSecurityGroups()
    {
    }

    [void]CreateSecurityGroup([string]$ingressCidrIp, [string]$egressCidrIp)
    {
        $sg = New-Object Amazon.EC2.Model.SecurityGroup -Property @{
            Description         = 'Mock security group'
            GroupId             = 'sg-{0:D8}' -f (++[MockSecurityGroups]::sgId)
            GroupName           = 'mock-security-=group'
            OwnerId             = '000000000000'
            VpcId               = 'vpc-00000001'
        }

        if ($ingressCidrIp)
        {
            $sg.IpPermissions = @(
                New-Object Amazon.EC2.Model.IpPermission -Property @{
                    FromPort   = 80
                    ToPort     = 80
                    IpProtocol = 'tcp'
                    Ipv4Ranges = @(
                        New-Object Amazon.EC2.Model.IpRange -Property @{
                            CidrIp      = $ingressCidrIp
                            Description = 'Test Range'
                        }
                    )
                }
            )
        }

        if ($egressCidrIp)
        {
            $sg.IpPermissionsEgress = @(
                New-Object Amazon.EC2.Model.IpPermission -Property @{
                    FromPort   = 5432
                    ToPort     = 5432
                    IpProtocol = 'udp'
                    Ipv4Ranges = @(
                        New-Object Amazon.EC2.Model.IpRange -Property @{
                            CidrIp      = $egressCidrIp
                            Description = 'Test Range'
                        }
                    )
                }
            )
        }

        $this.groups.Add($sg)
    }

    [Amazon.EC2.Model.SecurityGroup]GetById([string]$groupId)
    {
        $sg = $this.groups |
        Where-Object {
            $_.GroupId -eq $groupId
        }

        if (-not $sg)
        {
            throw "The security group '$groupId' does not exist"
        }

        return $sg
    }

    [Amazon.EC2.Model.SecurityGroup[]]GetByFilter([Amazon.EC2.Model.Filter[]]$filter)
    {
        # For the purpose of the code under test, we only ever pass a single filter, with a single value
        $f = $filter | Select-Object -First 1

        if (-not $f)
        {
            return $null
        }

        $sg = $null

        switch ($f.Name)
        {
            'ip-permission.cidr'
            {
                $sg = $this.groups |
                Where-Object {
                    $_.IpPermissions.Ipv4Ranges.CidrIp -contains ($f.Values | Select-Object -First 1)
                }
            }

            'egress.ip-permission.cidr'
            {
                $sg = $this.groups |
                Where-Object {
                    $_.IpPermissionsEgress.Ipv4Ranges.CidrIp -contains ($f.Values | Select-Object -First 1)
                }
            }
        }

        return $sg
    }

    [void]Clear()
    {
        $this.groups.Clear()
        [MockSecurityGroups]::sgId = 0
    }

    [void]GrantIngressRule([string]$groupId, [Amazon.EC2.Model.IpPermission[]]$ipp)
    {
        $sg = $this.GetById($groupId)

        $ipp | Foreach-Object {
            $sg.IpPermissions.Add($_)
        }
    }

    [void]RevokeIngressRule([string]$groupId, [Amazon.EC2.Model.IpPermission[]]$ipp)
    {
        $sg = $this.GetById($groupId)
        $c = $ipp.Clone()

        $c | Foreach-Object {
            $sg.IpPermissions.Remove($_)
        }
    }

    [void]GrantEgressRule([string]$groupId, [Amazon.EC2.Model.IpPermission[]]$ipp)
    {
        $sg = $this.GetById($groupId)

        $ipp | Foreach-Object {
            $sg.IpPermissionsEgress.Add($_)
        }
    }

    [void]RevokeEgressRule([string]$groupId, [Amazon.EC2.Model.IpPermission[]]$ipp)
    {
        $sg = $this.GetById($groupId)

        $ipp.Clone() | Foreach-Object {
            $sg.IpPermissionsEgress.Remove($_)
        }
    }
}

$mockSecurityGroups = [MockSecurityGroups]::new()

Describe 'Mock Security Group Class' {

    Mock -CommandName Get-EC2SecurityGroup -MockWith {

        if ($GroupId)
        {
            $mockSecurityGroups.GetById($GroupId)
        }
        elseif ($Filter)
        {
            $mockSecurityGroups.GetByFilter($Filter)
        }
        else
        {
            throw "Unsupported arguments"
        }
    }

    BeforeAll {
        $mockSecurityGroups.CreateSecurityGroup('1.1.1.1/32', $null) # sg-00000001
        $mockSecurityGroups.CreateSecurityGroup($null, '2.2.2.2/32') # sg-00000002
    }

    AfterAll {
        $mockSecurityGroups.Clear()
    }

    It 'Gets security group by ID' {

        { $mockSecurityGroups.GetById('sg-00000001') } | Should Not Throw
    }

    It 'Gets security group by ingress filter' {

        $groups = $mockSecurityGroups.GetByFilter(@{ Name = 'ip-permission.cidr'; Values = '1.1.1.1/32' })
        $groups.GroupId | Should -Be 'sg-00000001'
    }

    It 'Gets security group by egress filter' {

        $groups = $mockSecurityGroups.GetByFilter(@{ Name = 'egress.ip-permission.cidr'; Values = '2.2.2.2/32' })
        $groups.GroupId | Should -Be 'sg-00000002'
    }

    It 'Mock Get-EC2SecurityGroup -GroupId returns group' {

        $sg = Get-EC2SecurityGroup -GroupId sg-00000001
        $sg.GroupId | Should -Be 'sg-00000001'
    }

    It 'Mock Get-EC2SecurityGroup -Filter with single ingress filter returns group' {

        $sg = Get-EC2SecurityGroup -Filter @{
            Name   = 'ip-permission.cidr'
            Values = '1.1.1.1/32'
        }

        $sg.GroupId | Should -Be 'sg-00000001'
    }
}

Describe 'Security Group Updater' {

    Context 'Security Group Updater' {

        BeforeEach {
            $mockSecurityGroups.CreateSecurityGroup('1.1.1.1/32', $null) # sg-00000001
            $mockSecurityGroups.CreateSecurityGroup($null, '2.2.2.2/32') # sg-00000002
            $mockSecurityGroups.CreateSecurityGroup('3.3.3.0/24', $null) # sg-00000003
            $mockSecurityGroups.CreateSecurityGroup($null, '3.3.3.0/24') # sg-00000004
            $mockSecurityGroups.CreateSecurityGroup('5.5.5.5/32', '6.6.6.6/32') # sg-00000005
            $mockSecurityGroups.CreateSecurityGroup('6.6.6.6/32', '7.7.7.7/32') # sg-00000006
        }

        AfterEach {
            $mockSecurityGroups.Clear()
        }

        Mock -CommandName Get-EC2SecurityGroup -MockWith {

            if ($GroupId)
            {
                $mockSecurityGroups.GetById($GroupId)
            }
            elseif ($Filter)
            {
                $mockSecurityGroups.GetByFilter($Filter)
            }
            else {
                throw "Unsupported arguments"
            }
        }

        Mock -CommandName Grant-EC2SecurityGroupIngress -MockWith {

            $mockSecurityGroups.GrantIngressRule($GroupId, $IpPermission)
        }

        Mock -CommandName Revoke-EC2SecurityGroupIngress -MockWith {

            $mockSecurityGroups.RevokeIngressRule($GroupId, $IpPermission)
        }

        Mock -CommandName Grant-EC2SecurityGroupEgress -MockWith {

            $mockSecurityGroups.GrantEgressRule($GroupId, $IpPermission)
        }

        Mock -CommandName Revoke-EC2SecurityGroupEgress -MockWith {

            $mockSecurityGroups.RevokeEgressRule($GroupId, $IpPermission)
        }

        It 'Updates matching /32 ingress rule' {

            New-Object PSObject -Property @{
                PreviousAddress = '1.1.1.1'
                NewAddress      = '2.1.1.1'
            } |
                Publish-IPChanges

            Assert-MockCalled -CommandName Grant-EC2SecurityGroupIngress -Times 1 -Scope It
            Assert-MockCalled -CommandName Revoke-EC2SecurityGroupIngress -Times 1 -Scope It
        }

        It 'Updates matching /32 egress rule' {

            New-Object PSObject -Property @{
                PreviousAddress = '2.2.2.2'
                NewAddress      = '2.1.1.1'
            } |
                Publish-IPChanges

            Assert-MockCalled -CommandName Grant-EC2SecurityGroupEgress -Times 1 -Scope It
            Assert-MockCalled -CommandName Revoke-EC2SecurityGroupEgress -Times 1 -Scope It
        }

        It 'Does not update any rule when rule IP matches but does not target single host' {

            # Matches sg-00000003 and sg-00000004 by IP only
            New-Object PSObject -Property @{
                PreviousAddress = '3.3.3.0'
                NewAddress      = '3.3.3.3'
            } |
                Publish-IPChanges

            Assert-MockCalled -CommandName Grant-EC2SecurityGroupIngress -Times 0 -Scope It
            Assert-MockCalled -CommandName Revoke-EC2SecurityGroupIngress -Times 0 -Scope It
            Assert-MockCalled -CommandName Grant-EC2SecurityGroupEgress -Times 0 -Scope It
            Assert-MockCalled -CommandName Revoke-EC2SecurityGroupEgress -Times 0 -Scope It
        }

        It 'Updates 2 security groups having the same cidr within their rule sets' {

            # Matches sg-00000005 egress and sg-00000006 ingress
            New-Object PSObject -Property @{
                PreviousAddress = '6.6.6.6'
                NewAddress      = '10.0.0.0'
            } |
                Publish-IPChanges

            Assert-MockCalled -CommandName Grant-EC2SecurityGroupIngress -Times 1 -Scope It
            Assert-MockCalled -CommandName Revoke-EC2SecurityGroupIngress -Times 1 -Scope It
            Assert-MockCalled -CommandName Grant-EC2SecurityGroupEgress -Times 1 -Scope It
            Assert-MockCalled -CommandName Revoke-EC2SecurityGroupEgress -Times 1 -Scope It
        }
    }
}