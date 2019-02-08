# Overview

Whilst this is a guide to configuring dynamic DNS on pfSense, because that's what I use, the CloudFormation template creates an IAM user with the correct permissions to genwrically perform a DNS update so can be used for any DDNS provision that supports AWS. Even roll your own with aws cli or one of the SDKs.

# WHat is Dynamic DNS

DynDNS is a service that translates your external IP Address into an URL like yourcompany.dyndns.org

If you have a static IP from your provider, you will not need DynDNS necessarily, since you can just update the record directly in the knowledge that the underlying IP will not change.

Most of you, at least for private usage, will have an external IP Address that changes every so often at your service provider's whim, so it would be impossible to reach your internal network after the change of your IP Address.

This is where DynDNS comes into play.

Each time your IP address gets changed by your service privder, pfSense will tell your DynDNS provider your new IP Address automatically.
