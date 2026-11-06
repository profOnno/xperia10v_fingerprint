# Documentation index

| Document | What it covers |
|---|---|
| [`file-map.md`](file-map.md) | Per-file map of the repository and the corresponding installed phone paths |
| [`meta-rpm.md`](meta-rpm.md) | Single-RPM end-user installer, phone-side validation, `%pre`/`%post`, install/rollback |
| [`architecture.md`](architecture.md) | Global working principle, every layer from `/dev/esfp0` to the Settings UI, enrollment/authentication sequences, storage and boot order |
| [`functions.md`](functions.md) | Index of every bridge function, daemon method and script, with a one-line description and a link to the detailed reference |
| [`biometry-bridge.md`](biometry-bridge.md) | Function-by-function reference for `biometry_fp_aidl_for_hybris.cpp` (AIDL client, gatekeeper HAT, callbacks, C ABI) |
| [`fpd-daemon.md`](fpd-daemon.md) | `sailfish-fpd-community` D-Bus API, state machine, bridge loading, store paths and the local patches |
| [`scripts.md`](scripts.md) | Every build/install/test script: purpose, prerequisites, usage and what it does step by step |
| [`system-integration.md`](system-integration.md) | systemd units, boot order, the official devicelock overlay, `devicelock.conf`, mce settings, rollback |
| [`troubleshooting.md`](troubleshooting.md) | The concrete failures encountered during the port and their fixes |

Quick pointers:

* **“How does the whole thing work?”** → [`architecture.md`](architecture.md)
* **“What does `u_hardware_biometry_enroll()` do?”** → [`biometry-bridge.md`](biometry-bridge.md)
* **“What does `install-devicelock-overlay.sh` change?”** → [`scripts.md`](scripts.md)
* **“Where do the Jolla overlay files come from?”** → [`overlay/README.md`](../overlay/README.md)
* **“Why did the HAL stall at `ISession::enroll started`?”** → [`troubleshooting.md`](troubleshooting.md)
