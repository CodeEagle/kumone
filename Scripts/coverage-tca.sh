#!/bin/bash
# 导出 KumoneTCA 单元测试覆盖率（行级未覆盖清单）
# 用法： scripts/coverage-tca.sh [输出json]
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-/tmp/tca_cov.json}"
swift test --enable-code-coverage --filter KumoneTCATests >/dev/null 2>&1 || true

BIN=.build/out/Products/Debug
PROFDATA=$(find .build -name 'default.profdata' | head -1)
XCTEST=$BIN/KumoneTCATests.xctest/Contents/MacOS/KumoneTCATests

xcrun llvm-cov export -format=text -instr-profile="$PROFDATA" "$XCTEST" -arch arm64 > "$OUT"

python3 - "$OUT" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
files={}
for data in d['data']:
    for f in data['files']:
        n=f['filename']
        if '/Sources/KumoneTCA/' not in n: continue
        short=n.split('/KumoneTCA/')[-1]
        unc=set()
        for seg in f['segments']:
            # [line, col, count, hasCount, ...]; hasCount && count==0 => 未覆盖
            if seg[3] and seg[2]==0: unc.add(seg[0])
        covered=f['summary']['lines']['covered']; total=f['summary']['lines']['count']
        files[short]=(sorted(unc), covered, total)
tc=sum(v[1] for v in files.values()); tt=sum(v[2] for v in files.values())
print(f"KumoneTCA: {tc}/{tt} = {100.0*tc/tt:.1f}%\n")
for k in sorted(files, key=lambda k:-len(files[k][0])):
    v=files[k]
    if not v[0]: continue
    print(f"### {k} ({len(v[0])} unc, {100.0*v[1]/max(v[2],1):.1f}%)")
    r=[]; s=pv=v[0][0]
    for x in v[0][1:]:
        if x==pv+1: pv=x
        else: r.append((s,pv)); s=pv=x
    r.append((s,pv))
    print(", ".join(str(a) if a==b else f"{a}-{b}" for a,b in r)); print()
PY
