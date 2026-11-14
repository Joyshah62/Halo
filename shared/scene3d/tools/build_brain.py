"""Builds Halo's 3D brain from the BodyParts3D anatomical atlas.

Source meshes: BodyParts3D 3.0 (https://lifesciencedb.jp/bp3d/), (c) The Database Center for Life Science,
licensed under CC Attribution-Share Alike 2.1 Japan. One STL per anatomical structure, in millimetres.

    uv venv .venv && uv pip install --python .venv/bin/python numpy trimesh fast-simplification embreex
    .venv/bin/python build_brain.py <dir with FMA*.stl> ../brain-data.js

Each structure is simplified, grouped into the parts a student can touch (see PARTS, which must match
catalog.json), and given baked ambient occlusion so the folds read without any real-time shadowing.
The result is one gzipped binary, written as a script so it loads from file:// and extension pages alike.
"""
import base64, gzip, json, struct, sys
from pathlib import Path
import numpy as np, trimesh, fast_simplification
from trimesh.ray.ray_pyembree import RayMeshIntersector

# part id -> (layer, keep ratio, [BodyParts3D ids]). Layers: "cortex" is what you see from outside,
# "stem" the cerebellum and brainstem, "deep" everything the cortex hides.
PARTS = {
    "frontal": ("cortex", 0.30, ["FMA72653", "FMA72654", "FMA72655", "FMA72656", "FMA72701", "FMA72702", "BP51"]),
    "motor": ("cortex", 0.30, ["FMA72661", "FMA72662"]),
    "somatosensory": ("cortex", 0.30, ["FMA72665", "FMA72666"]),
    "parietal": ("cortex", 0.30, ["FMA72667", "FMA72668", "FMA72669", "FMA72670", "BP49", "BP50"]),
    "temporal": ("cortex", 0.30, ["FMA72685", "FMA72686", "FMA72687", "FMA72688", "FMA72689", "FMA72690",
                                  "FMA72800", "FMA72801", "FMA72804", "FMA72805", "FMA72705", "FMA72706"]),
    "occipital": ("cortex", 0.30, ["FMA72975", "FMA72976"]),
    "cingulate": ("cortex", 0.30, ["FMA72717", "FMA72718"]),
    "insula": ("deep", 0.25, ["FMA72977", "FMA72978"]),
    "cerebellum": ("stem", 0.22, ["FMA67944"]),
    "midbrain": ("stem", 0.07, ["FMA61993nsn", "FMA62394", "FMA73422", "FMA73423", "FMA73434", "FMA73435"]),
    "pons": ("stem", 0.07, ["FMA67943"]),
    "medulla": ("stem", 0.08, ["FMA62004"]),
    "corpus-callosum": ("deep", 0.07, ["FMA86464"]),
    "thalamus": ("deep", 0.5, ["FMA258714", "FMA258716", "FMA73303", "FMA73304", "FMA73309", "FMA73310"]),
    "hypothalamus": ("deep", 0.15, ["FMA62008nsn", "FMA62327", "FMA74877"]),
    "pituitary": ("stem", 0.3, ["FMA13889"]),
    "pineal": ("deep", 0.6, ["FMA62033", "FMA62032"]),
    "hippocampus": ("deep", 0.7, ["FMA72713", "FMA72714"]),
    "amygdala": ("deep", 1.0, ["FMA72832", "FMA72833"]),
    "fornix": ("deep", 0.07, ["FMA72924", "FMA72925", "FMA61970"]),
    "caudate": ("deep", 0.25, ["FMA72826", "FMA72827"]),
    "putamen": ("deep", 0.08, ["FMA72828", "FMA72829"]),
    "globus-pallidus": ("deep", 0.08, ["FMA72830", "FMA72831"]),
    "ventricles": ("deep", 0.05, ["FMA78449", "FMA78450", "FMA78454", "FMA78467", "FMA78469"]),
    "optic": ("stem", 0.2, ["FMA50875", "FMA50878", "FMA62045", "FMA62382", "FMA67936"]),
}
NAMES = {}  # filled from the STL folder's parts list when present


