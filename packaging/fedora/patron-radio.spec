Name:           patron-radio
Version:        0.8
Release:        1%{?dist}
Summary:        Plasma 6 panel widget for streaming independent and public radio stations

License:        GPL-3.0-or-later
URL:            https://github.com/ajweiss/patron-radio
Source0:        %{url}/archive/refs/tags/v%{version}.tar.gz#/%{name}-%{version}.tar.gz

BuildRequires:  cmake
BuildRequires:  gcc-c++
BuildRequires:  extra-cmake-modules
BuildRequires:  qt6-qtbase-devel
BuildRequires:  qt6-qtdeclarative-devel
BuildRequires:  qt6-qtmultimedia-devel
BuildRequires:  kf6-kcoreaddons-devel
BuildRequires:  kf6-kconfig-devel
BuildRequires:  kf6-ki18n-devel
BuildRequires:  kf6-kio-devel
BuildRequires:  libebur128-devel
# for the ctest run in %%check
BuildRequires:  dbus-daemon
BuildRequires:  dbus-tools

Requires:       plasma-workspace
# runtime QML module (org.kde.bluezqt), not linked so not auto-detected
Requires:       kf6-bluez-qt

%description
Patron Radio is a native KDE Plasma 6 panel widget for streaming a curated
set of independent and public radio stations. It features live stream-title
metadata, EBU R128 loudness normalization, MPRIS integration, smart audio
device routing, and one-click donation links for supporting the stations.

%prep
%autosetup -n patron-radio-%{version}

%build
%cmake
%cmake_build

%install
%cmake_install

%check
cd %{__cmake_builddir}
dbus-run-session -- ctest --output-on-failure --force-new-ctest-process

%files
%license LICENSE
%doc README.md
%{_datadir}/plasma/plasmoids/com.signal11.patronradio/
%{_datadir}/applications/com.signal11.patronradio.desktop

%changelog
* Thu Jul 23 2026 Adam Weiss <adam@signal11.com> - 0.8-1
- Initial package
