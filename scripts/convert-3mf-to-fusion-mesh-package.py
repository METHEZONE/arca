#!/usr/bin/env python3
import math
import os
import struct
import sys
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

CORE = "{http://schemas.microsoft.com/3dmanufacturing/core/2015/02}"
PROD = "{http://schemas.microsoft.com/3dmanufacturing/production/2015/06}"


def parse_transform(value):
    if not value:
        return (1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0)
    values = tuple(float(x) for x in value.split())
    if len(values) != 12:
        raise ValueError(f"Expected 12 transform values, got {len(values)}: {value}")
    return values


def transform_point(t, p):
    a, b, c, d, e, f, g, h, i, j, k, l = t
    x, y, z = p
    return (
        a * x + d * y + g * z + j,
        b * x + e * y + h * z + k,
        c * x + f * y + i * z + l,
    )


def compose(left, right):
    basis = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (0, 0, 0)]
    mapped = [transform_point(left, transform_point(right, p)) for p in basis]
    origin = mapped[3]
    x_axis = tuple(mapped[0][n] - origin[n] for n in range(3))
    y_axis = tuple(mapped[1][n] - origin[n] for n in range(3))
    z_axis = tuple(mapped[2][n] - origin[n] for n in range(3))
    return (
        x_axis[0], x_axis[1], x_axis[2],
        y_axis[0], y_axis[1], y_axis[2],
        z_axis[0], z_axis[1], z_axis[2],
        origin[0], origin[1], origin[2],
    )


def normal(a, b, c):
    ux, uy, uz = (b[0] - a[0], b[1] - a[1], b[2] - a[2])
    vx, vy, vz = (c[0] - a[0], c[1] - a[1], c[2] - a[2])
    nx, ny, nz = (uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx)
    length = math.sqrt(nx * nx + ny * ny + nz * nz) or 1.0
    return (nx / length, ny / length, nz / length)


def read_models(path):
    models = {}
    with zipfile.ZipFile(path) as zf:
        for name in zf.namelist():
            if name.startswith("3D/") and name.endswith(".model"):
                xml = ET.fromstring(zf.read(name))
                objects = {}
                for obj in xml.findall(f".//{CORE}object"):
                    oid = obj.attrib["id"]
                    mesh = obj.find(f"{CORE}mesh")
                    components = obj.find(f"{CORE}components")
                    if mesh is not None:
                        vertices = [
                            (
                                float(v.attrib["x"]),
                                float(v.attrib["y"]),
                                float(v.attrib["z"]),
                            )
                            for v in mesh.findall(f".//{CORE}vertex")
                        ]
                        triangles = [
                            (
                                int(t.attrib["v1"]),
                                int(t.attrib["v2"]),
                                int(t.attrib["v3"]),
                            )
                            for t in mesh.findall(f".//{CORE}triangle")
                        ]
                        objects[oid] = {
                            "type": "mesh",
                            "vertices": vertices,
                            "triangles": triangles,
                            "name": obj.attrib.get("name") or f"object_{oid}",
                        }
                    elif components is not None:
                        objects[oid] = {
                            "type": "components",
                            "components": [
                                {
                                    "objectid": c.attrib["objectid"],
                                    "path": c.attrib.get(f"{PROD}path"),
                                    "transform": parse_transform(c.attrib.get("transform")),
                                }
                                for c in components.findall(f"{CORE}component")
                            ],
                            "name": obj.attrib.get("name") or f"assembly_{oid}",
                        }
                build = [
                    {
                        "objectid": item.attrib["objectid"],
                        "transform": parse_transform(item.attrib.get("transform")),
                        "printable": item.attrib.get("printable", "1") != "0",
                    }
                    for item in xml.findall(f".//{CORE}build/{CORE}item")
                ]
                models["/" + name] = {"objects": objects, "build": build}
                models[name] = models["/" + name]
    return models


