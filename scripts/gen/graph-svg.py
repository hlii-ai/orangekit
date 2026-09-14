#!/usr/bin/env python3
"""workflow.graph.json -> the work-flow SVG (the graph picture in docs/manual/user.html).

A reader has to be able to answer three questions — what comes first, what goes where, and
what comes back. So the layout is not left free:

  1. **The column is the order.** Work runs left to right only. The x coordinate is time.
  2. **Lines turn at right angles only.** Free curves lose their direction where they overlap.
  3. **Return edges never cross the body.** They drop into a dedicated channel under the band
     and merge back as a single line.
  4. **A round trip is one line with an arrowhead at each end.** The same pair is never drawn twice.
  5. **Vertical moves happen only in the empty lanes between columns.** Descending through the
     middle of a column would run straight through the node below. So every long edge has the
     same shape: exit right -> lane -> channel -> enter the target from its left.

Only the layout (COL, ROW) is set by hand; labels, kinds and edges are read from the graph.
When assets are added or renamed, re-run this and drop the new SVG into user.html.

Usage:
  python3 scripts/gen/graph-svg.py [graph.json] [output.svg]
  Defaults: workflow.graph.json -> docs/manual/graph.svg
"""
import json, pathlib, sys

argv = []
for a in sys.argv[1:]:
    if a.startswith("--"):
        sys.exit("unknown option: %s" % a)
    argv.append(a)
SRC = pathlib.Path(argv[0] if len(argv) > 0 else "workflow.graph.json")
OUT = pathlib.Path(argv[1] if len(argv) > 1 else "docs/manual/graph.svg")
if not SRC.exists():
    sys.exit("graph not found: %s (run this from the repository root)" % SRC)

G = json.load(open(SRC))
NODES = {n["id"]: n for n in G["nodes"]}

# -- grid --───────────────────────────────────────────────────────────
W, H = 200, 56
COLX = [60, 310, 560, 810, 1060, 1310, 1560]      # column = order of progress
GAP = 50
CANVAS_W = 1820
BAND1 = (40, 88, 1740, 596)                        # x, y, w, h
BAND2 = (40, 736, 1740, 372)
CH1 = 640                                          # band 1 return channel
CH2 = 1060                                         # band 2 return channel
LANES = [672, 686, 700, 714]                       # horizontal lanes between bands

RULER = [("Enter", 0), ("Explore · Plan", 1), ("Prep output", 2), ("Build", 3),
         ("Verify", 4), ("Cross-check", 5), ("Take back", 6)]

LABEL = {
    "session-start": "session briefing", "understand": "explore", "plan": "plan",
    "build": "implement", "verify": "hand to review", "cross-check": "reviewer's extra pass",
    "orangekit-planner": "delegated design", "orangekit-reviewer": "independent review",
    "security-check": "blocks secrets · destructive cmds", "build-gate": "verification gate",
    "track-skill": "records skill use", "handoff": "handoff note",
    "prd-generator": "writes the PRD", "dev-docs-generator": "dev documents",
    "completion-review": "closing docs", "codex-claude-loop": "external model check",
    "receiving-code-review": "vets incoming feedback", "doctor": "self-verification",
    "lessons": "lessons log", "eval-report": "evaluation report",
    "rule-promotion": "asset promotion", "user-report": "report to a human",
    "harness-evaluation": "harness evaluation", "skill-enhancer": "skill redesign",
}
# id: (column, y)
POS = {
    "session-start":        (0, 232),
    "understand":           (1, 120),
    "plan":                 (1, 210),
    "orangekit-planner":         (2, 316),
    "prd-generator":        (2, 406),
    "dev-docs-generator":   (2, 496),
    "build":                (3, 210),
    "completion-review":    (4, 112),
    "verify":               (4, 210),
    "orangekit-reviewer":        (5, 112),
    "cross-check":          (5, 210),
    "codex-claude-loop":    (6, 210),
    "receiving-code-review":(6, 316),
    # -- feedback loop: feeds back right to left --
    "lessons":              (6, 784),
    "doctor":               (4, 784),
    "rule-promotion":       (1, 784),
    "user-report":          (0, 900),
    "harness-evaluation":   (4, 908),
    "eval-report":          (2, 908),
    "skill-enhancer":       (1, 908),
}
# hooks hang from a bus below build - drawing them as individual curves tangles on its own
HOOKBUS = ["security-check", "build-gate", "track-skill", "handoff"]
HOOK_Y0, HOOK_DY = 332, 74
HOOK_X = COLX[3] + 36
TRUNK_X = COLX[3] + 8
BLOCKING = {"security-check", "build-gate"}

