# Dynamic IP Watcher

Building upon what we've already done to set up Route 53 as a dynamic DNS provider, here is an example of what can be done with lambdas to cause things to happen within your AWS account when a DynDNS update occurs.

The code is written in PowerShell, primarily because I like PowerShell :-) and also to try out the fairly new (at the time of writing) support for PowerShell lambdas.

This project comprises the following

* A CloudFormation template to build the basic infrastructure
* A lambda that polls a host or hosts in Route 53 for a change of IP address - these being the hosts you have configured for DynDNS. State is saved in SSM Parameter store.
* Another lambda that is notified via an SNS topic whenever an IP change is detected. This lambda searches all security groups for rules targeting the watched host's IP directly (i.e. a `/32` CIDR). These would be the security groups you've configured to only permit access from e.g. your own broadband account's public IP. All security groups that are found have matching rules updated to the new IP address.
* A build script that deploys and updates the infrastructure and lambdas.

You could write additional handlers that subscribe to the SNS topic created by the CloudFormation to perform additional tasks when a chage of IP is detected.

## Build, Test, Deploy!

### Requirements

PowerShell lambdas are hosted by Linux instances in the background, therefore you must build them using PowerShell Core - the version of PowerShell that runs on top of .NET Core.

To install PowerShell Core on various platforms including configuring Visual Studio Code to use it, please [see here](https://docs.microsoft.com/en-us/powershell/scripting/components/vscode/using-vscode?view=powershell-6).

Once you have PowerShell Core up and running, you need to install `AWSPowerShell.netcore` for AWS support. All other modules required to build this project, including [AWSLambdaPSCore](https://github.com/aws/aws-lambda-dotnet/tree/master/PowerShell) are installed by `build.ps1`.

```powershell
Install-Module AWSPowerShell.NetCore -Scope CurrentUser -Force
```

### Building

This assumes you have already set up at least one DNS record you wish to track in Route 53.

To build and deploy, perform the following steps

1. Examine `deploy.json`. The very first property is the name of the CloudFormation stack that will be created from the included template. You may want to change that.
1. Still in `deploy.json` examine the environment settings for `DynamicIpWatcherLambda`. Here you will want to set the fully qualified domain name of the DNS record(s) you are tracking in the variable `HOST_NAMES`. This is a comma separated list of FQDNs.
1. Finally in `deploy.json` you may want to set the value of `SSM_KEY_PATH`. This is the root key in SSM Parameter Store under which the current IP address of tracked records is stored between invocations of the lambda.
1. Import the `AWSPowerShell.netcore` module and use `Set-AWSCredential` to authenticate with credentials for the AWS account to which you will deploy this project.
1. Run `build.ps1` which will run the pester tests, package the lambda functions if they have changed, deploy or update the CloudFormation stack, and finally deploy the lambda payloads on first build, or if they have changed.

Once that's finished you will have a fully functional system that will respond to changes in IP address of the tracked records within 5 minutes, and will update all security groups in the region to which the CloudFormation was deployed with any change to the watched hosts.

### Caveats

Currently the build system doesn't respond to changes in environment variables in `deploy.json` once the stack has been deployed. To force a redeploy of the lambda and its environment, simply delete the lambda payload zip file in the `BuildOutput` directory of this project and re-run `build.ps1`.