def resolve_object(models, model_path, objectid, transform):
    model = models[model_path]
    obj = model["objects"][objectid]
    if obj["type"] == "mesh":
        verts = [transform_point(transform, p) for p in obj["vertices"]]
        return [(obj["name"], verts, obj["triangles"])]
    parts = []
    base_dir = "/" + "/".join(model_path.strip("/").split("/")[:-1])
    for component in obj["components"]:
        child_path = component["path"]
        if child_path is None:
            child_model_path = model_path
        elif child_path.startswith("/"):
            child_model_path = child_path
        else:
            child_model_path = f"{base_dir}/{child_path}".replace("//", "/")
        child_transform = compose(transform, component["transform"])
        parts.extend(resolve_object(models, child_model_path, component["objectid"], child_transform))
    return parts


def write_binary_stl(path, parts):
    triangles = []
    for _, vertices, faces in parts:
        for face in faces:
            a, b, c = (vertices[face[0]], vertices[face[1]], vertices[face[2]])
            triangles.append((normal(a, b, c), a, b, c))
    with open(path, "wb") as f:
        f.write(b"ARCA 3MF mesh conversion".ljust(80, b"\0"))
        f.write(struct.pack("<I", len(triangles)))
        for n, a, b, c in triangles:
            f.write(struct.pack("<12fH", *(n + a + b + c), 0))


def write_obj(path, parts):
    with open(path, "w", encoding="utf-8") as f:
        f.write("# ARCA 3MF mesh conversion for Fusion import\n")
        offset = 1
        for name, vertices, faces in parts:
            f.write(f"o {name}\n")
            for x, y, z in vertices:
                f.write(f"v {x:.6f} {y:.6f} {z:.6f}\n")
            for a, b, c in faces:
                f.write(f"f {a + offset} {b + offset} {c + offset}\n")
            offset += len(vertices)


def convert(src, out_root):
    slug = Path(src).stem.replace(" ", "_").replace("(", "").replace(")", "")
    out_dir = Path(out_root) / slug
    stl_dir = out_dir / "stl_parts"
    out_dir.mkdir(parents=True, exist_ok=True)
    stl_dir.mkdir(parents=True, exist_ok=True)

    models = read_models(src)
    root_path = "/3D/3dmodel.model"
    build = models[root_path]["build"]
    all_parts = []
    manifest = []
    for index, item in enumerate(build, start=1):
        if not item["printable"]:
            continue
        parts = resolve_object(models, root_path, item["objectid"], item["transform"])
        all_parts.extend((f"plate_{index}_{name}", verts, faces) for name, verts, faces in parts)
        for part_index, (name, verts, faces) in enumerate(parts, start=1):
            part_slug = f"plate_{index:02d}_part_{part_index:02d}_{name}".replace("/", "_")
            write_binary_stl(stl_dir / f"{part_slug}.stl", [(part_slug, verts, faces)])
            manifest.append((part_slug, len(verts), len(faces)))

    write_binary_stl(out_dir / f"{slug}_combined.stl", all_parts)
    write_obj(out_dir / f"{slug}_combined.obj", all_parts)
    with open(out_dir / "README_FUSION_IMPORT.txt", "w", encoding="utf-8") as f:
        f.write(
            "Fusion import package generated from 3MF mesh data.\n\n"
            "Autodesk .f3d/.f3z is proprietary and cannot be authored directly without Fusion 360.\n"
            "Open Fusion 360, upload/import the combined OBJ or STL, then Save As / Export to F3D or F3Z.\n"
            "For editability, use Mesh > Modify > Convert Mesh after import.\n\n"
            "Files:\n"
            f"- {slug}_combined.obj: preserves separate object names in one importable mesh file.\n"
            f"- {slug}_combined.stl: combined printable mesh.\n"
            "- stl_parts/*.stl: individual printable parts.\n\n"
            "Parts:\n"
        )
        for part_slug, verts, faces in manifest:
            f.write(f"- {part_slug}: {verts} vertices, {faces} triangles\n")
    return out_dir


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: convert-3mf-to-fusion-mesh-package.py OUT_DIR FILE.3MF [FILE.3MF ...]")
    out_root = sys.argv[1]
    for src in sys.argv[2:]:
        out = convert(src, out_root)
        print(out)


if __name__ == "__main__":
    main()