# band-crossing edges: (lane, entry side) - lanes are split so they never cross the body
CROSS = {
    ("session-start", "doctor"):            (0, "t", COLX[4] + 100),
    ("session-start", "harness-evaluation"):(1, "r", 1530),
    ("track-skill", "doctor"):              (2, "t", COLX[4] + 60),
    ("verify", "lessons"):                  (3, "t", COLX[6] + 100),
    ("cross-check", "lessons"):             (1, "t", COLX[6] + 60),
    ("completion-review", "user-report"):   (0, "t", COLX[0] + 100),
}
_SUB = "subagent · separate context"
_IRR = "Irreversible only"
GROUPS = [
    (COLX[2] - 14, 296, W + 28, 96,  _SUB),
    (COLX[5] - 14, 92,  W + 28, 96,  _SUB),
    (COLX[5] - 14, 190, W + 28, 100, _IRR),
]
TXT = dict(band1="WORK FLOW — left to right",
           band2="FEEDBACK LOOP — feeds back right to left",
           flow="order →", bus="throughout the build · run by the machine",
           ch1="← defects send the work back to build", ch2="← evaluation results become lessons",
           short="all four entry states met → prep phases are skipped")

def x_of(nid):  return COLX[POS[nid][0]]
def y_of(nid):  return POS[nid][1]
def cx(nid):    return x_of(nid) + W / 2
def cy(nid):    return y_of(nid) + H / 2

def elbow(x1, y1, x2, y2, mx, r=10):
    """Horizontal -> vertical -> horizontal, with rounded corners. The only shape whose direction reads at a glance."""
    if abs(y1 - y2) < 2:
        return "M%.0f,%.0f H%.0f" % (x1, y1, x2)
    sy = 1 if y2 > y1 else -1
    sx1 = 1 if mx > x1 else -1
    sx2 = 1 if x2 > mx else -1
    return ("M%.0f,%.0f H%.0f Q%.0f,%.0f %.0f,%.0f V%.0f Q%.0f,%.0f %.0f,%.0f H%.0f"
            % (x1, y1, mx - sx1 * r, mx, y1, mx, y1 + sy * r,
               y2 - sy * r, mx, y2, mx + sx2 * r, y2, x2))

def band_of(nid):
    """Band 1 runs left-to-right; band 2 (the feedback loop) runs right-to-left.
    Without the distinction the whole main feedback flow is misread as a return edge and piles into the channel."""
    return 1 if y_of(nid) < BAND2[1] else 2

def elbow_left(a, b, k=0, r=10):
    """Right node to left node - the forward direction in band 2."""
    x1, y1 = x_of(a), cy(a)
    x2, y2 = x_of(b) + W, cy(b)
    if abs(y1 - y2) < 2:
        return "M%.0f,%.0f H%.0f" % (x1, y1, x2)
    mx = take(lambda c, k: x_of(a) - GAP / 2 - k * 13, POS[a][0], y1, y2)
    sy = 1 if y2 > y1 else -1
    return ("M%.0f,%.0f H%.0f Q%.0f,%.0f %.0f,%.0f V%.0f Q%.0f,%.0f %.0f,%.0f H%.0f"
            % (x1, y1, mx + r, mx, y1, mx, y1 + sy * r,
               y2 - sy * r, mx, y2, mx - r, y2, x2))

def rlane(col, k=0):
    """The empty lane right of a column. Nothing sits there, so a vertical run is safe."""
    return COLX[col] + W + 14 + k * 16

def llane(col, k=0):
    """The empty lane left of a column."""
    return COLX[col] - 14 - k * 16

_USED = {}

