#!/usr/bin/env python3
"""Score the model's congestion against an ISO's real binding constraints (REVIEW EXT-1).

    mix power_model.loadings --interconnection ERCOT --out /tmp/ercot.csv --buses /tmp/ercot_buses.csv
    python3 scripts/score_congestion.py --iso ercot --loadings /tmp/ercot.csv --buses /tmp/ercot_buses.csv

Inputs (vendored): the ISO's binding-constraint record (data/vendored/*binding_constraints*.csv) and
OSM's named substations (data/vendored/osm_substations_2026-08-18.json) as the geocoding bridge.
Method: each real constraint element (station A, station B, kV) is geocoded through OSM yard names
(ERCOT short-name rules: strip SW/SES suffixes and digits, first-three-letter + subsequence match, prefer
yards tagged with the kV), located in the model as buses within 1.5 km at that class, and looked for as a
path of <= 4 branches at that class between the two stations. Reported: how many elements geocode, how
many exist, the model's loading of the ones that exist and its percentile rank, how many sit on inferred
capacity; and the reverse — how many of the model's top-N loaded branches have both yards among the ISO's
constraint stations. Stdlib only.
"""
import argparse, csv, re, json, math, collections, difflib, sys
ISO={'ercot':dict(file='data/vendored/ercot_sced_binding_constraints_2026-08-28_09-01.csv', bbox=(25.5,-107,36.6,-93.4)),
     'miso':dict(file='data/vendored/miso_rt_binding_constraints_2024-12-25_2025-01-01.csv', bbox=(28,-105,50,-80))}
STOP=r'\b(SUB|SUBSTATION|STATION|SWITCHING|SWITCHYARD|SWITCH|SW|SS|TAP|POWER PLANT|PLANT|SES|GENERATING|ELECTRIC|ENERGY CENTER|TC|HY|KV)\b'
def norm(s):
    s=s.upper().replace('&',' AND ').replace('.',' '); s=re.sub(r'\(.*?\)',' ',s); s=re.sub(r'[^A-Z0-9 ]+',' ',s)
    s=re.sub(STOP,' ',s); return re.sub(r'\s+',' ',s).strip()
def is_subseq(a,b):
    it=iter(b); return all(c in it for c in a)
def km(a,b):
    la1,lo1,la2,lo2=map(math.radians,(a[0],a[1],b[0],b[1])); return 6371*math.hypot((lo2-lo1)*math.cos((la1+la2)/2),la2-la1)
def load_osm(path,bbox):
    byname=collections.defaultdict(list)
    for e in json.load(open(path))['elements']:
        t=e.get('tags',{}); n=t.get('name'); c=e.get('center',e)
        if not n or c.get('lat') is None: continue
        if not (bbox[0]<c['lat']<bbox[2] and bbox[1]<c['lon']<bbox[3]): continue
        nn=norm(n)
        if nn: byname[nn].append({'name':n,'lat':c['lat'],'lon':c['lon'],'kvs':[int(x)/1000 for x in re.findall(r'\d{4,6}',t.get('voltage','') or '')]})
    return byname
def geocode(byname,names,tok,kv):
    raw=tok.upper().replace('_',' ')
    for v in (raw, re.sub(r'(SW|SWS|SES|SS)$','',raw), re.sub(r'\d+$','',raw), re.sub(r'^(S|N|E|W|MV|I|TN)\s*','',raw)):
        t=norm(v); tk=t.replace(' ','')
        if len(tk)<3: continue
        if t in byname: c=byname[t]
        else:
            c=[o for n in names if n.replace(' ','')[:3]==tk[:3] and is_subseq(tk,n.replace(' ','')) for o in byname[n]]
            if not c: c=[o for n in names if n.replace(' ','').startswith(tk[:5]) for o in byname[n]]
            if not c and len(tk)>=4: c=[o for n in names if n.replace(' ','')[0]==tk[0] and is_subseq(tk,n.replace(' ','')) and len(n.replace(' ',''))<=2.5*len(tk) for o in byname[n]]
        if c: return [o for o in c if any(abs(k-kv)<kv*0.15 for k in o['kvs'])] or c
    return [o for n in difflib.get_close_matches(norm(raw),names,n=2,cutoff=0.85) for o in byname[n]]
def constraints(iso,path):
    items=[]
    rows=list(csv.DictReader(open(path)))
    if iso=='ercot':
        agg=collections.Counter((r['FromStation'],r['ToStation'],r['FromStationkV']) for r in rows if r['FromStation'] and float(r['FromStationkV'] or 0)>=60)
        for (a,b,kv),n in agg.most_common(): items.append((f"{a}-{b} {kv}kV",a,b,float(kv),n))
    else:
        for c,n in collections.Counter(r['contingency'] for r in rows if r['contingency']).most_common():
            m=re.match(r'^(.*?)\s*[-–]\s*(.*?)\s+(\d{3})\b',c)
            if m: items.append((c,m.group(1),m.group(2),float(m.group(3)),n))
        for bn,n in collections.Counter(r['branch_name'] for r in rows if not r['branch_name'].startswith('INTF')).most_common():
            mm=re.match(r'^(\S+)\s+(\S+)\s+(\S+)\s+\((\w+)/',bn)
            if not mm: continue
            st,elem,_,typ=mm.groups(); kvm=re.search(r'(\d{3})',elem); kv=float(kvm.group(1)) if kvm else 138.0
            if typ=='XF': items.append((f"XF {bn}",st,st,kv,n))
            else: items.append((f"LN {bn}",st,re.sub(r'[\d_]+$','',re.sub(r'^'+re.escape(st[:4]),'',elem.upper())),kv,n))
    return items
