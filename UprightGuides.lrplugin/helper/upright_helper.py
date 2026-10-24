"""Upright Guides helper: finds the room's vertical (and optionally horizontal)
directions in a photo and returns Lightroom Guided Upright guides for them.

usage: upright_helper.py <jobs.tsv> <results.tsv> [<overlay_dir>]

jobs.tsv, one photo per line, tab separated:
    id  path  lens_profile_file  lens_on  horizontal
      lens_profile_file  the .lcp file name Lightroom uses, or empty to match by lens
      lens_on            1 if lens profile correction will be on in Lightroom
      horizontal         1 to also return two horizontal guides for straight-on shots

results.tsv, tab separated:
    id  ok      pitch  roll  yaw  guides  note
    id  error   message
  guides are "x1,y1,x2,y2" in 0-1 image coordinates, joined by ";". Coordinates
  are in the file's stored pixel orientation (Lightroom ignores rotation for
  guides), in the lens-corrected frame when lens_on is 1, otherwise uncorrected.

The method: detect straight line segments, then find the three perpendicular
room directions (up and two horizontals) that the most line length agrees with.
Each guide is placed on a strong real edge but angled to agree with all the
lines, so Lightroom's result matches the whole-image estimate.
"""
import glob
import math
import os
import re
import shutil
import subprocess
import sys

import cv2
import numpy as np

WORK_W = 1600          # analysis width (px)
MIN_LEN = 0.03         # shortest segment, fraction of image height
TAU = 0.6              # inlier residual (deg)
MERGE_PX = 3.0         # collinear segments within this distance join one guide
ONE_POINT_YAW = 15     # deg: below this the shot counts as straight-on

rng = np.random.default_rng(0)


# ---------------------------------------------------------------- tools

def find_exiftool():
    for c in [shutil.which('exiftool'), r'C:\Program Files\exiftool\exiftool.exe',
              r'C:\Program Files (x86)\exiftool\exiftool.exe', r'C:\Windows\exiftool.exe',
              '/opt/homebrew/bin/exiftool', '/usr/local/bin/exiftool', '/usr/bin/exiftool']:
        if c and os.path.exists(c):
            return c
    return None


EXIFTOOL = find_exiftool()


def exif(path, *tags):
    out = subprocess.run([EXIFTOOL, '-s3', '-f', *('-' + t for t in tags), path],
                         capture_output=True, text=True, encoding='utf-8').stdout.splitlines()
    return out + [''] * (len(tags) - len(out))


def lens_profile_dirs():
    dirs = []
    for base in [os.environ.get('PROGRAMDATA'), os.environ.get('APPDATA'),
                 '/Library/Application Support', os.path.expanduser('~/Library/Application Support')]:
        if base:
            dirs.append(os.path.join(base, 'Adobe', 'CameraRaw', 'LensProfiles', '1.0'))
    return [d for d in dirs if os.path.isdir(d)]


def squash(s):
    return re.sub(r'[^a-z0-9]', '', s.lower())


def find_lcp(filename, lens_model):
    files = [f for d in lens_profile_dirs() for f in glob.glob(os.path.join(d, '**', '*.lcp'), recursive=True)]
    if filename:
        for f in files:
            if os.path.basename(f).lower() == filename.lower():
                return f
    key = squash(lens_model or '')
    if key:
        hits = [f for f in files if key in squash(os.path.basename(f))]
        hits.sort(key=lambda f: ('RAW' not in f, len(f)))   # raw profiles first
        if hits:
            return hits[0]
    return None


def lcp_params(lcp, focal):
    """Adobe radial model at the farthest profiled focus, interpolated in focal length."""
    txt = open(lcp, encoding='utf-8', errors='ignore').read()
    by_fl = {}
    for blk in re.split(r'<rdf:li', txt)[1:]:
        fl = re.search(r'stCamera:FocalLength="([\d.]+)"', blk)
        fd = re.search(r'stCamera:FocusDistance="([\d.]+)"', blk)
        pm = re.search(r'FocalLengthX="([\d.]+)".*?ImageXCenter="([\d.]+)".*?ImageYCenter="([\d.]+)"'
                       r'.*?RadialDistortParam1="([-\d.e]+)"(?:.*?RadialDistortParam2="([-\d.e]+)")?'
                       r'(?:.*?RadialDistortParam3="([-\d.e]+)")?', blk, re.S)
        if not (fl and pm):
            continue
        k, d = float(fl.group(1)), float(fd.group(1)) if fd else 0
        vals = np.array([float(x) if x else 0.0 for x in pm.groups()])
        if k not in by_fl or d > by_fl[k][0]:
            by_fl[k] = (d, vals)
    if not by_fl:
        return None
    fls = sorted(by_fl)
    lo = max([x for x in fls if x <= focal], default=fls[0])
    hi = min([x for x in fls if x >= focal], default=fls[-1])
    t = 0 if hi == lo else (focal - lo) / (hi - lo)
    return (1 - t) * by_fl[lo][1] + t * by_fl[hi][1]


