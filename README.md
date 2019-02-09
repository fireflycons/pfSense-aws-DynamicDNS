# Overview

Whilst this is a guide to configuring dynamic DNS on pfSense because that's what I use, the CloudFormation template creates an IAM user with the correct permissions to generically perform a DNS update so can be used for any DDNS provision that supports AWS. Even roll your own with aws cli or one of the SDKs.

# What is Dynamic DNS

DynDNS is a service that translates your external IP Address into an URL like yourcompany.dyndns.org

If you have a static IP from your provider, you will not need DynDNS necessarily, since you can just update the record directly in the knowledge that the underlying IP will not change.

Most of you, at least for private usage, will have an external IP Address that changes every so often at your service provider's whim, so it would be impossible to reach your internal network after a change to your IP Address.

This is where DynDNS comes into play.

Each time your IP address gets changed by your service provider, pfSense will tell your DynDNS provider your new IP Address automatically, in this case Route 53.

# Setup

## Prerequisites

* You must have the domain you want to update registered with Route 53. Either register a new one, or transfer one in from another DNS provider.

## Find the Hosted Zone ID

Here you get the Zone ID of the domain that will be updated by DynDNS.

For the purpuse of this guide, we will assume that the DNS domain is `mycompany.org`

1. Log into AWS console.
2. Go to the Route 53 console, display your hosted zones and note the Hosted Zone ID of the domain you wish to update.

## Create an IAM User

Here you create an IAM user in your AWS account with permission to update DNS records

1. Log into AWS console.
2. Go to CloudFormation console and create a new CloudFormation Stack using the template provided. It will prompt you for the name to give the new user, and for the Hosted Zone ID of the zone (which you found above) it will have permission to manage.
3. Go to the IAM console and find the user that has been created by CloudFormation.
4. Select the Security Credentials tab, and press Create Access Key.
5. Note down the Access Key ID and Secret Access Key, you will need them later.

## Configure pfSense to update Route 53

Now you set up pfSense to do the heavy lifting.

1. Log into the pfSense user interface.
2. From the `Services` menu, select `Dynamic DNS`.
3. Press the Add button to create a new Dynamic DNS service.
4. Fill out the form as follows. Only the fields listed here require values.
4.1 `Service Type` - `Route 53`
4.2 `Interface to monitor` - Select `WAN`, or whichever interface is connected to your service provider's modem/router.
4.3 `Hostname` - Enter the fully qualified name of the record you which to be updated, e.g. `www.mycompany.org`
4.4 `Username` - Enter the Access Key ID you created above.
4.5 `Password` - Enter the Secret Access Key from above.
4.6 `Zone ID` - There have been different reports as to what works here. One of the following should work. Either just the Hosted Zone ID, or the Hosted Zone ID prefixed with `us-east-1/`. Note that it must be `us-east-1` and not any other region. The latter is working for me.
4.7 `TTL` - Choose a TTL value, e.g. 300 (5 min)
4.8 `Description` - Anything you want, or leave blank.
5. Save the configuration and the DNS update should soon happen. Your external IP should then show up green in the Cached IP column.

## Troubleshooting

If there is an issue with the DNS update, the Cached IP column will show the IP address in red, or will show `N/A`

1. Check for typos in the `Username`, `Password` and `Zone ID` fields.
2. Examine the pfSense system log for clues. In pfSense, select `System Logs` from the `Status` menu.
3. Look for messages beginning `/services_dyndns_edit.php: error message:`

### Error Log example 1

```xml
<?xml version="1.0"?>
<ErrorResponse xmlns="https://route53.amazonaws.com/doc/2013-04-01/">
<Error>
<Type>Sender</Type>
<Code>SignatureDoesNotMatch</Code>
<Message>Credential should be scoped to a valid region, not 'eu-west-1'. </Message>
</Error>
<RequestId>112208b4-2bec-11e9-b72a-d74051dabb6f</RequestId>
</ErrorResponse>
```
This indicates an issue with the Zone ID field in the configuration. Review step 4.6 above. If you have included a region with the zone ID, it must be `us-east-1`, irresepctive of what your preferred region is for deploying resources.

### Error log example 2

Account and Zone IDs redacted.

```xml
<ErrorResponse xmlns="https://route53.amazonaws.com/doc/2013-04-01/">
<Error>
<Type>Sender</Type>
<Code>AccessDenied</Code>
<Message>User: arn:aws:iam::000000000000:user/test-ddns is not authorized to perform: route53:ChangeResourceRecordSets on resource: arn:aws:route53:::hostedzone/Zxxxxxxxxxxxx</Message>
</Error>
<RequestId>e8048f80-2c41-11e9-8a34-7b4695c088ab</RequestId>
</ErrorResponse>
```

The zone ID you gave to CloudFormation when you created the user is not the same as the zone ID you gave to pfSense. The IAM user only has permission to update the specific zone given when you created the user.