def take(base, col, y1, y2):
    """Claim a free vertical lane.

    Two lines that share an x for their whole length read as one and lose their destinations.
    Where they overlap, push one into the next lane so they always read separately.
    """
    lo, hi = min(y1, y2), max(y1, y2)
    for k in range(7):
        x = base(col, k)
        if all(lo >= b - 10 or hi <= a + 10 for a, b in _USED.get(x, ())):
            _USED.setdefault(x, []).append((lo, hi))
            return x
    return base(col, 0)

def bus(a, b, ch, ka=0, kb=0, r=9):
    """Exit sideways -> lane -> channel -> lane beside the target -> in through the target's edge.

    Giving every long edge the same shape makes it obvious which line goes where.
    The entry side follows the target band's forward direction - coming in from upstream keeps
    the edge from fighting the flow.
    """
    right_in = band_of(b) == 2          # in band 2, upstream is on the right
    ya = cy(a)
    yb = cy(b) + 14                     # nudged down so it does not overlap the forward arrowhead
    x1 = take(rlane, POS[a][0], ya, ch)
    x2 = take(rlane if right_in else llane, POS[b][0], ch, yb)
    sx = 1 if x2 > x1 else -1
    return ("M%.0f,%.0f H%.0f Q%.0f,%.0f %.0f,%.0f V%.0f Q%.0f,%.0f %.0f,%.0f "
            "H%.0f Q%.0f,%.0f %.0f,%.0f V%.0f Q%.0f,%.0f %.0f,%.0f H%.0f"
            % (x_of(a) + W, ya, x1 - r, x1, ya, x1, ya + r,
               ch - r, x1, ch, x1 + sx * r, ch,
               x2 - sx * r, x2, ch, x2, ch - r,
               yb + r, x2, yb, x2 + (r if not right_in else -r), yb,
               x_of(b) + (W if right_in else 0)))

