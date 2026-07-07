"""
ARCA Desk Buddy V0  —  Blender 5 / 4.x Python Generator
=========================================================
Outputs:
  stl/arca_desk_base_bottom.stl
  stl/arca_desk_base_lid.stl
  stl/arca_oled_bezel_adapter.stl
  arca_render.png

CLI:
  /Applications/Blender.app/Contents/MacOS/blender \\
    --background --python arca_desk_buddy_v0.py

Or paste into Blender's Scripting tab and click Run.
"""

import bpy, math, os, sys

# ─── Output paths ──────────────────────────────────────────────────────────────
try:
    SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
except NameError:
    SCRIPT_DIR = bpy.path.abspath("//") or os.path.expanduser("~/Desktop")

STL_DIR     = os.path.join(SCRIPT_DIR, "stl")
RENDER_PATH = os.path.join(SCRIPT_DIR, "arca_render.png")
os.makedirs(STL_DIR, exist_ok=True)

# ─── Dimensions (all in mm, treated as raw Blender units) ─────────────────────
BASE_W  = 105.0   # width  X
BASE_D  = 75.0    # depth  Y
BASE_H  = 24.0    # height Z
WALL    = 2.0
BEVEL_R = 3.0
EPS     = 0.6     # boolean cutter overlap

ESP_W, ESP_D, ESP_H = 60.0, 32.0, 12.0   # ESP32-S3 DevKitC-1
SD_W,  SD_D,  SD_H  = 28.0, 25.0, 8.0    # microSD module
USB_W, USB_H        = 12.0, 6.0           # USB-C slot
CABLE_W, CABLE_H    = 10.0, 8.0           # cable passthrough
BTN_R               = 5.0                 # 10 mm tactile button
MIC_R               = 0.75               # 1.5 mm dia mic hole

LID_H     = 3.0
LID_LIP_H = 5.0
LID_LIP_T = 1.8   # lip wall thickness

BZL_W      = 38.0   # bezel outer
BZL_D      = 28.0
BZL_T      = 2.0
BZL_WIN_W  = 24.0   # OLED active area window
BZL_WIN_H  = 13.0
BZL_SCREW  = 0.9    # M2 screw hole radius


# ─── Primitive helpers ────────────────────────────────────────────────────────

def deselect():
    bpy.ops.object.select_all(action='DESELECT')

def clear_scene():
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete()
    for col in [bpy.data.meshes, bpy.data.materials]:
        for b in list(col):
            col.remove(b)

def activate(obj):
    deselect()
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)

def box(name, w, d, h, cx=0.0, cy=0.0, cz=0.0):
    """Axis-aligned box, center at (cx,cy,cz), dims in mm."""
    bpy.ops.mesh.primitive_cube_add(size=1, location=(cx, cy, cz))
    o = bpy.context.active_object
    o.name = name
    o.scale = (w, d, h)
    activate(o)
    bpy.ops.object.transform_apply(scale=True)
    return o

def cyl(name, r, h, cx=0.0, cy=0.0, cz=0.0,
        rx=0.0, ry=0.0, rz=0.0, v=32):
    """Cylinder, center at (cx,cy,cz), optional rotation in degrees."""
    bpy.ops.mesh.primitive_cylinder_add(
        radius=r, depth=h, vertices=v,
        location=(cx, cy, cz),
        rotation=(math.radians(rx), math.radians(ry), math.radians(rz)))
    o = bpy.context.active_object
    o.name = name
    return o

def _bool_op(target, other, op):
    activate(target)
    mod = target.modifiers.new("_b", 'BOOLEAN')
    mod.operation = op
    mod.object    = other
    mod.solver    = 'EXACT'
    try:
        mod.use_hole_tolerant = True
    except Exception:
        pass
    try:
        bpy.ops.object.modifier_apply(modifier="_b")
    except Exception as e:
        print(f"[WARN] bool {op} '{other.name}' → '{target.name}': {e}")
        target.modifiers.remove(mod)
    bpy.data.objects.remove(other, do_unlink=True)

def sub(target, cutter):
    _bool_op(target, cutter, 'DIFFERENCE')

def uni(target, other):
    _bool_op(target, other, 'UNION')

def bevel(obj, r=BEVEL_R, segs=4, angle=70):
    activate(obj)
    bev = obj.modifiers.new("bev", 'BEVEL')
    bev.width        = r
    bev.segments     = segs
    bev.limit_method  = 'ANGLE'
    bev.angle_limit   = math.radians(angle)
    bpy.ops.object.modifier_apply(modifier="bev")

