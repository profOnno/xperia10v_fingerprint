Name:           xperia10v-fingerprint
Version:        1.0
Release:        8
Summary:        Xperia 10 V fingerprint unlock for Sailfish OS 5.1.0.11
License:        GPL-3.0-or-later
URL:            https://github.com/sailfishos-open/sailfish-fpd-community
Source0:        xperia10v-fingerprint-1.0.tar.bz2
ExclusiveArch:  aarch64

# libbiometry_fp_api.so is a bionic library; its Android SONAMEs
# (libbase, libbinder_ndk, libc.so, ...) are not glibc RPM dependencies.
%define __requires_exclude_from ^.*/libbiometry_fp_api\.so$

# The meta package replaces the split daemon/bridge packages.
Provides:       sailfish-fpd
Obsoletes:      sailfish-fpd-community < 1.2
Obsoletes:      droid-biometry-fp < 1.2

%description
Single-file Sailfish OS fingerprint stack for the Sony Xperia 10 V
(pdx235 / XQ-DC72) running the Sailfish OS 5.1.0.11 xqdc72 community port
on top of a LineageOS 22.2 / Android 15 vendor base.

It bundles:
  - sailfish-fpd-community (D-Bus org.sailfishos.fingerprint1)
  - the AIDL V4 libbiometry_fp_api bridge
  - the devicelock configuration and boot-order unit

Jolla's proprietary encsfa-fpd plugin and libsailfishdevicelock are NOT
included. install.sh extracts them on the phone from the official Jolla
packages supplied by the user.

The phone-side install.sh validates the device, Sailfish version, Lineage/
Android version and fingerprint HAL before installing. A reboot is required.

%prep
%setup -q

%install
cd xperia10v-fingerprint-1.0
rm -rf %{buildroot}

install -D -m 0755 sailfish-fpd-community \
    %{buildroot}/usr/bin/sailfish-fpd-community
install -D -m 0644 org.sailfishos.fingerprint1.conf \
    %{buildroot}/etc/dbus-1/system.d/org.sailfishos.fingerprint1.conf
install -D -m 0644 sailfish-fpd-community.service \
    %{buildroot}/usr/lib/systemd/system/sailfish-fpd-community.service
install -D -m 0755 libbiometry_fp_api.so \
    %{buildroot}/usr/libexec/droid-hybris/system/lib64/libbiometry_fp_api.so

install -D -m 0644 sailfish-devicelock-encsfa-fpd.service \
    %{buildroot}/usr/lib/systemd/system/sailfish-devicelock-encsfa-fpd.service
install -D -m 0644 devicelock.conf \
    %{buildroot}/usr/share/xperia10v-fingerprint/devicelock.conf
install -D -m 0755 install.sh \
    %{buildroot}/usr/share/xperia10v-fingerprint/install.sh
install -D -m 0644 README.md \
    %{buildroot}/usr/share/doc/xperia10v-fingerprint/README.md

%pre
if [ ! -f /usr/lib64/qt5/plugins/devicelock/encsfa-fpd ] || \
   [ ! -f /usr/lib64/libsailfishdevicelock.so.1.2.0 ]; then
    cat >&2 <<'EOF'
The Jolla devicelock overlay is missing.

Run the phone-side install.sh; it installs the two files from the official
Jolla packages you provide. The files are not redistributed with this RPM.
EOF
    exit 1
fi

if [ "$XPERIA10V_FP_CONFIRM" != "1" ] && [ ! -e /run/xperia10v-fingerprint.confirm ]; then
    cat >&2 <<'EOF'
xperia10v-fingerprint changes the device lock stack (disables the old
devicelock daemon, enables the fpd daemon, switches devicelock.conf) and
requires a reboot.

Run the phone-side install.sh and confirm, or set XPERIA10V_FP_CONFIRM=1
after reading the warning.
EOF
    exit 1
fi

%post
# Do not stop the running old daemon; it is disabled and replaced at reboot.
systemctl daemon-reload || :
systemctl enable sailfish-fpd-community.service || :
systemctl disable --now jolla-devicelock-encsfa.service 2>/dev/null || :
systemctl mask jolla-devicelock-encsfa.service 2>/dev/null || :
rm -f /etc/systemd/system/nemo-devicelock.service
systemctl daemon-reload || :
systemctl restart nemo-devicelock.socket 2>/dev/null || :
systemctl enable --now sailfish-devicelock-encsfa-fpd.service 2>/dev/null || :

mkdir -p /data/vendor_de/100000/fpdata || :
chown -R system:system /data/vendor_de/100000 2>/dev/null || :
chmod 770 /data/vendor_de/100000/fpdata 2>/dev/null || :

if [ ! -f /usr/share/lipstick/devicelock/devicelock.conf.bak ]; then
    cp -a /usr/share/lipstick/devicelock/devicelock.conf \
        /usr/share/lipstick/devicelock/devicelock.conf.bak 2>/dev/null || :
