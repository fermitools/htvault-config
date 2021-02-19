# htconfig-vault
Configure a Hashicorp Vault server for use with htgettoken.

## Installation

The rpm is available in
[OSG yum repositories](https://opensciencegrid.org/docs/common/yum/#install-the-osg-repositories), currently in osg-development.

To install vault and htvault-config as root:
```
yum install --enablerepo=osg-development htvault-config
systemctl enable vault
systemctl enable htvault-config
```

Note that the htvault-config systemd service ties itself to vault so
restarting the vault service will also do the config.  The
htvault-config service can also be restarted independently without
restarting vault, but by default any subcomponent that is already
configured will not be reconfigured.  The output from configuration goes
into `/var/log/htvault-config/startlog` and logging for vault itself
goes to `/var/log/messages`.  You can force reconfiguring of
subcomponents by running `/usr/libexec/htvault-config/config.sh` as
root.  Pass the `-h` option to it to see usage including a list of
the subcomponents. Be aware that reconfiguring a component wipes out
any stored data, so avoid reconfiguring the oauth subcomponents if you
can because that's where refresh tokens are stored.

## Configuration

If you want to enable debugging, uncomment the indicated line in
`/etc/sysconfig/htvault-config`.

Put x.509 host credentials in `/etc/htvault-config/hostcert.pem`
and `/etc/htvault-config/hostkey.pem`.  The former should be
world-readable and the latter should only be owned by the
'vault' user id and mode 400.  For a production system make sure that
those credentials get renewed before expiry and vault gets restarted.

Put most of the configuration for now in a new file you create
called `/etc/htvault-config/config.d/parameters.sh`.

First, set a required parameter:
```
MYFQDN=`uname-n`
```

### OIDC/Oauth configuration

There isn't currently a mechanism for configuring multiple roles per
issuer.

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

Note that the "device" callback mode is not available by default
on the wlcg token issuer, you have to request it from the
administrator.

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
KERBPOLICYDOMAIN=@fnal.gov
```

CERN:
```
LDAPURL="ldaps://xldap.cern.ch"
LDAPDN="OU=Users,OU=Organic Units,DC=cern,DC=ch"
LDAPATTR="cn"
```

LIGO:
```
LDAPURL="ldaps://ldap.ligo.org"
LDAPDN="ou=people,dc=ligo,dc=org"
LDAPATTR="uid"
```

## High availability

The configuration also supports an option of 3 vault servers providing
a single high-availablity service, using vault's
[raft storage](https://learn.hashicorp.com/tutorials/vault/raft-storage)
feature.