def export_stl(obj, fname):
    fp = os.path.join(STL_DIR, fname)
    deselect()
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    # Blender 4+ uses wm.stl_export; 3.x uses export_mesh.stl
    if bpy.app.version >= (4, 0, 0):
        bpy.ops.wm.stl_export(
            filepath=fp,
            export_selected_objects=True,
            global_scale=1.0,
            ascii_format=False,
        )
    else:
        bpy.ops.export_mesh.stl(
            filepath=fp,
            use_selection=True,
            global_scale=1.0,
        )
    print(f"[ARCA] ✓  stl/{fname}")


# ─── BASE BOTTOM ──────────────────────────────────────────────────────────────

def build_bottom():
    # 1 ── Outer shell, bottom at z=0
    shell = box("shell", BASE_W, BASE_D, BASE_H, cz=BASE_H/2)
    bevel(shell)

    # 2 ── Main inner cavity (open top, 2 mm floor + 2 mm walls)
    cav_h  = BASE_H - WALL + EPS
    cav_cz = WALL + cav_h / 2
    sub(shell, box("cav",
        BASE_W - 2*WALL,
        BASE_D - 2*WALL,
        cav_h,
        cz=cav_cz))

    # 3 ── ESP32-S3 DevKitC-1 pocket (centred X, flush to rear wall)
    #       USB-C ports face the rear (-Y) so they align with the rear slot.
    esp_cy = -(BASE_D/2 - WALL - ESP_D/2)   # = -19.5
    esp_cz =   WALL + ESP_H/2               # sits on cavity floor
    sub(shell, box("esp32",
        ESP_W + EPS, ESP_D + EPS, ESP_H + EPS,
        cy=esp_cy, cz=esp_cz))

    # 4 ── microSD module pocket (front-right corner)
    sd_cx =  BASE_W/2 - WALL - SD_W/2 - 2
    sd_cy =  BASE_D/2 - WALL - SD_D/2 - 2
    sd_cz =  WALL + SD_H/2
    sub(shell, box("sd",
        SD_W + EPS, SD_D + EPS, SD_H + EPS,
        cx=sd_cx, cy=sd_cy, cz=sd_cz))

    # 5 ── USB-C port slot through rear wall, centred on ESP32 footprint
    usb_cz = WALL + 5.0 + USB_H / 2   # 5 mm above cavity floor
    sub(shell, box("usb",
        USB_W, WALL + 2*EPS, USB_H,
        cy=-(BASE_D/2), cz=usb_cz))

    # 6 ── Cable channel notch (front wall, near top) for OLED + mic wires
    cc_cz = BASE_H - CABLE_H / 2
    sub(shell, box("cable_ch",
        CABLE_W, WALL + 2*EPS, CABLE_H,
        cy=BASE_D/2, cz=cc_cz))

    # 7 ── Tactile button hole (right side wall, mid-height)
    #       ry=90 → cylinder axis along +X
    sub(shell, cyl("btn", BTN_R, WALL + 2*EPS,
        cx=BASE_W/2, cz=BASE_H/2, ry=90))

    # 8 ── Mic hole through front wall, top area (1.5 mm dia)
    #       rx=90 → cylinder axis along +Y
    sub(shell, cyl("mic", MIC_R, WALL + 2*EPS,
        cx=8, cy=BASE_D/2, cz=BASE_H - 5,
        rx=90, v=16))

    # 9 ── M3 screw bosses (four inner corners, 6 mm OD, 3 mm ID)
    boss_cz = WALL + 8.0 / 2
    for i, (sx, sy) in enumerate([(-1,-1),(1,-1),(-1,1),(1,1)]):
        bx = sx * (BASE_W/2 - WALL - 5)
        by = sy * (BASE_D/2 - WALL - 5)
        post = cyl(f"boss_{i}", 3.0, 8.0, cx=bx, cy=by, cz=boss_cz, v=20)
        uni(shell, post)
        sub(shell, cyl(f"boss_h_{i}", 1.5, 8.0 + EPS,
            cx=bx, cy=by, cz=boss_cz, v=20))

    shell.name = "arca_base_bottom"
    return shell


# ─── LID ──────────────────────────────────────────────────────────────────────

