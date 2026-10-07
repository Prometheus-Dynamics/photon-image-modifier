#!/usr/bin/env python3
"""Pack PhotonVision's linuxarm64 jar for the Raze read-only (EROFS) root.

Run by post-image-rootfs.sh on the extracted root filesystem, after the image
feed has installed /opt/photonvision/photonvision.jar:

    pack-photonvision-jar.py --jar ROOT/opt/photonvision/photonvision.jar \
        --nativecache ROOT/usr/lib/photonvision/wpilib/nativecache \
        --strip HOST/bin/aarch64-linux-strip

What it does to the jar (the artifact PhotonVision's Gradle build produced is
left untouched in output/; only the copy in the image changes):

1. Drops native libraries for other platforms: every ELF that is not 64-bit
   AArch64, and every Windows/macOS library (sqlite-jdbc, JNA and diozero
   bundle all of them).
2. Drops the RKNN and TFLite object detection backends (their JNI, runtimes,
   the libraries only they need, and their .rknn/.tflite models). PhotonVision
   only loads them on RK3588 and QCS6490 boards (Main.java,
   NeuralNetworkModelManager), never on a CM5.
3. Drops the web UI's JavaScript source maps (*.map): only browser developer
   tools fetch them.
4. Pre-extracts the WPILib/OpenCV/photon natives listed in
   /ResourceInformation.json, stripped with the target toolchain, into
   NATIVECACHE/linux/arm64/<hash>/, and rewrites the JSON with their new MD5s
   and a new combined hash. PhotonVision's CombinedRuntimeLoader extracts to
   ~/.wpilib/nativecache/linux/arm64/<hash>/ and skips every file that already
   exists there with the right MD5, so with /root/.wpilib pointing at the
   image's copy it never writes at run time. The loader still opens each
   listed jar entry (it requires a non-null stream before checking the file),
   so the entries stay in the jar, empty.
5. Writes every entry STORED (uncompressed): the root filesystem compresses
   with LZMA, which packs the jar far smaller than per-entry deflate, and the
   JVM and Jetty read stored entries without inflating them.

The result is checked before the script exits: every native the JSON lists
exists in the cache with the listed MD5 and has an entry in the jar.
"""

import argparse
import collections
import hashlib
import io
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import warnings
import zipfile

RESOURCE_INFO = "ResourceInformation.json"
PLATFORM, ARCH = "linux", "arm64"
EM_AARCH64 = 183

# Object detection backends PhotonVision only uses on other SoCs: the JNI
# libraries LoadJNI loads for them (RKNN_DETECTOR: rga, rknnrt, rknn_jni;
# RUBIK_DETECTOR: tflite_jni) and their runtimes. Libraries that only these
# need (absl, ruy, ...) are found from the ELF dependencies and dropped too.
DROPPED_BACKEND_LIB = re.compile(r"^lib(rga|rknnrt|rknn_jni|tflite_jni|tensorflow-?lite.*)\.so(\.[0-9]+)*$")
DROPPED_MODEL = re.compile(r"^models/.*\.(rknn|tflite)$")
SOURCE_MAP = re.compile(r"^web/.*\.map$")
FOREIGN_LIB_SUFFIX = re.compile(r"\.(dll|dylib|jnilib)$", re.IGNORECASE)


def log(msg):
    print(f"pack-photonvision-jar: {msg}", flush=True)


