# htconfig-vault
This package configures a Hashicorp Vault server for use with 
[htgettoken](https://github.com/fermitools/htgettoken).

In addition to making it easy to configure the server, it includes
a modified Hashicorp vault plugin
([vault-plugin-auth-jwt](https://github.com/hashicorp/vault-plugin-auth-jwt))
and a vault plugin from Puppet Labs
([vault-plugin-secrets-oauthapp](https://github.com/puppetlabs/vault-plugin-secrets-oauthapp)).

## Installation

The rpm is available in the
[Open Science Grid yum repositories](https://opensciencegrid.org/docs/common/yum/#install-the-osg-repositories).
After enabling the OSG repositories, do this as root to install vault
and htvault-config:
```
yum install htvault-config
systemctl enable vault
systemctl enable htvault-config
```


## Configuration

If you want to enable debugging, uncomment the indicated line in
`/etc/sysconfig/htvault-config`.

Put X.509 host credentials in `/etc/htvault-config/hostcert.pem`
and `/etc/htvault-config/hostkey.pem`.  The former should be
world-readable and the latter should be owned by the
'vault' user id and mode 400.  For a production system make sure that
those credentials get renewed before expiry and vault gets restarted.

Configuration parameters are done in YAML and can be placed in any
`/etc/htvault-config/config.d/*.yaml` file.  The files are processed
in alphabetical order and options are merged from later files into
earlier ones.  If the same parameters are set again in a later file
it overrides the earlier one.  It is recommended to start the file
names with two digit numbers to easily control the order.


### OIDC/Oauth configuration

OIDC/Oauth configuration is done under an "issuers" top-level keyword.
Each list item under that should have the following keywords:

`issuers` keywords
| Keyword | Meaning |
|:---     | :--     |
| name | Issuer name |
| clientid | OIDC Client ID |
| secret  | OIDC Client secret |
| url  | Issuer URL |
| callbackmode | `direct` or `device` (optional, default `device`) |
| credclaim | OIDC id token claim to use for credential key |
| roles | List of roles |

If you want a default issuer for htgettoken give that one the
name `default`. 

It may be more convenient for the sake of system configurators (e.g.
puppet) to put the secrets all into a separate file, but if you do that
remember if an issuer name is changed it has to be changed in both
files. 

If you want also want to support kerberos, the `credclaim` used for all
issuers in a Vault instance sharing that kerberos for credential renewal
must map to the users' kerberos IDs.  For that reason, the source of
information for both the OIDC issuer and for the Kerberos Domain
Controller (KDC) must ultimately be from the same database.  See the
discussion on `policydomain` below in the kerberos section to see
whether or not the domain name should be included in the `credclaim`
value.

Each role under roles should have the following keywords:

`roles` keywords
| Keyword | Meaning |
|:---     | :--     |
| name | Role name |
| scopes | List of scopes to request |

There should be a role called `default` because htgettoken will use that
role if no role is given to it.  The scopes list can be in any format
that is accepted by YAML; the most convenient is probably
comma-separated and surrounded by square brackets.  If there are
characters that are special to YAML such as a colon in a scope value, the
scope should be surrounded by double quotes (although a special case is
that a scope can end with a colon without being quoted).

Below are some example configuration files.

20-cilogon.yaml
```
issuers:
  - name: cilogon
    clientid: xxx
    url: https://cilogon.org
    callbackmode: direct
    credclaim: wlcg.credkey
    roles:
      - name: default
        scopes: [profile,email,org.cilogon.userinfo,storage.read:,storage.create:]
      - name: readonly
        scopes: [profile,email,org.cilogon.userinfo,storage.read:]
```

20-wlcg.yaml
```
issuers:
  - name: default
    clientid: xxx
    url: https://wlcg.cloud.cnaf.infn.it/
    callbackmode: device
    credclaim: email
    roles:
      - name: default
        scopes: [profile,email,offline_access,wlcg,wlcg.groups,"storage.read:/","storage.modify:/","storage.create:/"]
  - name: wlcg
    clientid: xxx
    url: https://wlcg.cloud.cnaf.infn.it/
    callbackmode: direct
    credclaim: email
    roles:
      - name: default
        scopes: [profile,email,offline_access,wlcg,wlcg.groups,"storage.read:/","storage.modify:/","storage.create:/"]

```

80-secrets.yaml
```
issuers:
  - name: cilogon
    secret: xxx
  - name: default
    secret: xxx
  - name: wlcg
    secret: xxx
```

Note that the "device" callback mode is not available by default on the
wlcg token issuer, you have to request it from the administrator.  If using
the "direct" method (which is the standard OIDC code flow), register
callback URIs of the form
```
https://<your.host.name>:8200/v1/auth/oidc-<issuer>/oidc/callback
```
where `<issuer>` is replaced by each issuer name configured and
`<your.host.name>` is replaced by the fully qualified domain name of the
vault service.  The token issuer does not need access to that port but
web browsers of end users do, so the vault service may be behind a
firewall if the clients are also behind that firewall.


### Kerberos configuration

If you want to configure Kerberos support use the `kerberos` top-level
keyword.  The Vault kerberos plugin needs LDAP parameters to be set.
Here are the recognized keywords:

`kerberos` keywords
| Keyword | Meaning |
|:---     | :--     |
| name | kerberos service name |
| ldapurl | URL of LDAP server |
| ldapdn | Base DN to use for LDAP user search |
| ldapattr | LDAP attribute matching user name |
| policydomain | Policy domain (optional, default empty) |

There's unfortunately not a standard way to discover values for the ldap
keywords.  They vary per kerberos installation, but there is often some
document available on the internet that shows the right values.  If not,
contact the local administrators of kerberos and LDAP services.

The Vault kerberos plugin strips away the kerberos domain name when
mapping to vault secret storage paths and leaves only the `userid` from
a `userid@domain`.  For that reason, if you define OIDC issuer
`credclaim`s whose values contain a `@domain` name then set
`policydomain` to `@domain` to make the vault kerberos permission
policies add in that domain name.  In that way both kerberos and OIDC
issuers will map to the same Vault storage paths, which is what is
needed.  If the issuer `credclaim`s do not contain `@domain` then setting
policydomain is not necessary (but causes no harm because the kerberos
permission policies also always accept paths without the `@domain`).

Note that if an OIDC token issuer supports more than one Identity
Provider (IdP), the htvault-config kerberos credential feature can only
be used by the users that select the IdP that is from the same
organization as the kerberos domain.  Also, in this case care must be
taken to not use a credclaim that is always without `@domain` because
then it might be possible for the same user id used by different
people at different IdPs to map to the same Vault secrets path.

More than one kerberos service may be defined.  htgettoken will use the
first defined service by default, and Vault will read its keytab from
`/etc/krb5.keytab`.  Subsequent services expect to find a keytab in
`/etc/krb5-<name>.keytab` where `<name>` is the kerberos service name
defined here.  To access the alternate kerberos service from htgettoken
use its option `--kerbpath=auth/kerberos-<name>/login`.

As examples here is a configuration for Fermilab supporting both fnal
and ligo kerberos services, and another supporting a CERN kerberos
service:

10-kerberos.yaml for Fermilab
```
kerberos:
  - name: fnal
    ldapurl: ldaps://ldap.fnal.gov
    ldapdn: o=fnal
    ldapattr: uid
  - name: ligo
    ldapurl: ldaps://ldap.ligo.org
    ldapdn: ou=people,dc=ligo,dc=org
    ldapattr: uid
```

10-kerberos.yaml for CERN
```
kerberos:
  - name: cern
    ldapurl: ldaps://xldap.cern.ch
    ldapdn: OU=Users,OU=Organic Units,DC=cern,DC=ch
    ldapattr: cn
    policydomain: "@cern.ch"
```

The reason for the policydomain on the second example is to pair with
an OIDC issuer `credclaim` of `eppn` (for eduPersonPrincipalName) which
includes `@cern.ch`.

#### Supporting kerberos robot credentials

Some Kerberos installations support the use of "robot" credentials for
unattended use cases, with kerberos principals of the form
`user/purpose/machine.name`.  htvault-config and htgettoken support
using them, if there is an OIDC `credclaim` that does not include the
`@domain` for those who log in to the OIDC token issuer using an 
Identity Provider (IdP) that matches the kerberos domain.  This is done
by allowing access to vault paths that are of the form `user/*`,
along with htgettoken option `--credkey user/purpose/machine.name`
matching the kerberos principal.  For security reasons, if the OIDC
token issuer accepts multiple IdPs then if one of those other IdPs
are used the `credclaim` should include the IdP's `@domain` to avoid the
possibility of overlapping user ids mapping to the same Vault paths.

### High availability

This package also supports an option of 3 Vault servers providing a
single high-availability service, using Vault's
[raft storage](https://learn.hashicorp.com/tutorials/vault/raft-storage)
feature.  To configure it, first you need to install the certificate of
the CA that certifies the host certificates of your servers into
`/etc/htvault-config/cacert.pem`.  This is needed so the servers can
verify the identity of each other.  Just like the host certificate, make
sure that it gets updated before it expires.

Next, set the following extra parameters under a `cluster` top-level
keyword:

`cluster` keywords
| Keyword | Meaning |
|:---     | :--     |
| name | Cluster name |
| master | Cluster master machine |
| peer1 | First peer machine |
| peer2 | Other peer machine |
| myname | Current machine name (optional, default \`uname -n\`) |

All of the keyword values should be fully qualified domain names.
It is recommended to put all 3 machines behind a load balancer or DNS
round-robin, and set the full value as `name`, although it can be
tested by setting `name` to one of the individual machine names.
In the testing case in order to test one of the peers give its name as
the Vault server address to htgettoken `-a` and give the cluster name as
the `--vaultalias` option.

The `myname` keyword is only needed if \`uname -n\` does not match
the fully qualified domain name of the current machine when accessing
it externally.  That keyword may also be used in non-HA, single machine
configurations for the same purpose.

Here is an example:

10-cluster.yaml
```
cluster:
  name: htvault.fnal.gov
  master: htvault1.fnal.gov
  peer1: htvault2.fnal.gov
  peer2: htvault3.fnal.gov
```

The full configuration should only be set on the `master` machine.  The
other machines only need these cluster settings, no other configuration.
They should each list the same cluster `name` and `master` but set the
other two machines as their peers, for example on htvault2:

10-cluster.yaml
```
cluster:
  name: htvault.fnal.gov
  master: htvault1.fnal.gov
  peer1: htvault1.fnal.gov
  peer2: htvault3.fnal.gov
```


## Network accessibility

The vault service listens on port 8200 so make sure that is open through
iptables.  It needs to be accessible from all users' web browsers, so if
all users are within a LAN it does not need to be accessible through
firewalls to the internet.  On the other hand if it is a public server
accessible from anywhere then it does need to have a firewall opening.


## Starting the service

The htvault-config systemd service ties itself to Vault, so starting or
restarting the vault service will also apply the configuration.
So to start the service simply do as root:
```
systemctl start vault
```

The htvault-config service can also be restarted independently without
restarting vault to reapply the configuration.  The output from
configuration goes into `/var/log/htvault-config/startlog` and logging
for Vault itself goes to `/var/log/messages`.  Previous settings for all
configuration parameters are saved, and only changed parameters are sent
to Vault.


## Testing the service

In order to test the service install
[htgettoken](https://github.com/fermitols/htgettoken)
on any machine that has access to port 8200 on the vault server.
If you have a default service configured you should be able to get a
token by simply running this as an unprivileged user:
```
htgettoken -a <your.host.name>
```
where `<your.host.name>` is replaced by the fully qualified domain
name of your Vault server.  Add `-i <issuer>` to select a specific
issuer and `-i <role>` to select a specific role.