# ---------------------------------------------------------------- image

def load(path):
    """8-bit grey image in the file's stored pixel orientation."""
    if path.lower().endswith('.dng'):
        try:
            import tifffile
            with tifffile.TiffFile(path) as t:
                best = None
                for s in t.series:
                    if len(s.shape) == 3 and s.shape[2] == 3 and (best is None or s.size > best.size):
                        best = s
                a = best.asarray().astype(np.float32)
            lum = np.clip(a.mean(axis=2), 1e-4 * max(a.max(), 1e-6), None)
            lg = np.log2(lum)
            lo, hi = np.percentile(lg, [0.5, 99.8])
            return (np.clip((lg - lo) / (hi - lo), 0, 1) * 255).astype(np.uint8)
        except Exception:
            pass  # e.g. a raw (mosaic) DNG: fall back to its preview
    for tag in ('PreviewImage', 'JpgFromRaw'):
        data = subprocess.run([EXIFTOOL, '-b', '-' + tag, path], capture_output=True).stdout
        if data:
            img = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_GRAYSCALE)
            if img is not None:
                return img
    raise RuntimeError('could not read image data')


class Lens:
    """Maps between uncorrected (distorted) and lens-corrected pixel positions."""

    def __init__(self, params, w, h):
        self.on = params is not None
        if self.on:
            fx, cx, cy, self.k1, self.k2, self.k3 = params
            self.F, self.u0, self.v0 = fx * max(w, h), cx * w, cy * h

    def _s(self, r2):
        return 1 + self.k1 * r2 + self.k2 * r2 ** 2 + self.k3 * r2 ** 3

    def undistort_image(self, img):
        if not self.on:
            return img
        h, w = img.shape[:2]
        yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
        x, y = (xx - self.u0) / self.F, (yy - self.v0) / self.F
        s = self._s(x * x + y * y)
        return cv2.remap(img, (x * s * self.F + self.u0).astype(np.float32),
                         (y * s * self.F + self.v0).astype(np.float32), cv2.INTER_LINEAR)

    def distort_point(self, p):
        if not self.on:
            return p
        x, y = (p[0] - self.u0) / self.F, (p[1] - self.v0) / self.F
        s = self._s(x * x + y * y)
        return (x * s * self.F + self.u0, y * s * self.F + self.v0)


# ---------------------------------------------------------------- geometry

def detect(gray):
    s = cv2.createLineSegmentDetector(cv2.LSD_REFINE_STD).detect(gray)[0]
    s = np.empty((0, 4)) if s is None else s.reshape(-1, 4)
    ln = np.hypot(s[:, 2] - s[:, 0], s[:, 3] - s[:, 1])
    keep = ln > MIN_LEN * gray.shape[0]
    return s[keep], ln[keep]


def normals(segs, pp, f):
    one = np.full(len(segs), f)
    p1 = np.c_[segs[:, 0] - pp[0], segs[:, 1] - pp[1], one]
    p2 = np.c_[segs[:, 2] - pp[0], segs[:, 3] - pp[1], one]
    n = np.cross(p1, p2)
    return n / np.linalg.norm(n, axis=1, keepdims=True)


def resid(n, R):
    return np.degrees(np.abs(np.arcsin(np.clip(n @ R, -1, 1))))


def frame_from(u, d):
    u = u / np.linalg.norm(u)
    d = d - (d @ u) * u
    d /= np.linalg.norm(d)
    return np.c_[d, u, np.cross(d, u)]   # columns: horizontal A, up, horizontal B


def ransac(n, w, segs):
    dx, dy = segs[:, 2] - segs[:, 0], segs[:, 3] - segs[:, 1]
    vert = np.degrees(np.arctan2(np.abs(dx), np.abs(dy))) < 30
    vi, hi = np.flatnonzero(vert), np.flatnonzero(~vert)
    if len(vi) < 2:
        raise RuntimeError('not enough vertical lines')
    pv = w[vi] / w[vi].sum()
    ph = w[hi] / w[hi].sum() if len(hi) else None

    def sample_up():
        a, b = rng.choice(vi, 2, replace=False, p=pv)
        u = np.cross(n[a], n[b])
        if np.linalg.norm(u) < 1e-6:
            return None
        u /= np.linalg.norm(u)
        if u[1] > 0:
            u = -u
        return u if -u[1] >= 0.7 else None

    def vertical_support(u):
        return w[vi][np.degrees(np.abs(np.arcsin(np.clip(n[vi] @ u, -1, 1)))) < TAU].sum()

    # Best support the vertical lines alone can give. Texture (wood grain,
    # marble) can line up with a wrong horizontal direction, so a full room
    # solution must keep most of this vertical support to be accepted.
    best_v = 0
    for _ in range(1500):
        u = sample_up()
        if u is not None:
            best_v = max(best_v, vertical_support(u))

    best, best_s = None, -1
    for _ in range(4000):
        u = sample_up()
        if u is None or vertical_support(u) < 0.8 * best_v:
            continue
        if len(hi):
            d = np.cross(n[rng.choice(hi, p=ph)], u)
            if np.linalg.norm(d) < 1e-6:
                continue
        else:
            d = np.array([1.0, 0, 0])
        R = frame_from(u, d)
        s = w[resid(n, R).min(axis=1) < TAU].sum()
        if s > best_s:
            best, best_s = R, s
    if best is None:
        raise RuntimeError('no consistent vertical direction')
    return best


