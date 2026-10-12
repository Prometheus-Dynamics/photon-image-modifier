#!/usr/bin/env python3
"""Swap the libcamera GPU driver JNI in a released PhotonVision linuxarm64 jar.

    swap-photonlibcamera.py --jar IN.jar --lib libphotonlibcamera.so --out OUT.jar

PhotonVision's release jars bundle linux/arm64/shared/libphotonlibcamera.so
built for Raspberry Pi OS (libcamera 0.5, GLVND's libOpenGL). Raze builds the
same driver version against its own libcamera and Mesa (raze/photonvision-
release.toml); this puts that library in the jar in place of the bundled one.

WPILib's CombinedRuntimeLoader checks every extracted native against the MD5
in /ResourceInformation.json, so the entry's MD5 is updated, and the combined
hash (the nativecache directory name) is recomputed the way
raze/assets/buildroot/pack-photonvision-jar.py computes it, so a cache filled
from the stock jar is never mistaken for this one. Every other entry is copied
as it is, with its original compression.
"""

import argparse
import hashlib
import json
import os
import sys
import warnings
import zipfile

RESOURCE_INFO = "ResourceInformation.json"
LIB_ENTRY = "linux/arm64/shared/libphotonlibcamera.so"
EM_AARCH64 = 183


def die(msg):
    print(f"swap-photonlibcamera: error: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def md5(data):
    return hashlib.md5(data).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--jar", required=True, help="released PhotonVision linuxarm64 jar")
    ap.add_argument("--lib", required=True, help="libphotonlibcamera.so to put in it")
    ap.add_argument("--out", required=True, help="jar to write")
    args = ap.parse_args()

    with open(args.lib, "rb") as f:
        lib = f.read()
    if lib[:4] != b"\x7fELF" or lib[4] != 2 or int.from_bytes(lib[18:20], "little") != EM_AARCH64:
        die(f"{args.lib} is not a 64-bit AArch64 ELF")

    zin = zipfile.ZipFile(args.jar)
    names = zin.namelist()
    if LIB_ENTRY not in names:
        die(f"{args.jar} has no {LIB_ENTRY}")
    if RESOURCE_INFO not in names:
        die(f"{args.jar} has no /{RESOURCE_INFO}")

    resinfo = json.loads(zin.read(RESOURCE_INFO))
    try:
        file_hashes = resinfo["platforms"]["linux"]["architectures"]["arm64"]["fileHashes"]
    except KeyError:
        die(f"/{RESOURCE_INFO} lists no linux/arm64 natives")
    key = "/" + LIB_ENTRY
    if key not in file_hashes:
        die(f"/{RESOURCE_INFO} does not list {key}")
    old = file_hashes[key]
    file_hashes[key] = md5(lib)
    resinfo["hash"] = md5("".join(f"{p}={h}\n" for p, h in sorted(file_hashes.items())).encode())
    new_resinfo = (json.dumps(resinfo, indent=2, sort_keys=True) + "\n").encode()

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    tmp = args.out + ".tmp"
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")  # duplicate license entries are kept as they are
        with zipfile.ZipFile(tmp, "w", allowZip64=True) as zout:
            for info in zin.infolist():
                if info.filename == LIB_ENTRY:
                    blob = lib
                elif info.filename == RESOURCE_INFO:
                    blob = new_resinfo
                else:
                    blob = zin.read(info)
                zout.writestr(info, blob, compress_type=info.compress_type)

    # Check the result the way the loader reads it.
    with zipfile.ZipFile(tmp) as zcheck:
        check = json.loads(zcheck.read(RESOURCE_INFO))
        listed = check["platforms"]["linux"]["architectures"]["arm64"]["fileHashes"]
        if md5(zcheck.read(LIB_ENTRY)) != listed[key]:
            die("swapped library does not match its MD5 in the written jar")
    os.replace(tmp, args.out)
    print(f"swap-photonlibcamera: {LIB_ENTRY}: {old} -> {listed[key]}; hash {check['hash']}; wrote {args.out}", flush=True)


if __name__ == "__main__":
    main()
