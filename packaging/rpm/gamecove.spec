# GameCove RPM for Bazzite / Fedora Atomic (rpm-ostree) and Fedora.
#
# Built by .github/workflows/release.yml (rpmbuild in a pinned Fedora container; not in mock).
# Tested on hardware: MSI Claw 8 EX AI+ (Bazzite) and ASUS ROG Ally (SteamOS).
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
# (notice in fixes/claw8ex-vrr/LICENSE.ClawLab-MIT). Bundled in the app: Godot Engine
# 4.7.2's export template (MIT, plus the components in LICENSES/Godot-COPYRIGHT.txt:
# Apache-2.0, BSD-2/3-Clause, Zlib, MPL-2.0, BSL-1.0, FTL, IJG, Unlicense, CC-BY-4.0
# and a few project licences grouped as LicenseRef-Godot-thirdparty), the OFL-1.1
# fonts, the kenyoni QR encoder (MIT), ReShade.fxh (CC0-1.0), the CRT-Lottes effect
# (public domain), Simple Icons path data (CC0-1.0) and the Heroic / Lutris / Bottles
# icons (GPL-3.0). The maker and store logos in app/assets/brand are their owners'
# trademarks, not GPL-licensed (app/assets/brand/LICENSE.md): LicenseRef-Trademarked-logos.
# The one bundled device picture (app/assets/device_photos/acer-nitro-blaze-8.webp, bundled because no
# linkable head-on image exists) is the maker's, not GPL-licensed (CREDITS.md): LicenseRef-Maker-image.
License:        GPL-3.0-or-later AND GPL-3.0-only AND GPL-2.0-only AND GPL-2.0-or-later AND MIT AND OFL-1.1 AND CC0-1.0 AND LicenseRef-Fedora-Public-Domain AND Apache-2.0 AND BSD-2-Clause AND BSD-3-Clause AND Zlib AND MPL-2.0 AND BSL-1.0 AND FTL AND IJG AND Unlicense AND CC-BY-4.0 AND LicenseRef-Godot-thirdparty AND LicenseRef-Trademarked-logos AND LicenseRef-Maker-image
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
# licence and notice texts: every file packaging/licenses.list names (review H8)
mkdir -p licenses
while read -r src dest; do
    case "$src" in ''|'#'*) continue ;; esac
    install -pm0644 "$src" "licenses/$dest"
done < packaging/licenses.list

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
install -Dpm0755 packaging/libexec/gamecove-apply-choices %{buildroot}%{_libexecdir}/gamecove/gamecove-apply-choices
install -Dpm0755 packaging/get-gamecove.sh            %{buildroot}%{_libexecdir}/gamecove/get-gamecove.sh
# Per-game launch wrapper and upscaling helper (perf controls)
install -Dpm0755 packaging/libexec/gamecove-run       %{buildroot}%{_libexecdir}/gamecove/gamecove-run
install -Dpm0755 packaging/libexec/reaper             %{buildroot}%{_libexecdir}/gamecove/reaper
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

# Root autologin guard: the installer copies both into /etc so they outlive the package
# (session/gamecove-autologin-guard says why)
install -Dpm0755 session/gamecove-autologin-guard \
    %{buildroot}%{_prefix}/lib/gamecove/session/gamecove-autologin-guard
install -Dpm0644 session/systemd/gamecove-autologin-guard.service \
    %{buildroot}%{_prefix}/lib/gamecove/session/gamecove-autologin-guard.service

# Root autologin guard: the installer copies both into /etc so they outlive the package
# (session/gamecove-autologin-guard says why)
install -Dpm0755 session/gamecove-autologin-guard \
    %{buildroot}%{_prefix}/lib/gamecove/session/gamecove-autologin-guard
install -Dpm0644 session/systemd/gamecove-autologin-guard.service \
    %{buildroot}%{_prefix}/lib/gamecove/session/gamecove-autologin-guard.service

# polkit
install -Dpm0644 packaging/polkit/io.github.ihulksmashi.gamecove.policy \
    %{buildroot}%{_datadir}/polkit-1/actions/io.github.ihulksmashi.gamecove.policy

# Change log lives here (created by gamecove-fix on first change)
mkdir -p %{buildroot}%{_localstatedir}/lib/gamecove

%files
%license licenses/*
%doc README.md CREDITS.md docs/SESSION.md
%dir %{_prefix}/lib/gamecove
%{_prefix}/lib/gamecove/gamecove.x86_64
%{_prefix}/lib/gamecove/gamecove.pck
%{_prefix}/lib/gamecove/fixes
%{_prefix}/lib/gamecove/session
%dir %{_libexecdir}/gamecove
%{_libexecdir}/gamecove/gamecove-fix
%{_libexecdir}/gamecove/gamecove-fix-set
%{_libexecdir}/gamecove/gamecove-session-client
%{_libexecdir}/gamecove/gamecove-apply-choices
%{_libexecdir}/gamecove/get-gamecove.sh
%{_libexecdir}/gamecove/gamecove-run
%{_libexecdir}/gamecove/reaper
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
