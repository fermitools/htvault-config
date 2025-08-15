%define tarball_version 2.1
%define openbao_version 2.3.2
%define plugin1_name vault-plugin-auth-ssh
%define plugin1_version 0.3.4
%define plugin2_name openbao-plugin-secrets-oauthapp
%define plugin2_oldname vault-plugin-secrets-oauthapp
%define plugin2_version 3.2.0
%define gox_version 1.0.1

# This is to avoid
#   *** ERROR: No build ID note found
%define debug_package %{nil}

# This is so brp-python-bytecompile uses python3
%define __python python3

Summary: Configuration for OpenBao for use with htgettoken client
Name: htvault-config
Version: 2.1.0
Release: 2%{?dist}
Group: Applications/System
License: BSD
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
# download with:
# $ curl -o htvault-config-%%{version}.tar.gz \
#    https://codeload.github.com/fermitools/htvault-config/tar.gz/v%%{version}
Source0: %{name}-%{version}.tar.gz
# create with ./make-source-tarball
Source1: %{name}-src-%{tarball_version}.tar.gz

Requires: openbao-vault-compat >= %{openbao_version}
Requires: jq
Requires: diffutils
Requires: python3-PyYAML

BuildRequires: golang

%prep
%setup -q
%setup -q -T -b 1 -n %{name}-src-%{tarball_version}

%description
Installs plugins and configuration for OpenBao for use with
htgettoken as a client.

%build
# starts out in %{name}-src-%{tarball_version}
cd go/src
./make.bash
cd ../..
export GOPATH=$PWD/gopath
export PATH=$PWD/go/bin:$GOPATH/bin:$PATH
mkdir -p $GOPATH/bin
export GOPROXY=file://$(go env GOMODCACHE)/cache/download
go version
go install github.com/mitchellh/gox@v%{gox_version}

