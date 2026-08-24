#!/usr/bin/env bash
# Pure query planning and candidate identity evidence; JSON in, JSON out.

variants_matching_plan_queries() {
  python3 -c '
import json,sys,re,unicodedata
d=json.load(sys.stdin); ss=d.get("seeds",d if isinstance(d,list) else [])
def f(x): return unicodedata.normalize("NFKC",str(x or "")).casefold()
def tags(m): return [x for x in (m.get("tags") or []) if isinstance(x,str)]
def norm(s):
 s=f(s)
 def br(m): return m.group(1) if re.search(r"(?:vol(?:ume)?\.?|v|part|pt)\s*[-._ ]*\d+",m.group(1)) else " "
 s=re.sub(r"\[([^\]]+)\]",br,s); s=re.sub(r"\b(?:creator|language|translator|digital|edition)\b"," ",s); return s
def eligible(x): return len(x)>= (2 if any("\u3040"<=c<="\u30ff" or "\u3400"<=c<="\u9fff" for c in x) else 3)
def terms(m):
 out=[]
 for field in ("title","title_jpn"):
  s=norm(m.get(field)); vr=r"(?:vol(?:ume)?\.?|v|part|pt)\s*[-._ ]*\d+"; out += [re.sub(r"[-._ ]+","_",x) for x in re.findall(vr,s)]; s=re.sub(vr," ",s); out += re.findall(r"[\u3040-\u30ff\u3400-\u9fff]+|[^\W_]+",s,re.UNICODE)
 return sorted({x for x in out if eligible(x)},key=lambda x:(-len(x),x))[:3]
queries={}
def add(q,origin): queries.setdefault(q,set()).add(origin)
for m in sorted(ss,key=lambda x:int(x.get("gid",0))):
 gid=int(m.get("gid",0))
 for c in sorted({x for x in tags(m) if x.startswith("artist:") or x.startswith("group:")}): add("language:chinese$ other:tankoubon$ "+c.replace(" ","_")+"$","creator:"+str(gid)+":"+c)
 ws=terms(m)
 while ws and len("language:chinese$ other:tankoubon$ "+" ".join("title:"+x for x in ws))>200: ws.pop()
 if ws: add("language:chinese$ other:tankoubon$ "+" ".join("title:"+x for x in ws),"title:"+str(gid))
out=[{"query":q,"origins":sorted(o)} for q,o in sorted(queries.items())]
print(json.dumps({"queries":out},ensure_ascii=False,sort_keys=True,separators=(",",":")))
'
}

variants_matching_scope_json() {
  python3 -c '
import json,sys
m=json.load(sys.stdin); t=set(m.get("tags") or []); r={"language:chinese","other:tankoubon"}; print(json.dumps({"in_scope":r<=t,"required":sorted(r),"tags":sorted(t)},sort_keys=True,separators=(",",":")))
'
}

variants_matching_evidence_json() {
  python3 -c '
import json,sys,re,unicodedata,math
d=json.load(sys.stdin); a=d.get("source",{}); b=d.get("candidate",{})
def f(x): return unicodedata.normalize("NFKC",str(x or "")).casefold()
def tok(x): return set(re.findall(r"[\w]+",f(x),re.UNICODE))
def bi(x):
 z=[c for c in f(x) if not c.isspace() and not unicodedata.category(c).startswith("P")]; return set(zip(z,z[1:]))
def dice(x,y): return 1.0 if x==y and x else (2*len(x&y)/float(len(x)+len(y)) if x and y else 0.0)
def ts(m): return {x for x in (m.get("tags") or []) if isinstance(x,str)}
def cr(m): return {x for x in ts(m) if x.startswith("artist:") or x.startswith("group:")}
def n(m):
 for k in ("filecount","file_count","pages"):
  try:
   if m.get(k) is not None:return int(m[k])
  except (TypeError,ValueError): pass
 return None
def pts(x,y,z): return int(math.floor(x*y+0.5)) if z else 0
at,bt=tok(a.get("title")),tok(b.get("title")); aj,bj=bi(a.get("title_jpn")),bi(b.get("title_jpn")); tr=max(dice(at,bt),dice(aj,bj)); tp=pts(tr,40,bool(at or aj) and bool(bt or bj))
ac,bc=cr(a),cr(b); common=ac&bc; co=1.0 if common else 0.0; cp=30 if common else 0; ns={"parody","character","male","female","mixed"}; ax={x for x in ts(a) if x.split(":",1)[0] in ns}; bx={x for x in ts(b) if x.split(":",1)[0] in ns}; cj=len(ax&bx)/float(len(ax|bx)) if ax|bx else 0; cjp=pts(cj,20,bool(ax|bx)); af,bf=n(a),n(b); pg=min(af,bf)/float(max(af,bf)) if af is not None and bf is not None and max(af,bf)>0 else 0; pp=pts(pg,10,af is not None and bf is not None)
ct=[]
if ac and bc and not common: ct.append("disjoint_creator_sets")
if a.get("category") is not None and b.get("category") is not None and f(a.get("category"))!=f(b.get("category")): ct.append("category_mismatch")
def vp(m): return set(sum((re.findall(r"(?:vol(?:ume)?\.?|v|part|pt)\s*[-._ ]*\d+",f(m.get(k))) for k in ("title","title_jpn")),[]))
if vp(a) and vp(b) and vp(a).isdisjoint(vp(b)): ct.append("title_volume_part_conflict")
if not a.get("title") or not b.get("title") or not (ac|bc): ct.append("missing_evidence")
scope={"language:chinese","other:tankoubon"}<=ts(b); gid=b.get("gid"); chain={int(x) for x in d.get("chain_gids",[]) if str(x).isdigit()}; official=str(gid).isdigit() and int(gid) in chain; cat="official_chain" if official and scope else ("rejected_out_of_scope_chain" if official else ("independent" if scope else "out_of_scope"))
o={"gid":gid,"category":cat,"in_scope":scope,"official_chain":official,"reviewable":scope and not official,"score":tp+cp+cjp+pp,"raw":{"title_similarity":tr,"creator_overlap":co,"content_tag_jaccard":cj,"page_proximity":pg},"normalized":{"title_tokens_source":sorted(at),"title_tokens_candidate":sorted(bt),"japanese_bigrams_shared":len(aj&bj),"creators_source":sorted(ac),"creators_candidate":sorted(bc),"content_tags_source":sorted(ax),"content_tags_candidate":sorted(bx),"page_counts":[af,bf]},"components":{"title":{"points":tp,"max":40},"creator":{"points":cp,"max":30},"content_tags":{"points":cjp,"max":20},"page_proximity":{"points":pp,"max":10}},"contradictions":sorted(set(ct)),"origins":d.get("origins",[])}
print(json.dumps(o,ensure_ascii=False,sort_keys=True,separators=(",",":")))
'
}