def refine(n, w, R, iters=15):
    for _ in range(iters):
        r = resid(n, R)
        k = r.argmin(axis=1)
        inl = r.min(axis=1) < TAU
        if inl.sum() < 6:
            break
        c = R[:, k[inl]].T
        nn = n[inl]
        e = np.einsum('ij,ij->i', nn, c)
        J = np.cross(c, nn)
        sw = np.sqrt(w[inl])
        dw = np.linalg.lstsq(J * sw[:, None], -e * sw, rcond=None)[0]
        if np.linalg.norm(dw) < 1e-9:
            break
        R = cv2.Rodrigues(dw)[0] @ R
    r = resid(n, R)
    return R, r.argmin(axis=1), r.min(axis=1) < TAU


def level_rot(u):
    t = np.array([0.0, -1.0, 0.0])
    v = np.cross(u, t)
    s, c = np.linalg.norm(v), u @ t
    if s < 1e-9:
        return np.eye(3)
    vx = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + vx + vx @ vx * ((1 - c) / s ** 2)


def angles(R):
    up = R[:, 1]
    pitch = math.degrees(math.atan2(up[2], -up[1]))
    roll = math.degrees(math.atan2(up[0], -up[1]))
    L = level_rot(up)
    cands = [(L @ R[:, 0], 0), (L @ R[:, 2], 2)]
    d, axis = max(cands, key=lambda c: abs(c[0][0]))
    d = d if d[0] > 0 else -d
    return pitch, roll, math.degrees(math.atan2(d[2], d[0])), axis


# ---------------------------------------------------------------- guides

def guide_lines(segs, ln, k, inl, axis, R, pp, f, across):
    """Two guides for one room direction, each on a strong real edge.

    Segments of that direction lying on the same image line are merged, so a
    long edge broken into pieces by the detector counts as one. The two best
    lines that are well separated become the guides, each drawn through its
    edge towards the direction's vanishing point, so it agrees with the whole
    estimate rather than just its own edge."""
    d3 = R[:, axis]
    idx = np.flatnonzero(inl & (k == axis))
    if len(idx) == 0:
        return []

    vp = np.array([d3[0] * f + pp[0] * d3[2], d3[1] * f + pp[1] * d3[2], d3[2]])

    def line_dir(m):
        if abs(vp[2]) < 1e-9:
            v = vp[:2]
        else:
            v = vp[:2] / vp[2] - m
        return v / np.linalg.norm(v)

    order = idx[np.argsort(-ln[idx])]
    used = np.zeros(len(segs), bool)
    lines = []
    for i in order:
        if used[i]:
            continue
        m = (segs[i, :2] + segs[i, 2:]) / 2
        v = line_dir(m)
        nrm = np.array([-v[1], v[0]])
        total, ts = 0.0, []
        for j in order:
            if used[j]:
                continue
            p1, p2 = segs[j, :2], segs[j, 2:]
            if abs((p1 - m) @ nrm) < MERGE_PX and abs((p2 - m) @ nrm) < MERGE_PX:
                used[j] = True
                total += ln[j]
                ts += [(p1 - m) @ v, (p2 - m) @ v]
        lines.append((total, m + min(ts) * v, m + max(ts) * v, m))

    lines.sort(key=lambda t: -t[0])
    first = lines[0]
    span = across[1]
    pick = [first]
    for cand in lines[1:]:
        if abs((cand[3] - first[3])[across[0]]) > 0.25 * span:
            pick.append(cand)
            break
    if len(pick) < 2 and len(lines) > 1:
        pick.append(lines[1])
    return [(p[1], p[2]) for p in pick]