PLUGIN1_VERSION=%{plugin1_version}
PLUGIN2_VERSION=%{plugin2_version}
PLUGIN1_VERSION=${PLUGIN1_VERSION#commit/}
PLUGIN2_VERSION=${PLUGIN2_VERSION#commit/}

cd %{plugin1_name}-${PLUGIN1_VERSION}
make build

cd ../%{plugin2_name}-${PLUGIN2_VERSION}
make
cd ..

%install
# starts out in %{name}-src-%{tarball_version}
LIBEXECDIR=$RPM_BUILD_ROOT/%{_libexecdir}/%{name}
PLUGINDIR=$LIBEXECDIR/plugins
mkdir -p $PLUGINDIR
PLUGIN1_VERSION=%{plugin1_version}
PLUGIN2_VERSION=%{plugin2_version}
PLUGIN1_VERSION=${PLUGIN1_VERSION#commit/}
PLUGIN2_VERSION=${PLUGIN2_VERSION#commit/}
cp %{plugin1_name}-${PLUGIN1_VERSION}/vault/plugins/%{plugin1_name} $PLUGINDIR
cp %{plugin2_name}-${PLUGIN2_VERSION}/bin/%{plugin2_name} $PLUGINDIR/%{plugin2_oldname}
cd ../%{name}-%{version}
mkdir -p $RPM_BUILD_ROOT/%{_sysconfdir}/%{name}/config.d
mkdir -p $RPM_BUILD_ROOT/%{_sysconfdir}/logrotate.d
cp misc/logrotate $RPM_BUILD_ROOT/%{_sysconfdir}/logrotate.d/%{name}
SYSCONFIGDIR=$RPM_BUILD_ROOT/%{_sysconfdir}/sysconfig
mkdir -p $SYSCONFIGDIR
SYSTEMDDIR=$RPM_BUILD_ROOT/lib/systemd/system
mkdir -p $SYSTEMDDIR/openbao.service.d $SYSTEMDDIR/openbao.service.wants
cp misc/systemd.conf $SYSTEMDDIR/openbao.service.d/%{name}.conf
cp misc/config.service $SYSTEMDDIR/%{name}.service
cp misc/sysconfig $SYSCONFIGDIR/%{name}
cp libexec/*.sh libexec/*.template libexec/*.py $LIBEXECDIR
mv $LIBEXECDIR/plugin-wrapper.sh $LIBEXECDIR/plugins
ln -s plugin-wrapper.sh $LIBEXECDIR/plugins/%{plugin1_name}.sh
ln -s plugin-wrapper.sh $LIBEXECDIR/plugins/%{plugin2_oldname}.sh
mkdir -p $RPM_BUILD_ROOT%{_sharedstatedir}/%{name}
mkdir -p $RPM_BUILD_ROOT%{_localstatedir}/log/%{name}

%post
find %{_sysconfdir}/%{name} %{_sharedstatedir}/%{name} %{_localstatedir}/log/%{name} -user vault | xargs -r chown openbao:openbao
systemctl daemon-reload
%systemd_post %{name}.service

%preun
%systemd_preun %{name}.service

%postun
# restart openbao on upgrade
%systemd_postun_with_restart openbao.service

%files
%dir %attr(750, openbao, openbao) %{_sysconfdir}/%{name}
%dir %attr(750, root, root) %{_sysconfdir}/%{name}/config.d
%{_sysconfdir}/logrotate.d/%{name}
%config(noreplace) %{_sysconfdir}/sysconfig/%{name}
/lib/systemd/system/%{name}.service
/lib/systemd/system/openbao.service.d/%{name}.conf
%{_libexecdir}/%{name}
%attr(750, openbao, openbao) %{_sharedstatedir}/%{name}
%attr(750, openbao,root) %dir %{_localstatedir}/log/%{name}

%changelog
* Thu Aug 14 2025 Dave Dykstra <dwd@fnal.gov> 2.1.0-2
- Also chown files that need it in /var/log/htvault-config, in particular
  the auditlog.

* Fri Aug  8 2025 Dave Dykstra <dwd@fnal.gov> 2.1.0-1
- Update to require openbao 2.3.2, which has been updated in preparation
  for moving it to EPEL by changing the service to run under the openbao
  user and group id instead of vault.

* Thu Mar 20 2025 Dave Dykstra <dwd@fnal.gov> 2.0.0-1
- Remove the external auth/oidc plugin registration to switch to the
  builtin plugin.
- Change to semantic versioning starting at 2.0.0.  Compared to 1.18,
  the removal of the external vault-plugin-secrets-jwt plugin causes
  some incompatibility and requires a careful upgrade path in HA
  installations (that is, upgrade all vault/openbao first).

* Fri Mar 14 2025 Dave Dykstra <dwd@fnal.gov> 1.19-1
- Replace vault with openbao-2.2.0 and remove vault-plugin-secrets-jwt
  (since the builtin version works with openbao).
- Replace vault-plugin-secrets-oauthapp with openbao-plugin-secrets-oauthapp
  3.2.0 but still install it as vault-plugins-secrets-oauthapp for upgrade
  compatibility.
- Update vault-plugin-auth-ssh to 0.3.4.

* Fri Aug 16 2024 Dave Dykstra <dwd@fnal.gov> 1.18-1
- Restore patch #41 on vault-plugin-secrets-oauthapp which was accidentally
  dropped.
- Update to latest commit on vault-plugin-auth-jwt because one of the
  other patches now depends on it in order to apply cleanly.

* Mon Jul 22 2024 Dave Dykstra <dwd@fnal.gov> 1.17-1
- Add a patch of PR #90 to vault-plugin-secrets-oauthapp which adds caching
  of tokens exchanged via the /sts path and adds a minimum_seconds option to
  the API.
- Give vault tokens the capabilities of deleting secrets and revoking
  themselves.
- Update required vault to 1.17.
- Update vault-plugin-auth-jwt to 0.21.0.
- Update vault-plugin-auth-ssh to 0.3.2 which includes the patch for '@' 
  that was previously applied.

* Fri Jan  5 2024 Dave Dykstra <dwd@fnal.gov> 1.16-1
- Add 'ratelimits' keyword to put a limit on the number of requests per
  client per interval.
- Allow '@' to be included in the ssh plugin's keys.
- Fix bug that prevented reconfiguration when a policy name changed.
- Update vault-plugin-auth-jwt to 0.18.0.
- Update vault-plugin-auth-ssh to 0.3.1.
- Require vault to be >= 1.15.

* Tue May  2 2023 Dave Dykstra <dwd@fnal.gov> 1.15-1
- Update vault-plugin-secrets-oauthapp to 3.1.1 which adds support for token
  exchange at a /sts path instead of /creds.  Keep applying the PR patch
  that also adds it under /creds for a transition period until htgettoken
  is updated everywhere to use the new path.
- Update vault-plugin-auth-jwt to 0.15.2.
- Update vault-plugin-auth-ssh to 0.3.0.
- Require vault >= 1.13.
- Require diffutils.
- Fix bug where the kerberos policydomain option was ignored.

* Tue Jan 17 2023 Dave Dykstra <dwd@fnal.gov> 1.14-1
- Add auditlog configuration option.  As part of that, disable the
  vault systemd ProtectFull and ProtectHome options.
- Require vault >= 1.12.1.
- Update the vault-plugin-auth-jwt to the latest upstream commit.
- Include gox in the source tarball.

* Mon May 23 2022 Dave Dykstra <dwd@fnal.gov> 1.13-1
- Remove support for old-style per issuer/role secret plugins.  Requires
  htgettoken >= 1.7.
- Add ability to delete a previously defined configuration by using
  a keyword "delete:" under the configuration name and setting it to
  any value.
- Update vault-plugin-auth-jwt to the latest commit (because the patches
  had been rebased on it).

* Wed Mar 23 2022 Dave Dykstra <dwd@fnal.gov> 1.12-1
- Require vault-1.10.0 and update vault-plugin-auth-jwt to version 0.12.1
  and vault-plugin-auth-ssh to version 0.1.1.

* Wed Dec  1 2021 Dave Dykstra <dwd@fnal.gov> 1.11-1
- Add support for ssh-agent authentication, including self-registering of
  ssh public keys.

* Mon Nov 15 2021 Dave Dykstra <dwd@fnal.gov> 1.10-1
- Fix problem that /etc/krb5-<name>.keytab was preferred for first service
  only when the kerbservice was explicitly defined for an issuer.  Now it
  also works for default first kerberos service.

* Wed Nov 10 2021 Dave Dykstra <dwd@fnal.gov> 1.9-1
- Restore separate names for names of issuer and policy when generating
  policies

* Wed Nov 10 2021 Dave Dykstra <dwd@fnal.gov> 1.8-1
- Restore part of the setup of kerberos; too much was taken out in 1.7
- When an issuer is deleted, clean out the policies and kerberos modules
  related to its roles
- Make policy names more consistent with module names

* Thu Nov  4 2021 Dave Dykstra <dwd@fnal.gov> 1.7-1
- Require at least vault version 1.8.4
- Remove support for coarse-grained kerberos; requires htgettoken >= 1.3
- Use /etc/krb5-<name>.keytab if it exists even for the first defined
  kerberos service, in preference to /etc/krb5.keytab.
- Update to vault-plugin-secrets-oauthapp 3.0.0
- Update to vault-plugin-auth-jwt 0.11.1

* Wed Sep 15 2021 Dave Dykstra <dwd@fnal.gov> 1.6-1
- Update to vault-plugin-secrets-oauthapp 3.0.0-beta.4 which includes a
  replacement for PR #64.

* Mon Sep 13 2021 Dave Dykstra <dwd@fnal.gov> 1.5-1
- Require at least vault version 1.8.2
- Update to vault-plugin-auth-jwt to the master branch at the time of the
  0.10.1 tag of the release-1.8 branch
- Update to vault-plugin-secrets-oauthapp 3.0.0-beta.3 and use its new
  feature of combining all providers in a single plugin process
- Include vault-plugin-secrets-oauthapp PR #64 which enables a default
  "legacy" server so older versions of htgettoken can still work.
- Reconfigure kerberos if the service name changes.
- Add a "kerbservice" issuers keyword to select non-default kerberos service
  for a particular issuer
- Immediately fail with a clear message if there's a duplicate name in a
  configuration list
- Allow vault tokens to read auth/token/lookup-self so clients can look up
  the remaining time to live on the tokens

* Tue Jul 20 2021 Dave Dykstra <dwd@fnal.gov> 1.4-1
- Updated the token exchange PR for vault-plugin-secrets-oauthapp to
    send the client secret in the initial authorization request in the
    device flow
- Updated to vault-plugin-secrets-oauthapp-2.2.0

* Mon Jul 12 2021 Dave Dykstra <dwd@fnal.gov> 1.3-1
- Added license in COPYING file
- Updated to vault-plugin-secrets-oauthapp-2.1.0
- Updated the token exchange PR for vault-plugin-secrets-oauthapp to
    accept comma-separated lists of audiences
- Added audit log at /var/log/htvault-config/auditlog
- Enabled delayed log compression and daily logs instead of weekly
- Add support for moving the master in a high-availability cluster from
  one machine to another and for changing the name of either peer
- If 'name' is missing from a yaml list, give a helpful error message 
  instead of causing a python crash
- Limit vault token policies for oidc and kerberos to a single role
  and issuer.  To use these limited policies for kerberos requires
  htgettoken >= 1.3 so for now the coarse-grained kerberos is still
  supported as well but it will be removed later.
- Remove the default policy from vault tokens.

* Thu Jun 17 2021 Dave Dykstra <dwd@fnal.gov> 1.2-1
- Update to vault-plugin-auth-jwt-0.9.4 and require vault-1.7.3

* Mon May 10 2021 Dave Dykstra <dwd@fnal.gov> 1.1-1
- Correctly disable secret oauth module instead of incorrect auth module
  when something changes requiring clearing out of old secrets.
- Allow dashes in names by converting them in bash variables to
  underscores, and reject any other non-alphanumeric or underscore in
  names.
- Fix bug in RFC8693 token exchange pull request to puppetlabs plugin
  which caused comma-separated scopes to get sent to the token issuer
  instead of space-separated scopes.

* Wed May 5 2021 Dave Dykstra <dwd@fnal.gov> 1.0-2
- Add Requires: python3-PyYAML

* Tue May 4 2021 Dave Dykstra <dwd@fnal.gov> 1.0-1
- Convert to using yaml files instead of shell variables to configure.
- Only update the vault configuration for things that have changed in
  the configuration, and include removing things that have been removed.
- Keep secrets off command line to hide them from 'ps'.
- Require at least vault-1.7.1

* Thu Apr 15 2021 Dave Dykstra <dwd@fnal.gov> 0.7-1
- Update to vault-plugin-secrets-oauthapp version 2.0.0
- Update to final version of PR for periodic refresh of credentials
- Move the 'PartOf' rule in htvault-config.service to the correct section.
- Prevent vault DB initialization failure from blocking future attempts.
- Change to have vault listen on all interfaces with tls for port 8200,
  and to use port 8202 for non-tls localhost access.

* Thu Apr  8 2021 Dave Dykstra <dwd@fnal.gov> 0.6-1
- Update vault-plugin-secrets-oauthapp to version 1.10.1, including
    applying a bug fix for broken minimum_seconds option
- Disable periodic refresh of credentials; make it be only on demand
- Require at least vault-1.7.0

* Mon Mar 22 2021 Dave Dykstra <dwd@fnal.gov> 0.5-2
- Update vault-plugin-auth-jwt to version 0.9.2

* Fri Feb 19 2021 Dave Dykstra <dwd@fnal.gov> 0.5-1
- Always reconfigure everything when systemd service is started, just don't
  disable/reenable oauthapp because that wipes out stored secrets.
- Support multiple roles per issuer.

* Thu Feb 18 2021 Dave Dykstra <dwd@fnal.gov> 0.4-1
- Rename the few OIDC-related variables that didn't begin with OIDC to
  begin with OIDC.

* Wed Feb 17 2021 Dave Dykstra <dwd@fnal.gov> 0.3-1
- Rename make-downloads to make-source-tarball and make it have more
  in common with the vault-rpm build

* Mon Feb 01 2021 Dave Dykstra <dwd@fnal.gov> 0.2-1
- Pre-download and prepare all the go modules using new make-downloads
  script, so no network is needed during rpm build.

* Fri Jan 29 2021 Dave Dykstra <dwd@fnal.gov> 0.1-1
- Initial pre-release, including parameterization based on shell variables