def build_lid():
    # Lid plate, bottom face at z=0 → print this face-down
    lid = box("lid", BASE_W, BASE_D, LID_H, cz=LID_H/2)
    bevel(lid)

    # Snap lip extends downward (into base cavity) for alignment
    lip_ow = BASE_W - 2*WALL - 0.4   # 0.2 mm clearance per side
    lip_od = BASE_D - 2*WALL - 0.4
    lip_iw = lip_ow - 2*LID_LIP_T
    lip_id = lip_od - 2*LID_LIP_T
    lip_cz = -(LID_LIP_H / 2)

    lip_o = box("lip_out", lip_ow, lip_od, LID_LIP_H, cz=lip_cz)
    sub(lip_o, box("lip_in",
        lip_iw, lip_id, LID_LIP_H + EPS, cz=lip_cz))
    uni(lid, lip_o)

    # Cable slot matches base front-wall notch
    sub(lid, box("lid_cc",
        CABLE_W, WALL + 2*EPS, CABLE_H + LID_H,
        cy=BASE_D/2, cz=-(CABLE_H/2)))

    # M3 clearance holes (match boss positions)
    for i, (sx, sy) in enumerate([(-1,-1),(1,-1),(-1,1),(1,1)]):
        bx = sx * (BASE_W/2 - WALL - 5)
        by = sy * (BASE_D/2 - WALL - 5)
        sub(lid, cyl(f"lid_h_{i}", 1.7, LID_H + EPS,
            cx=bx, cy=by, cz=LID_H/2, v=20))

    lid.name = "arca_lid"
    return lid


# ─── OLED BEZEL ───────────────────────────────────────────────────────────────

def build_bezel():
    # Flat frame for 128×64 I2C OLED behind Mochi face window
    frame = box("bzl", BZL_W, BZL_D, BZL_T, cz=BZL_T/2)
    bevel(frame, r=1.0, segs=3)

    # Display window cutout (128×64 OLED active area ≈ 24×13 mm)
    sub(frame, box("win", BZL_WIN_W, BZL_WIN_H, BZL_T + EPS, cz=BZL_T/2))

    # M2 screw holes at four corners
    for sx, sy in [(-1,-1),(1,-1),(-1,1),(1,1)]:
        bx = sx * (BZL_W/2 - 3)
        by = sy * (BZL_D/2 - 3)
        sub(frame, cyl("bzl_sc", BZL_SCREW, BZL_T + EPS,
            cx=bx, cy=by, cz=BZL_T/2, v=16))

    frame.name = "arca_oled_bezel"
    return frame


# ─── RENDER SCENE ─────────────────────────────────────────────────────────────

def _make_pla_mat(name, r, g, b):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    bsdf = nt.nodes.new('ShaderNodeBsdfPrincipled')
    out  = nt.nodes.new('ShaderNodeOutputMaterial')
    nt.links.new(bsdf.outputs['BSDF'], out.inputs['Surface'])
    bsdf.inputs['Base Color'].default_value = (r, g, b, 1.0)
    bsdf.inputs['Roughness'].default_value  = 0.72
    for key in ('Specular IOR Level', 'Specular'):
        try:
            bsdf.inputs[key].default_value = 0.2
            break
        except Exception:
            pass
    return mat

def _assign_mat(obj, mat):
    if not obj.data.materials:
        obj.data.materials.append(mat)
    else:
        obj.data.materials[0] = mat