def process(path, lcp_name, lens_on, horizontal):
    gray = load(path)
    scale = WORK_W / max(gray.shape)
    gray = cv2.resize(gray, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    h, w = gray.shape

    focal, lens_model = exif(path, 'FocalLength#', 'LensModel')
    focal = float(focal) if focal not in ('', '-') else 0
    if focal <= 0:
        raise RuntimeError('no focal length in file')

    lcp = find_lcp(lcp_name, lens_model)
    params = lcp_params(lcp, focal) if lcp else None
    lens = Lens(params, w, h)
    img = lens.undistort_image(gray)
    # focal length in pixels: from the profile when there is one, else from a full-frame-equivalent guess
    f = lens.F if lens.on else focal * max(w, h) / 36.0
    pp = (w / 2, h / 2)

    segs, ln = detect(img)
    # Ignore the frame edge and the empty border lens correction leaves: both
    # look like perfectly straight lines but aren't part of the room.
    valid = lens.undistort_image(np.full_like(gray, 255))
    m = max(2, int(0.004 * max(w, h)))
    valid[:m], valid[-m:], valid[:, :m], valid[:, -m:] = 0, 0, 0, 0
    valid = cv2.erode(valid, np.ones((7, 7), np.uint8))
    inside = lambda x, y: valid[np.clip(y.astype(int), 0, h - 1), np.clip(x.astype(int), 0, w - 1)] > 0
    keep = inside(segs[:, 0], segs[:, 1]) & inside(segs[:, 2], segs[:, 3])
    segs, ln = segs[keep], ln[keep]
    n = normals(segs, pp, f)
    R, k, inl = refine(n, ln, ransac(n, ln, segs))
    pitch, roll, yaw, hz_axis = angles(R)

    # Confidence: re-fit on resampled lines; a wide spread means the lines
    # don't pin the angles down (few or short verticals, mostly texture).
    boots = []
    for _ in range(30):
        i = rng.integers(0, len(n), len(n))
        boots.append(angles(refine(n[i], ln[i], R, iters=6)[0])[:2])
    spread = float(np.max(np.std(boots, axis=0)))

    guides = guide_lines(segs, ln, k, inl, 1, R, pp, f, (0, w))
    note = 'low confidence: check' if spread > 0.3 else ''
    if horizontal:
        if abs(yaw) < ONE_POINT_YAW:
            guides += guide_lines(segs, ln, k, inl, hz_axis, R, pp, f, (1, h))
        else:
            note = (note + '; ' if note else '') + 'angled view: horizontal guides skipped'
    if len(guides) < 2:
        raise RuntimeError('not enough strong vertical edges')

    out = []
    for a, b in guides:
        if not lens_on:   # Lightroom will draw on the uncorrected image
            a, b = lens.distort_point(a), lens.distort_point(b)
        out.append((min(max(a[0] / w, 0), 1), min(max(a[1] / h, 0), 1),
                    min(max(b[0] / w, 0), 1), min(max(b[1] / h, 0), 1)))
    if not lcp:
        note = (note + '; ' if note else '') + 'no lens profile found'
    return pitch, roll, yaw, out, note, (img if lens_on else gray)


def overlay(img, guides, label, dest):
    vis = cv2.cvtColor(img, cv2.COLOR_GRAY2BGR)
    h, w = img.shape
    for x1, y1, x2, y2 in guides:
        cv2.line(vis, (int(x1 * w), int(y1 * h)), (int(x2 * w), int(y2 * h)), (0, 0, 255), 2, cv2.LINE_AA)
    cv2.putText(vis, label, (12, 32), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 0), 5, cv2.LINE_AA)
    cv2.putText(vis, label, (12, 32), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 255), 2, cv2.LINE_AA)
    cv2.imwrite(dest, vis, [cv2.IMWRITE_JPEG_QUALITY, 85])


def main():
    jobs, results = sys.argv[1], sys.argv[2]
    overlay_dir = sys.argv[3] if len(sys.argv) > 3 else None
    with open(jobs, encoding='utf-8') as fin, open(results, 'w', encoding='utf-8', newline='\n') as fout:
        for line in fin:
            parts = line.rstrip('\r\n').split('\t')
            if len(parts) < 5:
                continue
            pid, path, lcp_name, lens_on, horizontal = parts[:5]
            try:
                if not EXIFTOOL:
                    raise RuntimeError('ExifTool not found')
                pitch, roll, yaw, guides, note, img = process(path, lcp_name, lens_on == '1', horizontal == '1')
                g = ';'.join(','.join(f'{v:.6f}' for v in s) for s in guides)
                fout.write(f'{pid}\tok\t{pitch:.3f}\t{roll:.3f}\t{yaw:.3f}\t{g}\t{note}\n')
                if overlay_dir:
                    name = os.path.splitext(os.path.basename(path))[0]
                    overlay(img, guides, f'{name}  pitch {pitch:+.2f}  roll {roll:+.2f}  yaw {yaw:+.1f}',
                            os.path.join(overlay_dir, name + '_guides.jpg'))
            except Exception as e:
                fout.write(f'{pid}\terror\t{str(e).replace(chr(9), " ")}\n')
            fout.flush()


if __name__ == '__main__':
    main()