fi
install -m 0644 /usr/share/xperia10v-fingerprint/devicelock.conf \
    /usr/share/lipstick/devicelock/devicelock.conf 2>/dev/null || :
/sbin/ldconfig || :
rm -f /run/xperia10v-fingerprint.confirm
systemctl daemon-reload || :

echo ""
echo "xperia10v-fingerprint installed."
echo "REBOOT REQUIRED to start the new device lock stack and load the lipstick plugin."
echo "After reboot: Settings -> Security -> Device Lock -> Fingerprint."
echo ""

%postun
/sbin/ldconfig || :

%preun
if [ "$1" = 0 ]; then
    systemctl disable --now sailfish-devicelock-encsfa-fpd.service 2>/dev/null || :
    systemctl disable --now sailfish-fpd-community.service 2>/dev/null || :
    if [ -f /usr/share/lipstick/devicelock/devicelock.conf.bak ]; then
        cp -a /usr/share/lipstick/devicelock/devicelock.conf.bak \
            /usr/share/lipstick/devicelock/devicelock.conf 2>/dev/null || :
    fi
    systemctl unmask jolla-devicelock-encsfa.service 2>/dev/null || :
    systemctl daemon-reload || :
    systemctl restart nemo-devicelock.socket 2>/dev/null || :
    systemctl enable --now jolla-devicelock-encsfa.service 2>/dev/null || :
    systemctl daemon-reload || :
    if [ -f /usr/share/xperia10v-fingerprint/overlay-installed ]; then
        rm -f /usr/lib64/qt5/plugins/devicelock/encsfa-fpd
        rm -f /usr/lib64/libsailfishdevicelock.so.1 \
              /usr/lib64/libsailfishdevicelock.so.1.2 \
              /usr/lib64/libsailfishdevicelock.so.1.2.0
        rm -f /usr/share/xperia10v-fingerprint/overlay-installed
    fi
fi

%files
%attr(0755,root,root) /usr/bin/sailfish-fpd-community
%config(noreplace) %attr(0644,root,root) /etc/dbus-1/system.d/org.sailfishos.fingerprint1.conf
%attr(0644,root,root) /usr/lib/systemd/system/sailfish-fpd-community.service
%attr(0755,root,root) /usr/libexec/droid-hybris/system/lib64/libbiometry_fp_api.so
%attr(0644,root,root) /usr/lib/systemd/system/sailfish-devicelock-encsfa-fpd.service

# Supplied by install.sh from the official Jolla packages. %ghost keeps RPM
# ownership so an upgrade from a version that bundled them does not erase
# them, without putting the proprietary files in this package.
%ghost %attr(2755,root,disk) /usr/lib64/qt5/plugins/devicelock/encsfa-fpd
%ghost %attr(0755,root,root) /usr/lib64/libsailfishdevicelock.so.1.2.0
%ghost /usr/lib64/libsailfishdevicelock.so.1.2
%ghost /usr/lib64/libsailfishdevicelock.so.1

%attr(0644,root,root) /usr/share/xperia10v-fingerprint/devicelock.conf
%attr(0755,root,root) /usr/share/xperia10v-fingerprint/install.sh
%attr(0644,root,root) /usr/share/doc/xperia10v-fingerprint/README.md

%changelog
* Fri Nov 06 2026 Xperia 10 V fingerprint port <fp@localhost> - 1.0-8
- Verify SHA256SUMS for host-extracted Jolla files too; the host now extracts them so the phone does not need cpio.

* Fri Nov 06 2026 Xperia 10 V fingerprint port <fp@localhost> - 1.0-7
- Fix the Jolla extraction branch string mismatch that left the plugin/library paths empty; add a guard before installing them.

* Fri Nov 06 2026 Xperia 10 V fingerprint port <fp@localhost> - 1.0-6
- Stop bundling Jolla's proprietary encsfa-fpd and libsailfishdevicelock; install.sh now installs them from the official packages supplied by the user.

* Fri Nov 06 2026 Xperia 10 V fingerprint port <fp@localhost> - 1.0-5
- Clarify the install warning: enrolments (fingerprints) are lost by a reflash.

* Fri Nov 06 2026 Xperia 10 V fingerprint port <fp@localhost> - 1.0-4
- Stop/mask the old jolla-devicelock-encsfa daemon and restart the nemo-devicelock socket so the new fpd daemon owns it; start the new daemon in %post. Unmask/restore on %preun.

* Fri Nov 06 2026 Xperia 10 V fingerprint port <fp@localhost> - 1.0-3
- Add WantedBy=multi-user.target to the devicelock fpd unit so it starts at boot (the socket/alias alone did not start it).

* Fri Nov 06 2026 Xperia 10 V fingerprint port <fp@localhost> - 1.0-2
- Exclude the bionic bridge from RPM auto-requires; install.sh picks the newest RPM and uses --replacepkgs.

* Fri Nov 06 2026 Xperia 10 V fingerprint port <fp@localhost> - 1.0-1
- Initial single-RPM bundle for Sailfish OS 5.1.0.11 / pdx235.
