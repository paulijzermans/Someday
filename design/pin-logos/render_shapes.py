"""
Render the five proposed pin-logo shapes for Someday with three different
visual treatments per shape, so we can pick a style before porting to SwiftUI.

Outputs:
  design/pin-logos/grid.png — single side-by-side preview
  design/pin-logos/<shape>.png — individual large versions
"""
from __future__ import annotations
import numpy as np
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection, Line3DCollection
from matplotlib.colors import LinearSegmentedColormap


# --------- Color palettes (per shape) ------------------------------------------------
SHAPE_PALETTE = {
    "tetrahedron":  ("#FF7E42", "#FFB59B"),   # warm coral (food / activity)
    "cone":         ("#FFB343", "#FFE1B0"),   # amber (coffee / treats)
    "octahedron":   ("#4272FF", "#A8B9FF"),   # vivid blue (drinks / cocktails)
    "sphere":       ("#33BB66", "#A8E5C2"),   # accent green (saved / want-to-go)
    "dodecahedron": ("#8A5BFF", "#C6B0FF"),   # purple (travel / discovery)
}


# --------- Geometry helpers --------------------------------------------------------
def tetrahedron_faces():
    s = 1.0
    v = np.array([
        [+s, +s, +s],
        [-s, -s, +s],
        [-s, +s, -s],
        [+s, -s, -s],
    ])
    faces = [(0, 1, 2), (0, 1, 3), (0, 2, 3), (1, 2, 3)]
    return v, faces


def octahedron_faces():
    v = np.array([
        [+1, 0, 0], [-1, 0, 0],
        [0, +1, 0], [0, -1, 0],
        [0, 0, +1], [0, 0, -1],
    ])
    faces = [
        (0, 2, 4), (2, 1, 4), (1, 3, 4), (3, 0, 4),
        (2, 0, 5), (1, 2, 5), (3, 1, 5), (0, 3, 5),
    ]
    return v, faces


def dodecahedron_faces():
    phi = (1 + np.sqrt(5)) / 2
    a, b = 1, 1 / phi
    c = phi
    verts = []
    # (±1, ±1, ±1)
    for x in (-a, a):
        for y in (-a, a):
            for z in (-a, a):
                verts.append([x, y, z])
    # (0, ±1/phi, ±phi)
    for y in (-b, b):
        for z in (-c, c):
            verts.append([0, y, z])
    # (±1/phi, ±phi, 0)
    for x in (-b, b):
        for y in (-c, c):
            verts.append([x, y, 0])
    # (±phi, 0, ±1/phi)
    for x in (-c, c):
        for z in (-b, b):
            verts.append([x, 0, z])
    v = np.array(verts)

    # Faces by selecting coplanar pentagons. Use a deterministic algorithm:
    # for each pair of vertices, gather all that are at the typical edge length,
    # then extract the 12 unique pentagonal faces via face-normal grouping.
    # Simpler: hard-code from a known indexing.
    # Map vertices to integer keys for hard-coded face indices.
    # Using a canonical face list from a known dodecahedron parameterization.
    faces = [
        ( 0,  8, 10,  2, 16),
        ( 0, 16, 17,  1,  9),
        ( 0,  9, 11,  4,  8),
        ( 1, 17,  3, 19,  5),
        ( 1,  5, 13, 12,  9),
        ( 9, 12, 14, 11,  4 if False else 4),
    ]
    # Rather than fight with hand-indexed faces (error-prone), compute faces
    # by greedy detection: find all 5-cycles in the edge graph.
    return v, _compute_dodecahedron_faces(v)


