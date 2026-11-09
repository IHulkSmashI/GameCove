# GameCove RPM for Bazzite / Fedora Atomic (rpm-ostree) and Fedora.
#
# UNTESTED: written against Fedora packaging guidelines and checked with
# `rpmspec -P`, but never built in mock or installed on a handheld.
#
# Sources:
#   Source0  the repository at a tag (git archive), for session files, helpers, fixes
#   Source1  the exported Godot app: gamecove-<version>-x86_64.tar.gz holding
#            gamecove.x86_64 and gamecove.pck (made by CI from app/, not by this spec,
#            because Godot export templates aren't packaged in Fedora;
#            .github/workflows/release.yml makes it)
#   Source2  udev-hid-bpf at a pinned commit, for the headers the gyro fix's HID-BPF
#            program is compiled against in %%build

%global debug_package %{nil}
%global _build_id_links none
# Keep in step with UHB_PIN in fixes/claw8ex-gyro/bpf/build-bpf.sh
%global uhb_commit bbaad63

Name:           gamecove
Version:        0.1.0
Release:        1%{?dist}
Summary:        Controller-first home screen for Linux handhelds
# GameCove: GPL-3.0-or-later. The gyro fix's HID-BPF program (fixes/claw8ex-gyro/bpf,
# built here into MSI__Claw-ISH-IMU.bpf.o) is GPL-2.0-only; its Python helpers are
# GPL-2.0-or-later. The VRR panel list and EDID logic derive from MIT-licensed code
# (notice in fixes/claw8ex-vrr/LICENSE.ClawLab-MIT); MIT is GPL-compatible and
# absorbed into the GPL-3.0-or-later work.
License:        GPL-3.0-or-later AND GPL-3.0-only AND GPL-2.0-only AND GPL-2.0-or-later
URL:            https://github.com/IHulkSmashI/gamecove
Source0:        %{url}/archive/v%{version}/%{name}-%{version}.tar.gz
Source1:        %{url}/releases/download/v%{version}/%{name}-%{version}-x86_64.tar.gz
# udev-hid-bpf's BPF headers at the commit build-bpf.sh pins, to build the gyro program
Source2:        https://gitlab.freedesktop.org/libevdev/udev-hid-bpf/-/archive/%{uhb_commit}/udev-hid-bpf-%{uhb_commit}.tar.gz
ExclusiveArch:  x86_64

BuildRequires:  systemd-rpm-macros
# The gyro fix's HID-BPF program (fixes/claw8ex-gyro/bpf/build-bpf.sh)
BuildRequires:  clang
BuildRequires:  llvm
BuildRequires:  libbpf-devel
BuildRequires:  kernel-headers

# File dependencies so any package that provides them works (Terra's
# gamescope-session, a distro gamescope-session-plus, ...).
Requires:       gamescope
Requires:       /usr/bin/gamescope-session-plus
# Sets gamescope's X11 properties (frame limit, overlay, focus).
Requires:       /usr/bin/xprop
Requires:       /usr/bin/pkexec
Requires:       polkit
# Session switching and TDP; Bazzite ships it, plain Fedora may not.
Recommends:     steamos-manager
Recommends:     inputplumber
Recommends:     powerstation
Recommends:     steam

%description
GameCove is a free, open-source home screen for Linux handhelds. It runs as
gamescope's main client in its own session, puts every game store in one
library and gives quick access to power, screen and controller settings.

%prep
%autosetup -n %{name}-%{version}
mkdir -p app-export
tar -xzf %{SOURCE1} -C app-export
mkdir -p udev-hid-bpf
tar -xzf %{SOURCE2} -C udev-hid-bpf --strip-components=1

%build
# The Godot app comes pre-exported in Source1. Build the gyro fix's HID-BPF
# program from its source; fix.sh refuses to install without it.
UHB_SRC="$PWD/udev-hid-bpf" sh fixes/claw8ex-gyro/bpf/build-bpf.sh

%install
# The app
install -Dpm0755 app-export/gamecove.x86_64 %{buildroot}%{_prefix}/lib/gamecove/gamecove.x86_64
install -Dpm0644 app-export/gamecove.pck    %{buildroot}%{_prefix}/lib/gamecove/gamecove.pck

# Root fixes (one folder per fix, each with fix.sh); none is applied on install
if [ -d fixes ]; then
    mkdir -p %{buildroot}%{_prefix}/lib/gamecove/fixes
    cp -a fixes/. %{buildroot}%{_prefix}/lib/gamecove/fixes/
    find %{buildroot}%{_prefix}/lib/gamecove/fixes -name 'test.sh' -delete
    find %{buildroot}%{_prefix}/lib/gamecove/fixes -depth -type d -name tests -exec rm -rf {} +
fi
mkdir -p %{buildroot}%{_prefix}/lib/gamecove/fixes