def to_scene(v):
    """BodyParts3D: x toward the left ear, y toward the back of the head, z up. Scene: y up, face toward +z."""
    return np.column_stack([v[:, 0], v[:, 2], -v[:, 1]])


def outer_shell(mesh):
    """Some atlas meshes carry a second copy of their surface just inside the first, plus stray specks. Keep the outside."""
    pieces = mesh.split(only_watertight=False)
    if len(pieces) < 2:
        return mesh
    pieces = sorted(pieces, key=lambda m: -np.prod(m.extents))
    kept = [pieces[0]]
    for other in pieces[1:]:
        inside = all((other.bounds[0] >= k.bounds[0] - 0.5).all() and (other.bounds[1] <= k.bounds[1] + 0.5).all() for k in kept[:1])
        if not inside and len(other.faces) >= 100:
            kept.append(other)
    return trimesh.util.concatenate(kept) if len(kept) > 1 else kept[0]


def soften(mesh, rounds=3):
    """A light Taubin pass: takes the faceting off without shrinking the shape."""
    v = np.asarray(mesh.vertices, dtype=np.float64).copy()
    edges = mesh.edges_unique
    count = np.zeros(len(v)); np.add.at(count, edges[:, 0], 1); np.add.at(count, edges[:, 1], 1)
    count = np.maximum(count, 1)[:, None]
    for _ in range(rounds):
        for step in (0.5, -0.53):
            total = np.zeros_like(v)
            np.add.at(total, edges[:, 0], v[edges[:, 1]]); np.add.at(total, edges[:, 1], v[edges[:, 0]])
            v += step * (total / count - v)
    mesh.vertices = v


def hemisphere_rays(normals, count, rng):
    """Cosine-weighted directions around each normal."""
    u, w = rng.random((len(normals), count)), rng.random((len(normals), count))
    r, phi = np.sqrt(u), 2 * np.pi * w
    helper = np.where(np.abs(normals[:, :1]) < 0.9, [[1.0, 0, 0]], [[0, 1.0, 0]])
    t = np.cross(normals, helper); t /= np.linalg.norm(t, axis=1, keepdims=True)
    b = np.cross(normals, t)
    return (t[:, None] * (r * np.cos(phi))[..., None] + b[:, None] * (r * np.sin(phi))[..., None]
            + normals[:, None] * np.sqrt(1 - u)[..., None])


def occlusion(mesh, occluder, reach, rays=40, seed=7):
    """0 (open) to 1 (buried) per vertex: how much of the sky within `reach` mm is blocked."""
    rng = np.random.default_rng(seed)
    n = np.asarray(mesh.vertex_normals); v = np.asarray(mesh.vertices)
    d = hemisphere_rays(n, rays, rng).reshape(-1, 3)
    o = np.repeat(v + n * 0.15, rays, axis=0)
    hit = np.zeros(len(o))
    locations, index_ray, _ = occluder.intersects_location(o, d, multiple_hits=False)
    distance = np.linalg.norm(locations - o[index_ray], axis=1)
    hit[index_ray] = np.clip(1 - distance / reach, 0, 1)
    ao = hit.reshape(len(v), rays).mean(axis=1)
    # One pass of neighbour averaging hides ray noise.
    edges = mesh.edges_unique
    total, weight = ao.copy(), np.ones(len(v))
    np.add.at(total, edges[:, 0], ao[edges[:, 1]]); np.add.at(total, edges[:, 1], ao[edges[:, 0]])
    np.add.at(weight, edges[:, 0], 1); np.add.at(weight, edges[:, 1], 1)
    return total / weight