def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--iso',required=True,choices=ISO); ap.add_argument('--loadings',required=True); ap.add_argument('--buses',required=True)
    ap.add_argument('--osm',default='data/vendored/osm_substations_2026-08-18.json'); ap.add_argument('--top',type=int,default=30); ap.add_argument('--quiet',action='store_true')
    a=ap.parse_args(); cfg=ISO[a.iso]
    byname=load_osm(a.osm,cfg['bbox']); names=list(byname)
    buses={r['id']:(float(r['kv']),float(r['lat']),float(r['lon'])) for r in csv.DictReader(open(a.buses))}
    model=list(csv.DictReader(open(a.loadings)))
    adj=collections.defaultdict(list)
    for r in model: adj[r['from_bus_id']].append((r['to_bus_id'],r)); adj[r['to_bus_id']].append((r['from_bus_id'],r))
    def bkv(r):
        try: return float(r['kv'].split('/')[0])
        except: return None
    def near(os_,kv): return {b for o in os_ for b,(k,la,lo) in buses.items() if abs(k-kv)<kv*0.15 and km((o['lat'],o['lon']),(la,lo))<1.5}
    def path(S,G,kv):
        best=None
        for s in S:
            fr=[(s,[],0)]; seen={s}
            while fr:
                b,p,d=fr.pop(0)
                if d>=4: continue
                for nb,r in adj[b]:
                    k=bkv(r) or kv
                    if abs(k-kv)>kv*0.15 or nb in seen: continue
                    q=p+[r]
                    if nb in G:
                        t=max(q,key=lambda x:float(x['dc_loading_pct'] or 0))
                        if best is None or float(t['dc_loading_pct'] or 0)>float(best['dc_loading_pct'] or 0): best=t
                    else: seen.add(nb); fr.append((nb,q,d+1))
        return best
    items=constraints(a.iso,cfg['file']); total=len(items); located=found=inferred=0; loads=[]
    for label,x,y,kv,w in items:
        ox,oy=geocode(byname,names,x,kv),geocode(byname,names,y,kv)
        if not ox or not oy:
            if not a.quiet: print(f"  [nogeo ] {label} x{w}"); 
            continue
        located+=1; sx,sy=near(ox,kv),near(oy,kv)
        if not sx or not sy:
            if not a.quiet: print(f"  [nobus ] {label} x{w}  {ox[0]['name']}({len(sx)}) / {oy[0]['name']}({len(sy)})")
            continue
        best=path(sx,sy,kv) if x!=y and not (sx&sy) else max((r for s in sx for (_,r) in adj[s]),key=lambda r:float(r['dc_loading_pct'] or 0),default=None)
        if best:
            found+=1; l=float(best['dc_loading_pct'] or 0); loads.append(l); inferred+=int(best['inferred_circuits'] or 1)>1
            if not a.quiet: print(f"  [FOUND ] {label} x{w} -> {best['id']} {best['sub_1']}-{best['sub_2']} {best['kv']}kV dc {best['dc_loading_pct']}% n{best['inferred_circuits']}")
        elif not a.quiet: print(f"  [nopath] {label} x{w}  {ox[0]['name']} / {oy[0]['name']}")
    allloads=sorted((float(r['dc_loading_pct'] or 0) for r in model),reverse=True)
    pr=lambda v:100.0*sum(1 for u in allloads if u>v)/len(allloads)
    print(f"\n== {a.iso.upper()} real binding elements: {total}; geocoded both ends {located}; exist in model {found} ({100*found/max(located,1):.0f}% of located)")
    if loads:
        ranks=sorted(pr(v) for v in loads)
        print(f"   model DC loading of those: median {sorted(loads)[len(loads)//2]:.0f}%, mean {sum(loads)/len(loads):.0f}%; median percentile rank {ranks[len(ranks)//2]:.1f}% (0 = most loaded); in model top 5%: {sum(1 for v in ranks if v<5)}/{len(ranks)}; on inferred capacity: {inferred}/{found}")
    # reverse
    stations=set()
    for label,x,y,kv,w in items:
        for tok in (x,y):
            s=tok.upper().replace('_',' ')
            for v in (s,re.sub(r'(SW|SWS|SES)$','',s),re.sub(r'\d+$','',s)):
                t=norm(v).replace(' ','')
                if len(t)>=3: stations.add(t)
    osm_pts=[(n,o['lat'],o['lon']) for n,os_ in byname.items() for o in os_]
    def yard_names(bid):
        if bid not in buses: return []
        _,la,lo=buses[bid]; return [n for n,ola,olo in osm_pts if km((la,lo),(ola,olo))<1.5]
    def in_list(ns): return any(n.replace(' ','').startswith(s[:5]) or (s[:3]==n.replace(' ','')[:3] and is_subseq(s,n.replace(' ',''))) for n in ns for s in stations)
    top=[r for r in model if not r['id'].startswith('T') and (bkv(r) or 0)>=69]; top.sort(key=lambda r:-float(r['dc_loading_pct'] or 0))
    geo=hits=0
    for r in top[:a.top]:
        A,B=yard_names(r['from_bus_id']),yard_names(r['to_bus_id']); geo+=bool(A and B); hits+=bool(A and B and in_list(A) and in_list(B))
    print(f"== reverse: of the model's top-{a.top} loaded branches (>=69 kV), {geo} have named yards at both ends and {hits} have both yards among the ISO's constraint stations")
if __name__=='__main__': main()
