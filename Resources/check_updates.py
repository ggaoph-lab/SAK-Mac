#!/usr/bin/env python3
"""Compare local NSP/XCI/NSZ/XCZ files against titledb versions.txt.

Emits JSON lines on stdout for the SwitchBox UI. Does not download game content.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
import traceback
from pathlib import Path


def emit(payload: dict) -> None:
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def quiet_prints() -> None:
    class _Silent:
        def info(self, *a, **k):
            pass

        def error(self, *a, **k):
            pass

        def warning(self, *a, **k):
            pass

    try:
        import Print  # type: ignore

        Print.info = _Silent().info  # type: ignore
        Print.error = _Silent().error  # type: ignore
        Print.warning = getattr(Print, "warning", _Silent().warning)  # type: ignore
    except Exception:
        pass


def setup_ztools(ztools: Path) -> None:
    ztools = ztools.resolve()
    os.chdir(ztools)
    # NSC_BUILDER imports both top-level and lib/ modules.
    sys.path.insert(0, str(ztools))
    sys.path.insert(0, str(ztools / "lib"))


def sanitize_name(name: str) -> str:
    name = re.sub(r'[\\/:*?"<>|]', "", name)
    name = re.sub(r"\s+", " ", name).strip(" .")
    return name or "Unknown"


def filename_hint(path: str) -> str:
    base = Path(path).stem
    base = re.sub(r"\[[0-9A-Fa-f]{16}\]", "", base)
    base = re.sub(r"\[v?\d+\]", "", base, flags=re.I)
    base = re.sub(r"\[(UPD|DLC|BASE)\]", "", base, flags=re.I)
    return sanitize_name(base) or Path(path).stem


def _iter_ncas(container, is_xci: bool):
    from Fs import Nca  # type: ignore

    if is_xci:
        for nsp_f in container.hfs0:
            if str(nsp_f._path) == "secure":
                for nca in nsp_f:
                    if type(nca) == Nca:
                        yield nca
    else:
        for nca in container:
            if type(nca) == Nca:
                yield nca


def _read_cnmt_from_nca(nca) -> list[dict]:
    from binascii import hexlify as hx  # type: ignore

    results: list[dict] = []
    ctype = str(nca.header.contentType)
    if ctype != "Content.META" and "META" not in ctype.upper():
        return results
    for f in nca:
        for cnmt in f:
            nca.rewind()
            f.rewind()
            cnmt.rewind()
            titleid = cnmt.readInt64()
            titleversion = cnmt.read(0x4)
            cnmt.rewind()
            cnmt.seek(0xE)
            cnmt.readInt16()  # offset
            cnmt.readInt16()  # content_entries
            cnmt.readInt16()  # meta_entries
            content_type = str(cnmt._path)[:-22]
            titleid2 = str(hx(titleid.to_bytes(8, byteorder="big")))[2:-1].upper()
            version = int.from_bytes(titleversion, byteorder="little")
            cnmt.seek(0x20)
            if content_type == "Application":
                base_id = titleid2
                kind = "BASE"
            elif content_type == "Patch":
                original = cnmt.readInt64()
                base_id = str(hx(original.to_bytes(8, byteorder="big")))[2:-1].upper()
                kind = "UPDATE"
            elif content_type == "AddOnContent":
                original = cnmt.readInt64()
                base_id = str(hx(original.to_bytes(8, byteorder="big")))[2:-1].upper()
                kind = "DLC"
            else:
                continue
            results.append(
                {
                    "titleId": titleid2,
                    "baseId": base_id,
                    "version": version,
                    "kind": kind,
                }
            )
    return results


def _control_name(container, is_xci: bool, base_id: str) -> str | None:
    """Best-effort game name from CONTROL NCA / get_title, without titledb."""
    try:
        if not is_xci and hasattr(container, "get_title"):
            name = container.get_title(base_id, roman=True, tag=True)
            if name:
                return str(name)
    except Exception:
        pass
    try:
        from Fs import Nca  # type: ignore

        for nca in _iter_ncas(container, is_xci):
            if str(nca.header.contentType) != "Content.CONTROL" and "CONTROL" not in str(
                nca.header.contentType
            ).upper():
                continue
            title, *_rest = nca.get_langueblock("UNKNOWN", True)
            if title and title != "UNKNOWN":
                return str(title)
    except Exception:
        pass
    return None


def extract_metas(filepath: str) -> list[dict]:
    """Read CNMT entries from a container. Returns list of content dicts."""
    import Fs  # type: ignore

    lower = filepath.lower()
    if lower.endswith((".nsp", ".nsz", ".nsx")):
        container = Fs.Nsp(filepath, "rb")
        is_xci = False
    elif lower.endswith((".xci", ".xcz")):
        container = Fs.factory(filepath)
        container.open(filepath, "rb")
        is_xci = True
    else:
        raise ValueError(f"unsupported extension: {filepath}")

    results: list[dict] = []
    try:
        for nca in _iter_ncas(container, is_xci):
            for meta in _read_cnmt_from_nca(nca):
                meta["file"] = filepath
                results.append(meta)

        base_for_name = next(
            (r["titleId"] for r in results if r["kind"] == "BASE"),
            next(
                (r["baseId"] for r in results if r["kind"] == "UPDATE"),
                results[0]["baseId"] if results else "",
            ),
        )
        name = _control_name(container, is_xci, base_for_name) if base_for_name else None
        if not name:
            name = filename_hint(filepath)
        name = sanitize_name(str(name))
        for r in results:
            r["name"] = name
    finally:
        try:
            container.flush()
            container.close()
        except Exception:
            pass
    return results


def load_versions() -> dict[str, int]:
    import nutdb  # type: ignore

    # nutdb prints progress with builtin print(); keep stdout JSON-clean.
    real_stdout = sys.stdout
    try:
        sys.stdout = sys.stderr
        nutdb.check_other_file(nutdb.urlconfig, "versions_txt")
    finally:
        sys.stdout = real_stdout

    dbfile = os.path.join(nutdb.DATABASE_folder, "nutdb_versions.txt")
    versions: dict[str, int] = {}
    with open(dbfile, "rt", encoding="utf8") as csvfile:
        reader = csv.reader(csvfile, delimiter="|")
        header = next(reader, None)
        if not header or "id" not in header or "version" not in header:
            raise RuntimeError("versions database header missing id/version columns")
        id_i = header.index("id")
        ver_i = header.index("version")
        for row in reader:
            try:
                tid = str(row[id_i]).upper()
                ver_s = str(row[ver_i]).strip()
                if not tid or not ver_s:
                    continue
                versions[tid] = int(ver_s)
            except Exception:
                continue
    return versions


def update_id_for(base_id: str) -> str:
    return base_id[:-3] + "800"


def suggested_update_name(game_name: str, update_id: str, version: int) -> str:
    return f"{sanitize_name(game_name)} [{update_id}][v{version}]"


def collect_files(paths: list[str], recursive: bool) -> list[str]:
    exts = {".nsp", ".nsz", ".xci", ".xcz", ".nsx"}
    out: list[str] = []
    for p in paths:
        path = Path(p)
        if path.is_file() and path.suffix.lower() in exts:
            out.append(str(path.resolve()))
        elif path.is_dir():
            if recursive:
                for root, _, files in os.walk(path):
                    for name in files:
                        if Path(name).suffix.lower() in exts:
                            out.append(str(Path(root, name).resolve()))
            else:
                for child in path.iterdir():
                    if child.is_file() and child.suffix.lower() in exts:
                        out.append(str(child.resolve()))
    # Preserve order, drop dupes
    seen = set()
    unique = []
    for f in out:
        if f not in seen:
            seen.add(f)
            unique.append(f)
    return unique


def main() -> int:
    parser = argparse.ArgumentParser(description="Check local Switch files for missing/outdated updates")
    parser.add_argument("-tfile", help="Text file with one path per line")
    parser.add_argument("paths", nargs="*", help="Files or folders")
    parser.add_argument("--ztools", required=True, help="Path to NSC_BUILDER ztools directory")
    parser.add_argument("--recursive", action="store_true", help="Recurse into folders")
    args = parser.parse_args()

    paths: list[str] = list(args.paths or [])
    if args.tfile:
        with open(args.tfile, "r", encoding="utf8") as fh:
            paths.extend(line.strip() for line in fh if line.strip())

    if not paths:
        emit({"type": "error", "message": "没有要检查的文件"})
        return 1

    setup_ztools(Path(args.ztools))
    quiet_prints()

    files = collect_files(paths, recursive=args.recursive)
    if not files:
        emit({"type": "error", "message": "未找到 NSP / XCI / NSZ / XCZ 文件"})
        return 1

    emit({"type": "status", "message": f"正在刷新版本数据库（titledb）…"})
    try:
        versions = load_versions()
    except Exception as e:
        emit({"type": "error", "message": f"无法获取版本数据库：{e}"})
        traceback.print_exc(file=sys.stderr)
        return 1
    emit({"type": "status", "message": f"版本库已就绪（{len(versions)} 条），开始解析本地文件…"})

    # baseId -> aggregate
    games: dict[str, dict] = {}
    errors = 0

    for i, filepath in enumerate(files):
        emit(
            {
                "type": "progress",
                "percent": (i / max(len(files), 1)) * 100,
                "file": filepath,
                "step": "读取元数据",
            }
        )
        try:
            metas = extract_metas(filepath)
            if not metas:
                emit(
                    {
                        "type": "file_error",
                        "file": filepath,
                        "message": "未找到 CNMT 元数据",
                    }
                )
                errors += 1
                continue
            for meta in metas:
                if meta["kind"] == "DLC":
                    continue
                base = meta["baseId"]
                g = games.setdefault(
                    base,
                    {
                        "baseId": base,
                        "name": meta["name"],
                        "localUpdateVersion": -1,
                        "hasBase": False,
                        "files": [],
                    },
                )
                if meta["name"] and (not g["name"] or g["name"] == "Unknown"):
                    g["name"] = meta["name"]
                if meta["kind"] == "BASE":
                    g["hasBase"] = True
                    if meta["name"]:
                        g["name"] = meta["name"]
                if meta["kind"] == "UPDATE":
                    g["localUpdateVersion"] = max(g["localUpdateVersion"], int(meta["version"]))
                if filepath not in g["files"]:
                    g["files"].append(filepath)
        except Exception as e:
            errors += 1
            emit({"type": "file_error", "file": filepath, "message": str(e)})
            traceback.print_exc(file=sys.stderr)

    emit({"type": "progress", "percent": 100, "step": "对照版本库"})

    missing = outdated = current = unknown = 0
    for base_id, g in sorted(games.items(), key=lambda kv: kv[1]["name"].lower()):
        upd_id = update_id_for(base_id)
        latest = versions.get(upd_id)
        local = g["localUpdateVersion"]
        name = g["name"]

        if latest is None:
            # No update entry in titledb (game never had patches, or DB incomplete).
            status = "no_update_listed"
            unknown += 1
            suggested = ""
            latest_out = None
        elif local < 0:
            status = "missing"
            missing += 1
            suggested = suggested_update_name(name, upd_id, latest)
            latest_out = latest
        elif local < latest:
            status = "outdated"
            outdated += 1
            suggested = suggested_update_name(name, upd_id, latest)
            latest_out = latest
        else:
            status = "current"
            current += 1
            suggested = suggested_update_name(name, upd_id, local if local >= 0 else latest)
            latest_out = latest

        emit(
            {
                "type": "result",
                "status": status,
                "name": name,
                "baseId": base_id,
                "updateId": upd_id,
                "localVersion": None if local < 0 else local,
                "latestVersion": latest_out,
                "suggestedName": suggested,
                "files": g["files"],
            }
        )

    emit(
        {
            "type": "summary",
            "games": len(games),
            "missing": missing,
            "outdated": outdated,
            "current": current,
            "unknown": unknown,
            "errors": errors,
            "files": len(files),
        }
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