# Helpers
install -Dpm0755 packaging/libexec/gamecove-fix       %{buildroot}%{_libexecdir}/gamecove/gamecove-fix
install -Dpm0755 packaging/libexec/gamecove-fix-set   %{buildroot}%{_libexecdir}/gamecove/gamecove-fix-set
install -Dpm0755 session/gamecove-session-client      %{buildroot}%{_libexecdir}/gamecove/gamecove-session-client
%{_libexecdir}/gamecove/gamecove-apply-choices
%{_libexecdir}/gamecove/get-gamecove.sh
%{_datadir}/applications/io.github.ihulksmashi.GameCoveInstaller.desktop
install -Dpm0755 packaging/libexec/gamecove-apply-choices %{buildroot}%{_libexecdir}/gamecove/gamecove-apply-choices
install -Dpm0755 packaging/get-gamecove.sh            %{buildroot}%{_libexecdir}/gamecove/get-gamecove.sh
# Per-game launch wrapper and upscaling helper (perf controls)
install -Dpm0755 packaging/libexec/gamecove-run       %{buildroot}%{_libexecdir}/gamecove/gamecove-run
install -Dpm0755 packaging/libexec/gamecove-upscale   %{buildroot}%{_libexecdir}/gamecove/gamecove-upscale
mkdir -p %{buildroot}%{_prefix}/lib/gamecove/helpers
cp -a packaging/helpers/gamecove_upscale %{buildroot}%{_prefix}/lib/gamecove/helpers/
find %{buildroot}%{_prefix}/lib/gamecove/helpers -depth -type d -name __pycache__ -exec rm -rf {} +
install -Dpm0644 packaging/installer/io.github.ihulksmashi.GameCoveInstaller.desktop \
    %{buildroot}%{_datadir}/applications/io.github.ihulksmashi.GameCoveInstaller.desktop
install -Dpm0755 session/gamecove-session-select      %{buildroot}%{_bindir}/gamecove-session-select
install -Dpm0755 packaging/bin/gamecove-selftest      %{buildroot}%{_bindir}/gamecove-selftest

# Session
install -Dpm0644 session/gamescope-session-plus/sessions.d/gamecove \
    %{buildroot}%{_datadir}/gamescope-session-plus/sessions.d/gamecove
install -Dpm0644 session/wayland-sessions/gamecove.desktop \
    %{buildroot}%{_datadir}/wayland-sessions/gamecove.desktop
install -Dpm0644 session/systemd/gamescope-session-plus@gamecove.service.d/10-gamecove.conf \
    %{buildroot}%{_userunitdir}/gamescope-session-plus@gamecove.service.d/10-gamecove.conf

# polkit
install -Dpm0644 packaging/polkit/io.github.ihulksmashi.gamecove.policy \
    %{buildroot}%{_datadir}/polkit-1/actions/io.github.ihulksmashi.gamecove.policy

# Change log lives here (created by gamecove-fix on first change)
mkdir -p %{buildroot}%{_localstatedir}/lib/gamecove

%files
%license LICENSE LICENSES/GPL-2.0-only.txt fixes/claw8ex-vrr/LICENSE.ClawLab-MIT
%doc README.md docs/SESSION.md
%dir %{_prefix}/lib/gamecove
%{_prefix}/lib/gamecove/gamecove.x86_64
%{_prefix}/lib/gamecove/gamecove.pck
%{_prefix}/lib/gamecove/fixes
%dir %{_libexecdir}/gamecove
%{_libexecdir}/gamecove/gamecove-fix
%{_libexecdir}/gamecove/gamecove-fix-set
%{_libexecdir}/gamecove/gamecove-session-client
%{_libexecdir}/gamecove/gamecove-apply-choices
%{_libexecdir}/gamecove/get-gamecove.sh
%{_libexecdir}/gamecove/gamecove-run
%{_libexecdir}/gamecove/gamecove-upscale
%{_prefix}/lib/gamecove/helpers
%{_datadir}/applications/io.github.ihulksmashi.GameCoveInstaller.desktop
%{_bindir}/gamecove-session-select
%{_bindir}/gamecove-selftest
%dir %{_datadir}/gamescope-session-plus
%dir %{_datadir}/gamescope-session-plus/sessions.d
%{_datadir}/gamescope-session-plus/sessions.d/gamecove
%{_datadir}/wayland-sessions/gamecove.desktop
%dir %{_userunitdir}/gamescope-session-plus@gamecove.service.d
%{_userunitdir}/gamescope-session-plus@gamecove.service.d/10-gamecove.conf
%{_datadir}/polkit-1/actions/io.github.ihulksmashi.gamecove.policy
%dir %{_localstatedir}/lib/gamecove

%changelog
* Sun Nov 08 2026 Mena Hanna <227083792+IHulkSmashI@users.noreply.github.com> - 0.1.0-1
- First package: session, gamescope helper, root-fix dispatcher, polkit policy