def die(msg):
    print(f"pack-photonvision-jar: error: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def md5(data):
    return hashlib.md5(data).hexdigest()


def elf_info(data):
    """(is_elf, is_aarch64_64bit) for a file's first bytes."""
    if len(data) < 20 or data[:4] != b"\x7fELF":
        return False, False
    ei_class, ei_data = data[4], data[5]
    endian = "<" if ei_data == 1 else ">"
    (machine,) = struct.unpack_from(endian + "H", data, 18)
    return True, ei_class == 2 and machine == EM_AARCH64


def elf_needed(data):
    """DT_NEEDED names of a 64-bit little-endian ELF shared object."""
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        return []
    e_phoff, = struct.unpack_from("<Q", data, 0x20)
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 0x36)
    loads, dynamic = [], None
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, _flags, p_offset, p_vaddr, _paddr, p_filesz = struct.unpack_from("<IIQQQQ", data, off)
        if p_type == 1:
            loads.append((p_vaddr, p_offset, p_filesz))
        elif p_type == 2:
            dynamic = (p_offset, p_filesz)
    if dynamic is None:
        return []

    def vaddr_to_offset(addr):
        for vaddr, offset, size in loads:
            if vaddr <= addr < vaddr + size:
                return addr - vaddr + offset
        return None

    needed, strtab = [], None
    off, end = dynamic[0], dynamic[0] + dynamic[1]
    while off + 16 <= end:
        tag, val = struct.unpack_from("<qQ", data, off)
        off += 16
        if tag == 0:
            break
        if tag == 1:
            needed.append(val)
        elif tag == 5:
            strtab = vaddr_to_offset(val)
    if strtab is None:
        return []
    names = []
    for index in needed:
        start = strtab + index
        stop = data.index(b"\0", start)
        names.append(data[start:stop].decode())
    return names


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--jar", required=True, help="jar to rewrite in place")
    ap.add_argument("--nativecache", required=True, help="nativecache directory to fill")
    ap.add_argument("--strip", required=True, help="target toolchain strip")
    args = ap.parse_args()

    with open(args.jar, "rb") as f:
        original = f.read()
    zin = zipfile.ZipFile(io.BytesIO(original))
    infos = zin.infolist()
    # Duplicate names (license files from several dependencies) are kept as
    # they are; lookups by name read the last one, like java.util.zip does.
    data = {}
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")  # "overlapped entries": the duplicates
        for info in infos:
            data[info.filename] = zin.read(info)

    if RESOURCE_INFO not in data:
        die(f"{args.jar} has no /{RESOURCE_INFO}; PhotonVision's native loader changed")
    resinfo = json.loads(data[RESOURCE_INFO])
    try:
        file_hashes = resinfo["platforms"][PLATFORM]["architectures"][ARCH]["fileHashes"]
    except KeyError:
        die(f"/{RESOURCE_INFO} lists no {PLATFORM}/{ARCH} natives")

    drop = set()
    reasons = {}

    def mark(name, why):
        drop.add(name)
        reasons[why] = reasons.get(why, 0) + len(data.get(name, b""))

    # 1. Other platforms' natives.
    for name, blob in data.items():
        if name.endswith("/"):
            continue
        is_elf, is_target = elf_info(blob[:64])
        if (is_elf and not is_target) or FOREIGN_LIB_SUFFIX.search(name):
            mark(name, "other platforms' natives")

    # 2. RKNN/TFLite backends: their libraries, then whatever only they need.
    natives = {os.path.basename(p): p.lstrip("/") for p in file_hashes}
    needed = {base: elf_needed(data[path]) for base, path in natives.items() if path in data}
    roots = {base for base in natives if DROPPED_BACKEND_LIB.match(base)}
    dropped_libs = set(roots)
    changed = True
    while changed:
        changed = False
        kept = set(natives) - dropped_libs
        kept_needs = {dep for base in kept for dep in needed.get(base, [])}
        for base in natives:
            if base in dropped_libs or base in kept_needs:
                continue
            # Only dropped libraries need it, and at least one of them does.
            if any(base in needed.get(d, []) for d in dropped_libs):
                dropped_libs.add(base)
                changed = True
    for base in sorted(dropped_libs):
        mark(natives[base], "RKNN/TFLite natives")
        del file_hashes["/" + natives[base]]
    for name in data:
        if DROPPED_MODEL.match(name):
            mark(name, "RKNN/TFLite models")

    # 3. Source maps.
    for name in data:
        if SOURCE_MAP.match(name):
            mark(name, "web UI source maps")

    # 4. Pre-extract the natives PhotonVision loads.
    tmp = tempfile.mkdtemp(prefix="pack-photonvision-jar.", dir=os.path.dirname(os.path.abspath(args.jar)))
    try:
        stripped = {}
        for path in sorted(file_hashes):
            name = path.lstrip("/")
            if name not in data:
                die(f"/{RESOURCE_INFO} lists {path}, which is not in the jar")
            if md5(data[name]) != file_hashes[path]:
                die(f"{path} does not match its MD5 in /{RESOURCE_INFO}")
            out = os.path.join(tmp, os.path.basename(name))
            with open(out, "wb") as f:
                f.write(data[name])
            stripped[path] = out
        subprocess.run([args.strip, "--strip-unneeded", *stripped.values()], check=True)

        new_hashes = {}
        blobs = {}
        for path, out in stripped.items():
            with open(out, "rb") as f:
                blob = f.read()
            if not elf_info(blob[:64])[1]:
                die(f"{path} is not an AArch64 ELF after stripping")
            blobs[path] = blob
            new_hashes[path] = md5(blob)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    combined = md5("".join(f"{p}={h}\n" for p, h in sorted(new_hashes.items())).encode())
    file_hashes.clear()
    file_hashes.update(new_hashes)
    resinfo["hash"] = combined

    cache = os.path.join(args.nativecache, PLATFORM, ARCH, combined)
    if os.path.isdir(args.nativecache):
        shutil.rmtree(args.nativecache)
    os.makedirs(cache)
    unpacked = 0
    for path, blob in blobs.items():
        with open(os.path.join(cache, os.path.basename(path)), "wb") as f:
            f.write(blob)
        os.chmod(os.path.join(cache, os.path.basename(path)), 0o755)
        unpacked += len(blob)
        # The loader opens the entry before it checks the cached file.
        data[path.lstrip("/")] = b""
    data[RESOURCE_INFO] = (json.dumps(resinfo, indent=2, sort_keys=True) + "\n").encode()

    # 5. Write the jar back, every entry stored.
    out_path = args.jar + ".new"
    counts = collections.Counter(info.filename for info in infos)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")  # duplicate names are intentional
        with zipfile.ZipFile(out_path, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as zout:
            for info in infos:
                name = info.filename
                if name in drop:
                    continue
                # Duplicated names (license texts) keep each original copy;
                # everything else gets its possibly rewritten content.
                if counts[name] > 1:
                    blob = zin.read(info)
                else:
                    blob = data[name]
                new = zipfile.ZipInfo(name, date_time=info.date_time)
                new.external_attr = info.external_attr
                new.create_system = info.create_system
                new.compress_type = zipfile.ZIP_STORED
                zout.writestr(new, blob)

    # Check the result the way the loader will use it.
    zcheck = zipfile.ZipFile(out_path)
    names = set(zcheck.namelist())
    check = json.loads(zcheck.read(RESOURCE_INFO))
    listed = check["platforms"][PLATFORM]["architectures"][ARCH]["fileHashes"]
    for path, digest in listed.items():
        if path.lstrip("/") not in names:
            die(f"{path} is listed but has no jar entry")
        with open(os.path.join(args.nativecache, PLATFORM, ARCH, check["hash"], os.path.basename(path)), "rb") as f:
            if md5(f.read()) != digest:
                die(f"cached {path} does not match its MD5")
    os.replace(out_path, args.jar)

    mib = 1024 * 1024
    for why, size in sorted(reasons.items()):
        log(f"dropped {why}: {size / mib:.1f} MiB uncompressed")
    log(f"pre-extracted {len(listed)} natives ({unpacked / mib:.1f} MiB stripped) to {cache}")
    log(f"jar: {len(original) / mib:.1f} MiB deflated -> {os.path.getsize(args.jar) / mib:.1f} MiB stored")


if __name__ == "__main__":
    main()
