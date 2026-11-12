# 09 - Rules-engine sketch (scratch, not app code)

Written and run 2026-11-09 in the research container (Python, because there is
no Swift toolchain here). It is a sketch of about 150 lines whose only job was
to settle one question before anyone writes Swift: can a small rule tree with
explicit sharing, a greedy allocator and a prerequisite-aware term planner
express a Penn-shaped program and produce a sane what-if? The program below is
a TOY with invented numbers; it is not the real CIS BSE.

## What it showed

- A requirement tree of `need {courses, credits}` leaves with `match` filters
  (explicit codes, department plus number range, attribute) and `share` sets
  evaluates correctly and reads clearly. This is the shape note 05 section 6
  recommends, and it is the shape Penn Labs' `Rule` model has.
- Greedy allocation "to the rule with the largest shortfall, honouring
  symmetric sharing" placed six taken courses sensibly in one pass. Penn Labs
  adds a rebalance pass; the sketch did not need one on this toy, but a real
  program would.
- The planner filled the remaining course shortfalls, ordered them by the
  length of their prerequisite chain, respected a fall-only course
  (`CIS-2620`, `CIS-4710`) and a spring-only one (`CIS-3200`), and kept each
  term under a 5 CU cap. Three terms, nothing unplaced.
- **One gap it exposed, worth carrying into the design:** the planner filled
  shortfalls counted in courses but not in credits. The "natural science"
  rule needs 3.0 CU; the student had 1.5 CU of `PHYS-0150`; the planner
  planned nothing for it because its shortfall is in CU, not in course count.
  A real engine must treat a credit shortfall as "add eligible courses until
  the CU total is reached", and must prefer courses whose CU fits the gap.
- Picking "the lowest-numbered eligible course" to fill a shortfall is a
  placeholder. A real planner should prefer courses that also unlock later
  requirements (longest downstream chain) and courses the student already has
  prerequisites for.

## Output of the run

```
cis core                         open  ['CIS-1200', 'CIS-1600']
cis electives 3000+              open  []
math                             open  ['MATH-1400']
natural science                  open  ['PHYS-0150']
writing seminar                  met   ['WRIT-0020']
social science / humanities      open  ['HIST-0100']
program met: False
  fall 2027    ['CIS-1210', 'CIS-2400', 'CIS-2620', 'MATH-1410', 'ECON-0100']
  spring 2028  ['CIS-3200', 'MATH-2400', 'PHIL-0010']
  fall 2028    ['CIS-4710']
unplaced: []
```

## The sketch