def main(source, out):
    source = Path(source)
    loaded = {}
    for part, (layer, keep, ids) in PARTS.items():
        for bp in ids:
            mesh = outer_shell(trimesh.load(source / f"{bp}.stl", process=True))
            mesh.vertices = to_scene(np.asarray(mesh.vertices))
            loaded[bp] = mesh
    surface = trimesh.util.concatenate([loaded[bp] for part, (layer, _, ids) in PARTS.items() if layer != "deep" for bp in ids])
    low, high = surface.bounds
    centre = (low + high) / 2
    surface_rays = RayMeshIntersector(surface)

    meshes, blobs = [], []
    for part, (layer, keep, ids) in PARTS.items():
        sides = {}
        for bp in ids:
            mesh = loaded[bp]
            # Paired structures stay separate so the two halves can be pulled apart.
            x = mesh.bounds.mean(axis=0)[0] - centre[0]
            span = mesh.extents[0]
            side = "M" if abs(x) < 0.2 * span else ("L" if x > 0 else "R")
            target = max(min(len(mesh.faces), 500), int(len(mesh.faces) * keep))
            if target < len(mesh.faces):
                v, f = fast_simplification.simplify(np.asarray(mesh.vertices, np.float32), np.asarray(mesh.faces), target_count=target, agg=5)
                small = trimesh.Trimesh(v, f, process=True)
            else:
                small = mesh.copy()
            soften(small)
            if layer == "deep":
                ao = occlusion(small, RayMeshIntersector(mesh), reach=5) * 0.7
            else:
                # Tight creases (the grooves between folds) plus the broad shade under and between the lobes.
                fine, broad = occlusion(small, surface_rays, reach=4), occlusion(small, surface_rays, reach=16, seed=11)
                ao = 1 - (1 - fine) * (1 - 0.75 * broad)
            small.metadata["ao"] = ao
            sides.setdefault(side, []).append(small)
        for side, group in sorted(sides.items()):
            v = np.concatenate([m.vertices for m in group])
            offsets = np.cumsum([0] + [len(m.vertices) for m in group[:-1]])
            f = np.concatenate([m.faces + o for m, o in zip(group, offsets)])
            ao = np.concatenate([m.metadata["ao"] for m in group])
            areas = np.concatenate([m.area_faces for m in group])
            centroids = np.concatenate([m.triangles_center for m in group])
            middle = (centroids * areas[:, None]).sum(axis=0) / areas.sum()
            meshes.append((part, layer, side, v, f, ao, middle))
            print(f"{part:16s} {side} {layer:6s} {len(v):6d} vertices {len(f):6d} triangles")

    size = float((high - low).max())
    quantum = 60000          # leaves headroom: smoothing can nudge a vertex just past the measured bounds
    header = {"unit": "mm", "size": size, "quantum": quantum, "meshes": []}
    for part, layer, side, v, f, ao, middle in meshes:
        q = np.clip(np.round((v - centre) / size * quantum), -32767, 32767).astype("<i2")          # the brain spans roughly ±0.5
        wide = len(v) > 65535
        index = f.astype("<u4" if wide else "<u2").tobytes()
        shade = np.round(np.clip(1 - ao, 0, 1) * 255).astype("u1").tobytes()
        header["meshes"].append({"part": part, "layer": layer, "side": side, "vertices": len(v), "indices": int(f.size),
                                 "wide": wide, "centre": [round(float(c), 5) for c in (middle - centre) / size]})
        for chunk in (q.tobytes(), index, shade):
            blobs.append(chunk + b"\0" * (-len(chunk) % 4))
    head = json.dumps(header, separators=(",", ":")).encode()
    head += b" " * (-len(head) % 4)
    packed = gzip.compress(struct.pack("<I", len(head)) + head + b"".join(blobs), 9, mtime=0)
    text = ("// Brain geometry derived from BodyParts3D, (c) The Database Center for Life Science, licensed under\n"
            "// CC Attribution-Share Alike 2.1 Japan. Simplified and regrouped for Halo; see tools/build_brain.py.\n"
            f'self.HALO_BRAIN="{base64.b64encode(packed).decode()}";\n')
    Path(out).write_text(text)
    triangles = sum(len(m[4]) for m in meshes)
    print(f"{len(meshes)} meshes, {triangles} triangles, {len(packed) / 1e6:.2f} MB gzipped, {len(text) / 1e6:.2f} MB script")


if __name__ == "__main__":
    main(*sys.argv[1:3])
