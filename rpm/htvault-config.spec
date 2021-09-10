%define tarball_version 1.8
%define plugin1_name vault-plugin-auth-jwt
# this commit is equivalent to version 0.10.1 but on the master branch
%define plugin1_version commit/7311fc7f94c5e2d3b32ebc2824b61a782e03edf3
%define plugin2_name vault-plugin-secrets-oauthapp
%define plugin2_version 3.0.0-beta.3

# This is to avoid
#   *** ERROR: No build ID note found
%define debug_package %{nil}

# This is so brp-python-bytecompile uses python3
%define __python python3

Summary: Configuration for Hashicorp Vault for use with htgettoken client
Name: htvault-config
Version: 1.5
Release: 1%{?dist}
Group: Applications/System
License: BSD
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
# download with:
# $ curl -o htvault-config-%{version}.tar.gz \
#    https://codeload.github.com/fermitools/htvault-config/tar.gz/v%{version}
Source0: %{name}-%{version}.tar.gz
# create with ./make-source-tarball
Source1: %{name}-src-%{tarball_version}.tar.gz

Requires: vault >= 1.8.2
Requires: jq
Requires: python3-PyYAML

BuildRequires: golang

%prep
%setup -q
%setup -q -T -b 1 -n %{name}-src-%{tarball_version}

%description
Installs plugins and configuration for Hashicorp Vault for use with
htgettoken as a client.

%build
# starts out in %{name}-src-%{tarball_version}
export GOPATH=$PWD/gopath
export PATH=$GOPATH/bin:$PATH
export GOPROXY=file://$(go env GOMODCACHE)/cache/download
PLUGIN1_VERSION=%{plugin1_version}
PLUGIN2_VERSION=%{plugin2_version}
PLUGIN1_VERSION=${PLUGIN1_VERSION#commit/}
PLUGIN2_VERSION=${PLUGIN2_VERSION#commit/}
cd %{plugin1_name}-${PLUGIN1_VERSION}
# skip the git in the build script
ln -s /bin/true git
PATH=:$PATH make dev
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
cp %{plugin1_name}-${PLUGIN1_VERSION}/bin/%{plugin1_name} $PLUGINDIR
cp %{plugin2_name}-${PLUGIN2_VERSION}/bin/%{plugin2_name} $PLUGINDIR
cd ../%{name}-%{version}
mkdir -p $RPM_BUILD_ROOT/%{_sysconfdir}/%{name}/config.d
mkdir -p $RPM_BUILD_ROOT/%{_sysconfdir}/logrotate.d
cp misc/logrotate $RPM_BUILD_ROOT/%{_sysconfdir}/logrotate.d/%{name}
SYSCONFIGDIR=$RPM_BUILD_ROOT/%{_sysconfdir}/sysconfig
mkdir -p $SYSCONFIGDIR
SYSTEMDDIR=$RPM_BUILD_ROOT/lib/systemd/system
mkdir -p $SYSTEMDDIR/vault.service.d $SYSTEMDDIR/vault.service.wants
cp misc/systemd.conf $SYSTEMDDIR/vault.service.d/%{name}.conf
cp misc/config.service $SYSTEMDDIR/%{name}.service
cp misc/sysconfig $SYSCONFIGDIR/%{name}
cp libexec/*.sh libexec/*.template libexec/*.py $LIBEXECDIR
mv $LIBEXECDIR/plugin-wrapper.sh $LIBEXECDIR/plugins
ln -s plugin-wrapper.sh $LIBEXECDIR/plugins/%{plugin1_name}.sh
ln -s plugin-wrapper.sh $LIBEXECDIR/plugins/%{plugin2_name}.sh
mkdir -p $RPM_BUILD_ROOT%{_sharedstatedir}/%{name}
mkdir -p $RPM_BUILD_ROOT%{_localstatedir}/log/%{name}

%post
systemctl daemon-reload

%files
%dir %attr(750, vault, vault) %{_sysconfdir}/%{name}
%dir %attr(750, root, root) %{_sysconfdir}/%{name}/config.d
%{_sysconfdir}/logrotate.d/%{name}
%config(noreplace) %{_sysconfdir}/sysconfig/%{name}
/lib/systemd/system/%{name}.service
/lib/systemd/system/vault.service.d/%{name}.conf
%{_libexecdir}/%{name}
%attr(750, vault, vault) %{_sharedstatedir}/%{name}
%attr(750, vault,root) %dir %{_localstatedir}/log/%{name}

%changelog
* Fri Sep 10 2021 Dave Dykstra <dwd@fnal.gov> 1.5-1
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