```python
"""A SKETCH, not app code. Settles one question: can a small rule tree with
explicit sharing, a greedy allocator and a prerequisite-aware term planner
express a Penn-shaped program and produce a sane what-if? Python because the
container has no Swift toolchain. ~150 lines on purpose."""
from dataclasses import dataclass, field
from typing import Optional

# ---- rule model (mirrors docs/research/degree-progress/05 section 6) ----
@dataclass
class Match:
    codes: set = field(default_factory=set)
    dept: Optional[str] = None
    number_range: Optional[tuple] = None
    attribute: Optional[str] = None
    except_codes: set = field(default_factory=set)
    def accepts(self, course):
        if course.code in self.except_codes: return False
        if self.codes and course.code in self.codes: return True
        if self.dept and course.code.split("-")[0] == self.dept:
            n = int(course.code.split("-")[1])
            lo, hi = self.number_range or (0, 9999)
            if lo <= n <= hi: return True
        if self.attribute and self.attribute in course.attributes: return True
        return False

@dataclass
class Rule:
    id: str; title: str
    need_courses: Optional[int] = None; need_credits: Optional[float] = None
    children: list = field(default_factory=list)   # non-leaf
    need_children: Optional[int] = None            # N-of children; None = all
    match: Optional[Match] = None                  # leaf
    share: set = field(default_factory=set)        # rule ids it may share a course with
    def is_leaf(self): return self.match is not None

@dataclass
class Course:
    code: str; cu: float = 1.0; attributes: set = field(default_factory=set)
    prereqs: list = field(default_factory=list)    # list of alternatives: [["CIS-1200"], ["MATH-1400","MATH-1410"]]
    offered: set = field(default_factory=lambda: {"fall", "spring"})
    status: str = "taken"                           # taken | in_progress | planned

def leaves(rule):
    return [rule] if rule.is_leaf() else [l for c in rule.children for l in leaves(c)]

# ---- allocation: greedy by "most still needed", honouring sharing ----
def allocate(program, courses):
    ls = leaves(program)
    applied = {l.id: [] for l in ls}
    def shortfall(l):
        got_c = len(applied[l.id]); got_cu = sum(c.cu for c in applied[l.id])
        return max((l.need_courses or 0) - got_c, 0) + max((l.need_credits or 0) - got_cu, 0)
    for course in sorted(courses, key=lambda c: c.code):
        eligible = [l for l in ls if l.match.accepts(course)]
        used_by = []
        for l in sorted(eligible, key=shortfall, reverse=True):
            if shortfall(l) <= 0: continue
            if all(l.id in u.share and u.id in l.share for u in used_by):   # symmetric sharing only
                applied[l.id].append(course); used_by.append(l)
    return applied

def evaluate(rule, applied):
    if rule.is_leaf():
        got = applied[rule.id]
        c_ok = rule.need_courses is None or len(got) >= rule.need_courses
        cu_ok = rule.need_credits is None or sum(c.cu for c in got) >= rule.need_credits
        return c_ok and cu_ok
    sat = [evaluate(c, applied) for c in rule.children]
    need = rule.need_children if rule.need_children is not None else len(sat)
    return sum(sat) >= need

# ---- what-if planner: fill shortfalls, order by prereqs, offering, CU cap ----
def plan(program, catalog, have, start_term=("fall", 2027), cap=5.0, max_terms=8):
    applied = allocate(program, have)
    have_codes = {c.code for c in have}
    todo = []
    for l in leaves(program):
        short = max((l.need_courses or 0) - len(applied[l.id]), 0)
        pool = [c for c in catalog.values() if l.match.accepts(c) and c.code not in have_codes and c not in todo]
        todo += sorted(pool, key=lambda c: c.code)[:short]   # pick the lowest-numbered eligible; a real planner would weigh prereq chains
    terms, season, year = [], start_term[0], start_term[1]
    done = set(have_codes)
    for _ in range(max_terms):
        if not todo: break
        this, load = [], 0.0
        def ready(c): return all(any(p in done for p in alt) for alt in c.prereqs)
        for c in sorted(todo, key=lambda c: -chain_len(c, catalog)):
            if season in c.offered and ready(c) and load + c.cu <= cap:
                this.append(c); load += c.cu
        for c in this: todo.remove(c); done.add(c.code)
        terms.append((f"{season} {year}", [c.code for c in this]))
        season, year = ("spring", year + 1) if season == "fall" else ("fall", year)
    return terms, todo   # todo left over = could not be placed (infeasible or needs more terms)

def chain_len(c, catalog, seen=None):
    seen = seen or set()
    if not c.prereqs or c.code in seen: return 0
    return 1 + max((chain_len(catalog[p], catalog, seen | {c.code}) for alt in c.prereqs for p in alt if p in catalog), default=0)

# ---- a toy, Penn-shaped program (invented numbers, NOT the real CIS BSE) ----
if __name__ == "__main__":
    cat = {c.code: c for c in [
        Course("CIS-1200", prereqs=[], offered={"fall","spring"}),
        Course("CIS-1600"), Course("CIS-1210", prereqs=[["CIS-1200"],["CIS-1600"]]),
        Course("CIS-2400", prereqs=[["CIS-1200"]]), Course("CIS-2620", prereqs=[["CIS-1600"]], offered={"fall"}),
        Course("CIS-3200", prereqs=[["CIS-1210"],["CIS-1600"]], offered={"spring"}),
        Course("CIS-4710", prereqs=[["CIS-2400"]], offered={"fall"}),
        Course("MATH-1400"), Course("MATH-1410", prereqs=[["MATH-1400"]]), Course("MATH-2400", prereqs=[["MATH-1410"]]),
        Course("PHYS-0150", cu=1.5), Course("PHYS-0151", cu=1.5, prereqs=[["PHYS-0150"]]),
        Course("WRIT-0020", attributes={"AUWR"}), Course("HIST-0100", attributes={"AU16"}), Course("PHIL-0010", attributes={"AU16"}),
        Course("ECON-0100", attributes={"AU16"}),
    ]}
    core = Rule("core", "cis core", need_courses=5, match=Match(codes={"CIS-1200","CIS-1600","CIS-1210","CIS-2400","CIS-2620","CIS-3200"}))
    upper = Rule("upper", "cis electives 3000+", need_courses=2, match=Match(dept="CIS", number_range=(3000, 5999)), share={"core"})
    core.share = {"upper"}   # a 3000-level core course may also count as an elective (toy rule)
    math = Rule("math", "math", need_courses=3, match=Match(dept="MATH", number_range=(1400, 2999)))
    sci = Rule("sci", "natural science", need_credits=3.0, match=Match(dept="PHYS"))
    writing = Rule("writ", "writing seminar", need_courses=1, match=Match(attribute="AUWR"))
    ssh = Rule("ssh", "social science / humanities", need_courses=3, match=Match(attribute="AU16"))
    program = Rule("cis-bse-toy", "toy CIS BSE", children=[core, upper, math, sci, writing, ssh])

    def taken(*codes): return [cat[c] for c in codes]
    have = taken("CIS-1200", "CIS-1600", "MATH-1400", "WRIT-0020", "PHYS-0150", "HIST-0100")
    applied = allocate(program, have)
    for l in leaves(program):
        print(f"{l.title:32} {'met' if evaluate(l, applied) else 'open':4}  {[c.code for c in applied[l.id]]}")
    print("program met:", evaluate(program, applied))
    terms, left = plan(program, cat, have)
    for t, cs in terms: print(f"  {t:12} {cs}")
    print("unplaced:", [c.code for c in left])
```