def _compute_dodecahedron_faces(verts: np.ndarray) -> list[tuple[int, ...]]:
    from itertools import combinations
    # Edge length = 2/phi
    phi = (1 + np.sqrt(5)) / 2
    edge_len = 2 / phi
    n = len(verts)
    # build adjacency
    adj: dict[int, set[int]] = {i: set() for i in range(n)}
    for i, j in combinations(range(n), 2):
        d = np.linalg.norm(verts[i] - verts[j])
        if abs(d - edge_len) < 1e-3:
            adj[i].add(j)
            adj[j].add(i)
    # find all 5-cycles by DFS, deduplicated by the (frozen, unordered) vertex set
    faces: dict[frozenset[int], tuple[int, ...]] = {}
    for start in range(n):
        for path in _dfs_cycles(start, 5, adj):
            key = frozenset(path)
            if key in faces:
                continue
            # Order vertices around the face by sorting by angle around centroid.
            centroid = verts[list(path)].astype(float).mean(axis=0)
            p0 = verts[path[0]].astype(float)
            p1 = verts[path[1]].astype(float)
            p2 = verts[path[2]].astype(float)
            normal = np.cross(p1 - p0, p2 - p0)
            normal = normal / np.linalg.norm(normal)
            u = p0 - centroid
            u = u / np.linalg.norm(u)
            w = np.cross(normal, u)
            angles = []
            for p in path:
                vec = verts[p].astype(float) - centroid
                angles.append((float(np.arctan2(np.dot(vec, w), np.dot(vec, u))), p))
            ordered = tuple(p for _, p in sorted(angles))
            faces[key] = ordered
    return list(faces.values())


def _dfs_cycles(start: int, length: int, adj: dict[int, set[int]]):
    """Yield simple cycles of given length starting and ending at `start`."""
    def helper(path: list[int]):
        if len(path) == length:
            if start in adj[path[-1]] and len(set(path)) == length:
                yield tuple(path)
            return
        for nxt in adj[path[-1]]:
            if nxt not in path:
                yield from helper(path + [nxt])
    yield from helper([start])


def sphere_surface(res: int = 40):
    u = np.linspace(0, 2 * np.pi, res)
    v = np.linspace(0, np.pi, res)
    x = np.outer(np.cos(u), np.sin(v))
    y = np.outer(np.sin(u), np.sin(v))
    z = np.outer(np.ones_like(u), np.cos(v))
    return x, y, z


def cone_surface(res: int = 40, height: float = 1.6, radius: float = 1.0):
    # Apex at top, circular base at z = -height/2
    theta = np.linspace(0, 2 * np.pi, res)
    z = np.linspace(-height / 2, height / 2, res)
    Z, T = np.meshgrid(z, theta)
    # Radius linearly tapers from 'radius' at the base to 0 at the apex.
    R = radius * (1 - (Z - (-height / 2)) / height)
    X = R * np.cos(T)
    Y = R * np.sin(T)
    return X, Y, Z


# --------- Rendering helpers --------------------------------------------------------
def _light_for_face(verts: np.ndarray, face: tuple[int, ...], light_dir: np.ndarray) -> float:
    """Lambertian shading value in [0,1] for a polygon face."""
    p0 = verts[face[0]].astype(float)
    p1 = verts[face[1]].astype(float)
    p2 = verts[face[2]].astype(float)
    normal = np.cross(p1 - p0, p2 - p0)
    n = float(np.linalg.norm(normal))
    if n == 0:
        return 0.5
    normal = normal / n
    return max(0.05, float(np.dot(normal, light_dir)))


def _make_gradient_colors(base_hex: str, light_hex: str, n: int = 100) -> np.ndarray:
    cmap = LinearSegmentedColormap.from_list("g", [base_hex, light_hex])
    return cmap(np.linspace(0, 1, n))


def render_polyhedron(ax, verts: np.ndarray, faces, base_hex: str, light_hex: str,
                      *, edge: str = "#0F1B33", edge_width: float = 1.2):
    light_dir = np.array([0.4, 0.2, 1.0])
    light_dir = light_dir / np.linalg.norm(light_dir)
    palette = _make_gradient_colors(base_hex, light_hex, 100)

    polys = []
    colors = []
    for face in faces:
        face_verts = [verts[i] for i in face]
        polys.append(face_verts)
        shade = _light_for_face(verts, face, light_dir)
        idx = int(np.clip(shade, 0, 1) * (len(palette) - 1))
        colors.append(palette[idx])

    coll = Poly3DCollection(polys, facecolors=colors, edgecolor=edge, linewidths=edge_width)
    ax.add_collection3d(coll)


