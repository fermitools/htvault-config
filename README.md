# htconfig-vault
This package configures a Hashicorp Vault server for use with 
[htgettoken](https://github.com/fermitools/htgettoken).

## Installation

The rpm is available in the
[Open Science Grid yum repositories](https://opensciencegrid.org/docs/common/yum/#install-the-osg-repositories), currently in osg-testing.

After enabling the OSG repositories, do this as root to install vault
and htvault-config:
```
yum install --enablerepo=osg-testing htvault-config
systemctl enable vault
systemctl enable htvault-config
```

Note that the htvault-config systemd service ties itself to vault so
restarting the vault service will also do the config.  The
htvault-config service can also be restarted independently without
restarting vault, but by default any subcomponent that is already
configured will not be reconfigured.  The output from configuration goes
into `/var/log/htvault-config/startlog` and logging for vault itself
goes to `/var/log/messages`. 

## Configuration

If you want to enable debugging, uncomment the indicated line in
`/etc/sysconfig/htvault-config`.

Put X.509 host credentials in `/etc/htvault-config/hostcert.pem`
and `/etc/htvault-config/hostkey.pem`.  The former should be
world-readable and the latter should only be owned by the
'vault' user id and mode 400.  For a production system make sure that
those credentials get renewed before expiry and vault gets restarted.

Put most of the configuration for now in a new file you create
called `/etc/htvault-config/config.d/parameters.sh`.

First, set this required parameter:
```
MYFQDN="`uname-n`"
```

### OIDC/Oauth configuration

List the names of issuers you want to configure in a space-separated
ISSUERS variable, and set parameters for each issuer in variables that
begin with the issuer name followed by an underscore followed by
parameters (see example below for the specific parameters).  For each
issuer register a client to get a client ID and secret.

For example, to configure a wlcg issuer under its own name and the
default name, and a cilogon issuer:
```
ISSUERS="default wlcg cilogon"

default_OIDC_CLIENT_ID="xxx" 
default_OIDC_CLIENT_SECRET="xxx"
default_OIDC_SERVER_URL="https://wlcg.cloud.cnaf.infn.it/"
default_OIDC_SCOPES="profile,email,offline_access,wlcg,wlcg.groups,storage.read:
/,storage.modify:/,storage.create:/"
default_OIDC_CALLBACKMODE="device"
default_OIDC_USERCLAIM="email"

wlcg_OIDC_CLIENT_ID="$default_OIDC_CLIENT_ID" 
wlcg_OIDC_CLIENT_SECRET="$default_OIDC_CLIENT_SECRET"
wlcg_OIDC_SERVER_URL="$default_OIDC_SERVER_URL"
wlcg_OIDC_SCOPES="$default_OIDC_SCOPES"
wlcg_OIDC_CALLBACKMODE="direct"
wlcg_OIDC_USERCLAIM="$default_OIDC_USERCLAIM"

cilogon_OIDC_CLIENT_ID="xxx"
cilogon_OIDC_CLIENT_SECRET="xxx"
cilogon_OIDC_SERVER_URL="https://test.cilogon.org"
cilogon_OIDC_SCOPES="profile,email,org.cilogon.userinfo,storage.read:,storage.create:"
cilogon_OIDC_CALLBACKMODE="direct"
cilogon_OIDC_USERCLAIM="wlcg.credkey"
```

Note that the "device" callback mode is not available by default on the
wlcg token issuer, you have to request it from the administrator.

The above examples create one role for each issuer called "default".
If you want to specify multiple roles with a different list of
requested scopes for each, you can do that by declaring the
OIDC_SCOPES variable as an array and setting the scopes for each
role, for example:
```
declare -A cilogon_OIDC_SCOPES
cilogon_OIDC_SCOPES[default]="profile,email,org.cilogon.userinfo,storage.read:,storage.create:"
cilogon_OIDC_SCOPES[readonly]="profile,email,org.cilogon.userinfo,storage.read:"
```

### Kerberos configuration

If you want to configure Kerberos support, LDAP parameters need to be
set.  In addition, if you selected an OIDC id token scope as the
OIDC_USERCLAIM that does not contain an @domain name (which is useful
when wanting to support robot kerberos credentials) then set
KERBPOLICYDOMAIN to the @domain.  As examples here are settings for a
few Kerberos domains.

Fermilab:
```
LDAPURL="ldaps://ldap.fnal.gov"
LDAPDN="o=fnal"
LDAPATTR="uid"
KERBPOLICYDOMAIN="@fnal.gov"
```

CERN:
```
LDAPURL="ldaps://xldap.cern.ch"
LDAPDN="OU=Users,OU=Organic Units,DC=cern,DC=ch"
LDAPATTR="cn"
```

## High availability

This package also supports an option of 3 vault servers providing a
single high-availablity service, using vault's
[raft storage](https://learn.hashicorp.com/tutorials/vault/raft-storage)
feature.  To configure it, first you need to install the certificate of
the CA that certifies the host certificates of your servers into
`/etc/htvault-config/cacert.pem`.  This is needed so the servers can
verify the identity of each other.  Just like the host certificate, make
sure that it gets updated before it expires.

Next, set the following extra parameters in parameters.sh, for example:
```
CLUSTERFQDN="htvault.fnal.gov"
CLUSTERMASTER="htvault1.fnal.gov"
PEER1FQDN="htvault2.fnal.gov"
PEER2FQDN="htvault3.fnal.gov"
```

It is recommended to put all 3 servers behind a load balancer or DNS
round-robin, and set that value as CLUSTERFQDN, although it can be
tested by setting CLUSTERFQDN to one of the individual server names.
In the testing case in order to use one of the peers give its name as
the vault server address to htgettoken -a and give the cluster name as
the --vaultalias option.

The full configuration should only be set on the CLUSTERMASTER server.
The other servers only need these 4 settings.  They should each list the
same CLUSTERFQDN and CLUSTERMASTER but set the other two servers as
their peers, for example on htvault2:
```
CLUSTERFQDN="htvault.fnal.gov"
CLUSTERMASTER="htvault1.fnal.gov"
PEER1FQDN="htvault1.fnal.gov"
PEER2FQDN="htvault3.fnal.gov"
```