def shape(nid, x, y):
    kind = NODES[nid].get("kind", "stage")
    o = []
    if nid in BLOCKING:
        o.append('<path d="M%d,%d h%d l16,%d l-16,%d h-%d z" fill="var(--g-hookbg)" stroke="var(--g-block)" stroke-width="2.2"/>'
                 % (x, y, W - 16, H // 2, H // 2, W - 16))
    elif kind == "hook":
        o.append('<path d="M%d,%d h%d l16,%d l-16,%d h-%d z" fill="var(--g-surface)" stroke="var(--g-hook)" stroke-width="1.6"/>'
                 % (x, y, W - 16, H // 2, H // 2, W - 16))
    elif kind in ("store", "terminal"):
        bg = "var(--g-termbg)" if kind == "terminal" else "var(--g-surface)"
        st = "var(--g-term)" if kind == "terminal" else "var(--g-store)"
        o.append('<rect x="%d" y="%d" width="%d" height="%d" rx="%d" fill="%s" stroke="%s" stroke-width="1.6"/>'
                 % (x, y, W, H, H // 2, bg, st))
    elif kind == "tool":
        o.append('<path d="M%d,%d h%d l18,%d l-18,%d h-%d l-18,-%d z" fill="var(--g-surface)" stroke="var(--g-tool)" stroke-width="1.8"/>'
                 % (x + 18, y, W - 36, H // 2, H // 2, W - 36, H // 2))
    elif kind == "agent":
        o.append('<rect x="%d" y="%d" width="%d" height="%d" rx="8" fill="var(--g-surface)" stroke="var(--g-agent)" stroke-width="1.8"/>'
                 % (x, y, W, H))
    elif kind == "skill":
        o.append('<rect x="%d" y="%d" width="%d" height="%d" rx="6" fill="var(--g-surface)" stroke="var(--g-line)" stroke-width="1.4"/>'
                 % (x, y, W, H))
        o.append('<rect x="%d" y="%d" width="3" height="%d" fill="var(--g-skill)"/>' % (x + 9, y + 11, H - 22))
    else:
        o.append('<rect x="%d" y="%d" width="%d" height="%d" rx="10" fill="var(--g-stagebg)" stroke="var(--g-stage)" stroke-width="2"/>'
                 % (x, y, W, H))
    col = {"hook": "var(--g-hook)", "store": "var(--g-store)", "tool": "var(--g-tool)",
           "terminal": "var(--g-term)", "agent": "var(--g-agent)", "skill": "var(--g-skill)"}.get(kind, "var(--g-ink)")
    if nid in BLOCKING:
        col = "var(--g-block)"
    o.append('<text class="gn" x="%.0f" y="%d" text-anchor="middle" fill="%s">%s</text>' % (x + W / 2, y + 24, col, nid))
    o.append('<text class="gk" x="%.0f" y="%d" text-anchor="middle" fill="var(--g-soft)">%s</text>' % (x + W / 2, y + 42, LABEL.get(nid, "")))
    return "\n".join(o)

def edge(d, kind="fwd", both=False):
    style = {
        "fwd":  ('var(--g-edge)', "1.5", "", "ga"),
        "inst": ('var(--g-inst)', "1.9", "", "gi"),
        "back": ('var(--g-back)', "1.5", ' stroke-dasharray="7 5"', "gb"),
    }[kind]
    start = ' marker-start="url(#%s)"' % ({"fwd": "gas", "inst": "gis", "back": "gbs"}[kind]) if both else ""
    return '<path d="%s" fill="none" stroke="%s" stroke-width="%s"%s marker-end="url(#%s)"%s/>' % (
        d, style[0], style[1], style[2], style[3], start)

# -- edge classification --
SHORTCUT = ("session-start", "build")
FORCE_BACK = {("eval-report", "lessons")}   # semantically a feedback edge -> send it to the channel
# forward edges whose straight course is blocked - detour via the channel, keep the forward look
FORCE_BUS = {("harness-evaluation", "user-report")}
pairs, seen, fwd, back, cross, skipped = set(), set(), [], [], [], 0
E = [(e["from"], e["to"], bool(e.get("instrumented"))) for e in G["edges"]]
lookup = {(a, b): i for a, b, i in E}
for a, b, inst in E:
    if a in HOOKBUS or b in HOOKBUS:
        if (a, b) not in [("track-skill", "doctor")]:
            continue                                   # the hook bus draws these separately
    if a not in POS or b not in POS:
        skipped += 1
        continue
    if (b, a) in lookup and (b, a) not in seen:         # round trip - draw as one line
        pairs.add((a, b)); seen.add((a, b)); continue
    if (a, b) in seen or (b, a) in seen:
        continue
    seen.add((a, b))
    if (a, b) == SHORTCUT:
        continue                                        # drawn separately in the top lane
    if (a, b) in FORCE_BACK:
        back.append((a, b, inst)); continue
    if (a, b) in CROSS:
        cross.append((a, b, inst))
    elif POS[a][0] == POS[b][0]:
        (fwd if POS[a][1] < POS[b][1] else back).append((a, b, inst))
    elif band_of(a) == 1 and band_of(b) == 1:
        (fwd if POS[a][0] < POS[b][0] else back).append((a, b, inst))
    elif band_of(a) == 2 and band_of(b) == 2:
        (fwd if POS[a][0] > POS[b][0] else back).append((a, b, inst))
    else:
        back.append((a, b, inst))

ALT = ("The core paths of workflow.graph.json. Work runs left to right and the column is the order. "
         "From session start through explore and plan, preparation outputs converge on build, "
         "then verify and cross-check. Four hooks hang from a bus below build; the two that block are "
         "drawn in the warning colour. Return edges never cross the body — they drop into a dedicated "
         "channel under the band and merge back into build. The lower band is the feedback loop, "
         "feeding from the lessons log on the right back to the human report on the left.")

parts = [
    '<svg viewBox="0 0 %d 1150" role="img" aria-label="%s">' % (CANVAS_W, ALT),
    '<defs>',
]
for mid, col in [("ga", "--g-edge"), ("gi", "--g-inst"), ("gb", "--g-back")]:
    parts.append('<marker id="%s" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
                 '<path d="M0 0 L10 5 L0 10 z" fill="var(%s)"/></marker>' % (mid, col))
    parts.append('<marker id="%ss" viewBox="0 0 10 10" refX="1" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
                 '<path d="M10 0 L0 5 L10 10 z" fill="var(%s)"/></marker>' % (mid, col))
parts.append('</defs>')

# bands
for (bx, by, bw, bh, label) in [(*BAND1, TXT["band1"]),
                                (*BAND2, TXT["band2"])]:
    parts.append('<rect x="%d" y="%d" width="%d" height="%d" rx="10" fill="var(--g-band)" stroke="var(--g-line)" stroke-width="1"/>'
                 % (bx, by, bw, bh))
    parts.append('<text class="gb" x="%d" y="%d" fill="var(--g-faint)">%s</text>' % (bx + 18, by + 24, label))

# column ruler - answers "what comes first" with the x coordinate
parts.append('<line x1="%d" y1="72" x2="%d" y2="72" stroke="var(--g-line)" stroke-width="1"/>' % (BAND1[0], BAND1[0] + BAND1[2]))
for label, c in RULER:
    parts.append('<text class="gr" x="%.0f" y="62" text-anchor="middle" fill="var(--g-faint)">%s</text>' % (COLX[c] + W / 2, label))
    parts.append('<line x1="%.0f" y1="66" x2="%.0f" y2="78" stroke="var(--g-line)" stroke-width="1.5"/>' % (COLX[c] + W / 2, COLX[c] + W / 2))
parts.append('<text class="gr" x="%d" y="62" fill="var(--g-faint)">%s</text>' % (BAND1[0] + 8, TXT["flow"]))

# dashed groupings
for (gx, gy, gw, gh, glabel) in GROUPS:
    parts.append('<rect x="%d" y="%d" width="%d" height="%d" rx="8" fill="none" stroke="var(--g-agent)" stroke-width="1.2" stroke-dasharray="6 5" opacity="0.65"/>'
                 % (gx, gy, gw, gh))
    parts.append('<text class="gg" x="%d" y="%d" fill="var(--g-faint)">%s</text>' % (gx + 4, gy - 6, glabel))

# -- edges --
IN_Y = {}                                               # stagger lines that pile onto the same edge
for a, b, inst in fwd:
    ca, cb = POS[a][0], POS[b][0]
    kind = "inst" if inst else "fwd"
    if ca == cb:
        parts.append(edge("M%.0f,%d V%d" % (cx(a), y_of(a) + H, y_of(b)), kind))
        continue
    slot = IN_Y.get(b, 0); IN_Y[b] = slot + 1
    dy = (slot - 0.5) * 16 if slot else 0
    if (a, b) in FORCE_BUS:
        parts.append(edge(bus(a, b, CH2 if band_of(a) == 2 else CH1, ka=slot % 3, kb=slot % 2), kind))
        continue
    if band_of(a) == 2:
        parts.append(edge(elbow_left(a, b, k=slot), kind))
    else:
        mx = take(lambda c, k: COLX[c] + W + 16 + k * 13, ca, cy(a), cy(b) + dy)
        parts.append(edge(elbow(x_of(a) + W, cy(a), x_of(b), cy(b) + dy, mx), kind))

for a, b in sorted(pairs):
    ca, cb = POS[a][0], POS[b][0]
    if ca == cb:
        parts.append(edge("M%.0f,%d V%d" % (cx(a), y_of(a) + H, y_of(b)), "fwd", both=True))
    elif ca < cb:
        mx = COLX[ca] + W + GAP / 2
        parts.append(edge(elbow(x_of(a) + W, cy(a), x_of(b), cy(b), mx), "fwd", both=True))
    else:
        mx = COLX[cb] + W + GAP / 2
        parts.append(edge(elbow(x_of(b) + W, cy(b), x_of(a), cy(a), mx), "fwd", both=True))

for i, (a, b, inst) in enumerate(back):                  # return edges - dedicated channel
    ch = CH1 if y_of(a) < BAND2[1] else CH2
    parts.append(edge(bus(a, b, ch, ka=i % 3, kb=i % 2), "back"))

for i, (a, b, inst) in enumerate(cross):                 # crosses a band - same bus shape
    parts.append(edge(bus(a, b, LANES[CROSS[(a, b)][0]], ka=i % 3, kb=i % 2),
                      "inst" if inst else "fwd"))

# shortcut - when the entry conditions are met the prep phases are skipped entirely. Routed through the empty top lane.
if SHORTCUT in lookup:
    a, b = SHORTCUT
    ty = 104
    parts.append(edge("M%.0f,%d V%d Q%.0f,%d %.0f,%d H%.0f Q%.0f,%d %.0f,%d V%d"
                      % (cx(a), y_of(a), ty + 9, cx(a), ty, cx(a) + 9, ty,
                         cx(b) - 9, cx(b), ty, cx(b), ty + 9, y_of(b)), "fwd"))
    parts.append('<text class="gg" x="%.0f" y="%d" text-anchor="middle" fill="var(--g-soft)">'
                 '%s</text>' % ((cx(a) + cx(b)) / 2, ty - 8, TXT["short"]))

# -- hook bus --
bus_bottom = HOOK_Y0 + HOOK_DY * (len(HOOKBUS) - 1) + H / 2
parts.append('<rect x="%d" y="%d" width="%d" height="%d" rx="8" fill="none" stroke="var(--g-hook)" stroke-width="1.1" stroke-dasharray="5 5" opacity="0.55"/>'
             % (TRUNK_X - 16, HOOK_Y0 - 22, W + 76, bus_bottom - HOOK_Y0 + 52))
parts.append('<text class="gg" x="%d" y="%d" fill="var(--g-hook)">%s</text>' % (TRUNK_X - 16, HOOK_Y0 - 30, TXT["bus"]))
parts.append('<path d="M%.0f,%d V%.0f" fill="none" stroke="var(--g-hook)" stroke-width="1.6"/>'
             % (cx("build"), y_of("build") + H, HOOK_Y0 - 22))
parts.append('<path d="M%.0f,%d H%d V%.0f" fill="none" stroke="var(--g-hook)" stroke-width="1.6"/>'
             % (cx("build"), HOOK_Y0 - 22, TRUNK_X, bus_bottom))
for i, hid in enumerate(HOOKBUS):
    hy = HOOK_Y0 + HOOK_DY * i
    both = hid in BLOCKING
    parts.append('<path d="M%d,%.0f H%d" fill="none" stroke="var(--g-%s)" stroke-width="1.6" marker-end="url(#g%s)"%s/>'
                 % (TRUNK_X, hy + H / 2, HOOK_X, "block" if both else "hook",
                    "ba" if both else "ha", ' marker-start="url(#gbas)"' if both else ""))
for mid, col in [("gha", "--g-hook"), ("gba", "--g-block")]:
    parts.insert(9, '<marker id="%s" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
                    '<path d="M0 0 L10 5 L0 10 z" fill="var(%s)"/></marker>' % (mid, col))
parts.insert(9, '<marker id="gbas" viewBox="0 0 10 10" refX="1" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
                '<path d="M10 0 L0 5 L10 10 z" fill="var(--g-block)"/></marker>')

# -- nodes --
for nid in POS:
    parts.append(shape(nid, x_of(nid), y_of(nid)))
for i, hid in enumerate(HOOKBUS):
    parts.append(shape(hid, HOOK_X, HOOK_Y0 + HOOK_DY * i))

# channel labels - say what the returning lines are
parts.append('<text class="gg" x="%d" y="%d" fill="var(--g-back)">%s</text>' % (COLX[3] + 30, CH1 + 18, TXT["ch1"]))
parts.append('<text class="gg" x="%d" y="%d" fill="var(--g-back)">%s</text>' % (COLX[3], CH2 + 18, TXT["ch2"]))
parts.append('</svg>')

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text("\n".join(parts))
print("nodes %d · forward %d · round trip %d · return %d · band-crossing %d -> %s (%d bytes)"
      % (len(POS) + len(HOOKBUS), len(fwd), len(pairs), len(back), len(cross), OUT, OUT.stat().st_size))
if skipped:
    print("  (%d edges omitted as outside the core paths)" % skipped)

missing = [n for n in list(POS) + HOOKBUS if n not in NODES]
if missing:
    sys.exit("POS names nodes the graph does not have: %s" % ", ".join(missing))