def render_sphere(ax, base_hex: str, light_hex: str):
    x, y, z = sphere_surface(res=60)
    # Shade by z (top brighter).
    palette = _make_gradient_colors(base_hex, light_hex, 256)
    norm = (z - z.min()) / (z.max() - z.min())
    facecolors = palette[(norm * 255).astype(int)]
    ax.plot_surface(
        x, y, z, rstride=1, cstride=1,
        facecolors=facecolors, linewidth=0, antialiased=True, shade=False,
    )


def render_cone(ax, base_hex: str, light_hex: str):
    X, Y, Z = cone_surface(res=80)
    palette = _make_gradient_colors(base_hex, light_hex, 256)
    norm = (Z - Z.min()) / (Z.max() - Z.min())
    facecolors = palette[(norm * 255).astype(int)]
    ax.plot_surface(
        X, Y, Z, rstride=1, cstride=1,
        facecolors=facecolors, linewidth=0, antialiased=True, shade=False,
    )


# --------- Axes utilities ----------------------------------------------------------
def _setup_axes(ax, lim: float = 1.4):
    ax.set_box_aspect((1, 1, 1))
    ax.set_xlim(-lim, lim)
    ax.set_ylim(-lim, lim)
    ax.set_zlim(-lim, lim)
    ax.set_axis_off()
    # Soft viewpoint that flatters polyhedra: slight tilt, slight rotation.
    ax.view_init(elev=22, azim=35)


def draw_shape(ax, shape: str):
    base, light = SHAPE_PALETTE[shape]
    if shape == "tetrahedron":
        v, f = tetrahedron_faces()
        render_polyhedron(ax, v, f, base, light)
        _setup_axes(ax, lim=1.2)
    elif shape == "octahedron":
        v, f = octahedron_faces()
        render_polyhedron(ax, v, f, base, light)
        _setup_axes(ax, lim=1.1)
    elif shape == "dodecahedron":
        v, f = dodecahedron_faces()
        # Faces don't tile if cycle detection found != 12 faces; warn.
        if len(f) != 12:
            print(f"  ! Dodecahedron face count = {len(f)}, expected 12")
        render_polyhedron(ax, v, f, base, light)
        _setup_axes(ax, lim=1.6)
    elif shape == "sphere":
        render_sphere(ax, base, light)
        _setup_axes(ax, lim=1.1)
    elif shape == "cone":
        render_cone(ax, base, light)
        _setup_axes(ax, lim=1.1)


# --------- Driver ------------------------------------------------------------------
SHAPES = ["tetrahedron", "cone", "octahedron", "sphere", "dodecahedron"]


def render_grid(path: str):
    fig = plt.figure(figsize=(15, 4), dpi=140, facecolor="white")
    for i, shape in enumerate(SHAPES, 1):
        ax = fig.add_subplot(1, 5, i, projection="3d")
        draw_shape(ax, shape)
        ax.set_title(shape.capitalize(), fontsize=14, weight="bold", pad=6, color="#0F1B33")
    fig.subplots_adjust(left=0.01, right=0.99, top=0.92, bottom=0.02, wspace=-0.05)
    fig.savefig(path, dpi=140, facecolor="white", bbox_inches="tight")
    plt.close(fig)


def render_individual(folder: str):
    for shape in SHAPES:
        fig = plt.figure(figsize=(4, 4), dpi=200, facecolor="white")
        ax = fig.add_subplot(111, projection="3d")
        draw_shape(ax, shape)
        fig.subplots_adjust(left=0, right=1, top=1, bottom=0)
        fig.savefig(f"{folder}/{shape}.png", dpi=200, facecolor="white", bbox_inches="tight")
        plt.close(fig)


if __name__ == "__main__":
    render_grid("design/pin-logos/grid.png")
    render_individual("design/pin-logos")
    print("Done.")