def setup_render(bottom, lid, bezel):
    # Layout: angled to expose interior cavity and all features
    bottom.location       = (  0,   0,  0)
    bottom.rotation_euler = (0, 0, math.radians(20))   # slight yaw to show sides

    lid.location          = (-130, -20, 4)
    lid.rotation_euler    = (math.radians(-40), 0, math.radians(20))

    bezel.location        = ( 125,  -5,  1)
    bezel.rotation_euler  = (math.radians(-20), 0, math.radians(-10))

    # Materials
    gray  = _make_pla_mat("PLA_Gray",  0.55, 0.57, 0.62)
    white = _make_pla_mat("PLA_White", 0.90, 0.90, 0.90)
    _assign_mat(bottom, gray)
    _assign_mat(lid,    gray)
    _assign_mat(bezel,  white)

    # Ground plane
    bpy.ops.mesh.primitive_plane_add(size=800, location=(0, 0, -0.5))
    gnd = bpy.context.active_object
    gmat = bpy.data.materials.new("Ground")
    gmat.use_nodes = True
    gn = gmat.node_tree; gn.nodes.clear()
    gb = gn.nodes.new('ShaderNodeBsdfPrincipled')
    go = gn.nodes.new('ShaderNodeOutputMaterial')
    gn.links.new(gb.outputs['BSDF'], go.inputs['Surface'])
    gb.inputs['Base Color'].default_value = (0.96, 0.96, 0.96, 1.0)
    gb.inputs['Roughness'].default_value  = 0.88
    gnd.data.materials.append(gmat)

    # Camera – slightly high-angle, 40 mm lens
    bpy.ops.object.camera_add(
        location=(-10, -310, 260),
        rotation=(math.radians(43), 0, 0))
    cam = bpy.context.active_object
    cam.data.lens = 40
    bpy.context.scene.camera = cam

    # Key light (sun, warm angle)
    bpy.ops.object.light_add(type='SUN',
        location=(80, -120, 350),
        rotation=(math.radians(18), math.radians(8), math.radians(28)))
    bpy.context.active_object.data.energy = 5.0

    # Fill light (large soft area, camera-left)
    bpy.ops.object.light_add(type='AREA', location=(-250, -100, 220))
    fill = bpy.context.active_object
    fill.data.energy = 900.0
    fill.data.size   = 300
    fill.rotation_euler = (math.radians(-30), 0, math.radians(45))

    # Rim light (back-right, separates parts from ground)
    bpy.ops.object.light_add(type='SPOT', location=(120, 220, 100))
    rim = bpy.context.active_object
    rim.data.energy      = 450.0
    rim.data.spot_size   = math.radians(50)
    rim.rotation_euler   = (math.radians(-65), 0, math.radians(150))

    # World
    sc = bpy.context.scene
    sc.world.use_nodes = True
    bg = sc.world.node_tree.nodes.get('Background')
    if bg:
        bg.inputs['Color'].default_value    = (0.86, 0.90, 0.95, 1.0)
        bg.inputs['Strength'].default_value = 0.55

    # Cycles renderer (reliable headless on macOS Metal)
    sc.render.engine = 'CYCLES'
    try:
        prefs = bpy.context.preferences
        cp    = prefs.addons['cycles'].preferences
        cp.compute_device_type = 'METAL'
        cp.get_devices()
        for d in cp.devices:
            d.use = True
        sc.cycles.device = 'GPU'
        print("[ARCA] Cycles: Metal GPU")
    except Exception:
        sc.cycles.device = 'CPU'
        print("[ARCA] Cycles: CPU fallback")

    sc.cycles.samples          = 128
    sc.cycles.use_denoising    = True
    sc.render.resolution_x     = 1280
    sc.render.resolution_y     = 800
    sc.render.filepath         = RENDER_PATH
    sc.render.image_settings.file_format = 'PNG'


# ─── MAIN ─────────────────────────────────────────────────────────────────────

def main():
    # Work in mm as raw Blender units (no unit_settings conversion needed)
    print("\n[ARCA] ══════════════════════════════════════════════════")
    print("[ARCA]   ARCA Desk Buddy V0  —  Blender", bpy.app.version_string)
    print("[ARCA] ══════════════════════════════════════════════════")

    # ── Base bottom
    clear_scene()
    print("[ARCA] Building base bottom...")
    bot = build_bottom()
    export_stl(bot, "arca_desk_base_bottom.stl")

    # ── Lid
    clear_scene()
    print("[ARCA] Building lid...")
    lid = build_lid()
    export_stl(lid, "arca_desk_base_lid.stl")

    # ── OLED bezel
    clear_scene()
    print("[ARCA] Building OLED bezel...")
    bzl = build_bezel()
    export_stl(bzl, "arca_oled_bezel_adapter.stl")

    # ── Render preview scene
    clear_scene()
    print("[ARCA] Setting up render scene...")
    bot2 = build_bottom()
    lid2 = build_lid()
    bzl2 = build_bezel()
    setup_render(bot2, lid2, bzl2)
    print("[ARCA] Rendering (128 spp)…")
    bpy.ops.render.render(write_still=True)
    print(f"[ARCA] ✓  arca_render.png")
    print(f"\n[ARCA] All files → {SCRIPT_DIR}")
    print("[ARCA] ══════════════════════════════════════════════════\n")

main()
