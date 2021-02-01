%define downloads_version 1.0
%define plugin1_name vault-plugin-auth-jwt
%define plugin1_version 0.7.3
%define plugin2_name vault-plugin-secrets-oauthapp
%define plugin2_version 1.9.0

# This is to avoid
#   *** ERROR: No build ID note found
%define debug_package %{nil}

Summary: Configuration for Hashicorp Vault for use with htgettoken client
Name: htvault-config
Version: 0.2
Release: 1%{?dist}
Group: Applications/System
License: BSD
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
# download with:
# $ curl -o htvault-config-%{version}.tar.gz \
#    https://codeload.github.com/fermitools/htvault-config/tar.gz/v%{version}
Source0: %{name}-%{version}.tar.gz
# create with ./make-downloads
Source1: %{name}-downloads-%{downloads_version}.tar.gz

Requires: vault
Requires: jq

BuildRequires: golang

%prep
%setup -q
%setup -q -T -b 1 -n %{name}-downloads-%{downloads_version}

%description
Installs plugins and configuration for Hashicorp Vault for use with
htgettoken as a client.

%build
# starts out in htgettoken-downloads
export GOPATH=$PWD/gopath
export PATH=$GOPATH/bin:$PATH
cd %{plugin1_name}-%{plugin1_version}
# skip the git in the build script
ln -s /bin/true git
PATH=:$PATH make dev
cd ../%{plugin2_name}-%{plugin2_version}
make
cd ..

%install
# starts out in htgettoken-downloads
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
cp libexec/* $LIBEXECDIR
mv $LIBEXECDIR/plugin-wrapper.sh $LIBEXECDIR/plugins
ln -s plugin-wrapper.sh $LIBEXECDIR/plugins/%{plugin1_name}.sh
ln -s plugin-wrapper.sh $LIBEXECDIR/plugins/%{plugin2_name}.sh
mkdir -p $RPM_BUILD_ROOT%{_sharedstatedir}/%{name}
mkdir -p $RPM_BUILD_ROOT%{_localstatedir}/log/%{name}

%post
systemctl daemon-reload

%files
%attr(750, vault, vault) %{_sysconfdir}/%{name}
%attr(750, root, root) %{_sysconfdir}/%{name}/config.d
%{_sysconfdir}/logrotate.d/%{name}
%config(noreplace) %{_sysconfdir}/sysconfig/%{name}
/lib/systemd/system/%{name}.service
/lib/systemd/system/vault.service.d/%{name}.conf
%{_libexecdir}/%{name}
%attr(750, vault, vault) %{_sharedstatedir}/%{name}
%attr(750, root,root) %dir %{_localstatedir}/log/%{name}

%changelog
* Mon Feb 01 2021 Dave Dykstra <dwd@fnal.gov> 0.2-1
- Pre-download and prepare all the go modules using new make-downloads
  script, so no network is needed during rpm build.

* Fri Jan 29 2021 Dave Dykstra <dwd@fnal.gov> 0.1-1
- Initial pre-release, including parameterization based on shell variables
