# Patches

`sailfish-fpd-community.patch` is the diff of the modified GPL-3.0 daemon
against upstream
[`sailfishos-open/sailfish-fpd-community`](https://github.com/sailfishos-open/sailfish-fpd-community)
master.

It contains:

| File | Change |
|---|---|
| `src/fpdcommunity.cpp` | identify timeout 30 s → 120 s; `Verify` now calls `authenticate()` instead of `enroll()` |
| `rpm/sailfish-fpd-community.spec` | drop unavailable `libhybris-devel`/`desktop-file-utils` BuildRequires; add runtime `libhybris` |
| `rpm/droid-biometry-fp.spec` | `rm -rf droid-biometry-fp-0.0.0` before extracting the tarball (mb2 reuses the source directory) |
| `sailfish-fpd-community.service` | `After=wait_for_keymaster.service` |

Apply it to a clean checkout:

```bash
git clone https://github.com/sailfishos-open/sailfish-fpd-community.git
cd sailfish-fpd-community
git apply ../patches/sailfish-fpd-community.patch
```

The complete modified source is also included in
`../src/sailfish-fpd-community/`, so the patch is optional (it is useful for
review/rebasing).
