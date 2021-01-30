%define plugin1_name vault-plugin-auth-jwt
%define plugin1_version 0.7.3
%define plugin2_name vault-plugin-secrets-oauthapp
%define plugin2_version 1.9.0

# This is to avoid
#   *** ERROR: No build ID note found
%define debug_package %{nil}

Summary: Configuration for Hashicorp Vault for use with htgettoken client
Name: htvault-config
Version: 0.1
Release: 1%{?dist}
Group: Applications/System
License: BSD
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
# download with:
# $ curl -o htvault-config-%{version}.tar.gz \
#    https://codeload.github.com/fermitools/htvault-config/tar.gz/v%{version}
Source0: %{name}-%{version}.tar.gz
# $ curl -o %{plugin1_name}-%{plugin1_version}.tar.gz \
#    https://codeload.github.com/hashicorp/%{plugin1_name}/tar.gz/v%{plugin1_version}
Source1: %{plugin1_name}-%{plugin1_version}.tar.gz
# $ curl -o %{plugin2_name}-%{plugin2_version}.tar.gz \
#    https://codeload.github.com/puppetlabs/%{plugin2_name}/tar.gz/v%{plugin2_version}
Source2: %{plugin2_name}-%{plugin2_version}.tar.gz

# download with 
#  $ curl -L -o htvault1-119.patch https://github.com/hashicorp/vault-plugin-auth-jwt/pull/119.patch
Patch11: htvault1-119.patch
# download with 
#  $ curl -L -o htvault1-131.patch https://github.com/hashicorp/vault-plugin-auth-jwt/pull/131.patch
Patch12: htvault1-131.patch

# download with 
#  $ curl -L -o htvault2-24.patch https://github.com/puppetlabs/vault-plugin-secrets-oauthapp/pull/24.diff
Patch21: htvault2-24.patch
# download with 
#  $ curl -L -o htvault2-26.patch https://github.com/puppetlabs/vault-plugin-secrets-oauthapp/pull/26.diff
Patch22: htvault2-26.patch
# download with 
#  $ curl -L -o htvault2-34.patch https://github.com/puppetlabs/vault-plugin-secrets-oauthapp/pull/34.diff
Patch23: htvault2-34.patch

Requires: vault
Requires: jq

BuildRequires: golang
%if 0%{?rhel} == 7
%define newgit rh-git218
BuildRequires: %{newgit}
%endif


%prep
GOPATH=%{plugin1_name}-%{plugin1_version}/gopath
if [ -d $GOPATH ]; then
    # make go cache deletable 
    find $GOPATH -type d ! -perm -200|xargs -r chmod u+w
fi
%setup -q
%setup -b 1 -n %{plugin1_name}-%{plugin1_version} -q
%patch -P 11 -p1
# There is a slight clash between the two PRs, but re-applying the .rej
#  file afterward happens to make it apply cleanly
#%patch -P 12 -p1
patch -p1 <%{PATCH12} || patch -p0 <path_oidc.go.rej
%setup -b 2 -n %{plugin2_name}-%{plugin2_version} -q
%patch -P 21 -p1
%patch -P 22 -p1
%patch -P 23 -p1

%description
Installs plugins and configuration for Hashicorp Vault for use with
htgettoken as a client.

%build
cd ../%{plugin1_name}-%{plugin1_version}
export GOPATH=$PWD/gopath
export PATH=$GOPATH/bin:$PATH
%if 0%{?rhel} == 7
scl enable %{newgit} "make bootstrap"
%else
make bootstrap
%endif
go mod vendor
# skip the git in the build script
ln -s /bin/true git
PATH=:$PATH make dev
cd ../%{plugin2_name}-%{plugin2_version}
%if 0%{?rhel} == 7
scl enable %{newgit} "make"
%else
make
%endif
cd ..

%install
LIBEXECDIR=$RPM_BUILD_ROOT/%{_libexecdir}/%{name}
PLUGINDIR=$LIBEXECDIR/plugins
mkdir -p $PLUGINDIR
cd ..
cp %{plugin1_name}-%{plugin1_version}/bin/%{plugin1_name} $PLUGINDIR
cp %{plugin2_name}-%{plugin2_version}/bin/%{plugin2_name} $PLUGINDIR
cd %{name}-%{version}
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
* Fri Jan 29 2021 Dave Dykstra <dwd@fnal.gov> 0.1-1
- Initial pre-release, including parameterization based on shell variables
