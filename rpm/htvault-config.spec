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

Requires: vault

BuildRequires: golang
%if 0%{?rhel} == 7
%define newgit rh-git218
BuildRequires: %{newgit}
%endif


%prep
GOPATH=%{plugin1_name}-%{plugin1_version}/gopath
if [ -d $GOPATH ]; then
    # make go cache deletable 
    find $GOPATH -type d ! -perm -200|xargs chmod u+w
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

%description
Installs plugins and configuration for Hashicorp Vault

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
cd ..
PLUGINDIR=$RPM_BUILD_ROOT%{_libexecdir}/%{name}/plugins
mkdir -p $PLUGINDIR
cp %{plugin1_name}-%{plugin1_version}/bin/%{plugin1_name} $PLUGINDIR
cp %{plugin2_name}-%{plugin2_version}/bin/%{plugin2_name} $PLUGINDIR

%files
%{_libexecdir}/%name

%changelog
