%define tarball_version 1.3
%define plugin1_name vault-plugin-auth-jwt
%define plugin1_version 0.9.2
%define plugin2_name vault-plugin-secrets-oauthapp
%define plugin2_version 2.0.0

# This is to avoid
#   *** ERROR: No build ID note found
%define debug_package %{nil}

# This is so brp-python-bytecompile uses python3
%define __python python3

Summary: Configuration for Hashicorp Vault for use with htgettoken client
Name: htvault-config
Version: 1.0
Release: 2%{?dist}
Group: Applications/System
License: BSD
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
# download with:
# $ curl -o htvault-config-%{version}.tar.gz \
#    https://codeload.github.com/fermitools/htvault-config/tar.gz/v%{version}
Source0: %{name}-%{version}.tar.gz
# create with ./make-source-tarball
Source1: %{name}-src-%{tarball_version}.tar.gz

Requires: vault >= 1.7.1
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
cd %{plugin1_name}-%{plugin1_version}
# skip the git in the build script
ln -s /bin/true git
PATH=:$PATH make dev
cd ../%{plugin2_name}-%{plugin2_version}
make
cd ..

%install
# starts out in %{name}-src-%{tarball_version}
LIBEXECDIR=$RPM_BUILD_ROOT/%{_libexecdir}/%{name}
PLUGINDIR=$LIBEXECDIR/plugins
mkdir -p $PLUGINDIR
cp %{plugin1_name}-%{plugin1_version}/bin/%{plugin1_name} $PLUGINDIR
cp %{plugin2_name}-%{plugin2_version}/bin/%{plugin2_name} $PLUGINDIR
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
%attr(750, root,root) %dir %{_localstatedir}/log/%{name}

%changelog
# - Correctly disable secret oauth module instead of incorrect auth module
#    when something changes requiring clearing out of old secrets.
# - Allow dashes in names by converting them in bash variables to
    underscores, and reject any other non-alphanumeric or underscore in
    names.

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
