import os, re, json

SCRATCH = r"C:\Users\David\AppData\Local\Temp\claude\c--Users-David-OneDrive-Documents-GitHub-Control4-better-composer\e9dd508c-3805-4f57-b20b-5e956b545996\scratchpad"
OUT_DIR = r"C:\Users\David\OneDrive\Documents\GitHub\Control4\better_composer\research\agent_vocab"

header_re = re.compile(r"=== GLOBAL UNIQUE SHAPED TOKENS: (\d+) ===")

for fn in sorted(os.listdir(SCRATCH)):
    if not fn.startswith("vocabF_") or not fn.endswith(".log"):
        continue
    agent = fn[len("vocabF_"):-len(".log")]
    path = os.path.join(SCRATCH, fn)
    lines = open(path, encoding="utf-8", errors="replace").readlines()
    count = None
    tokens = []
    for i, line in enumerate(lines):
        m = header_re.search(line)
        if m:
            count = int(m.group(1))
            # token list is on a subsequent non-blank "ExtractVocab.java> ..." line
            for j in range(i + 1, min(i + 5, len(lines))):
                if "ExtractVocab.java>" in lines[j]:
                    content = lines[j].split("ExtractVocab.java>", 1)[1]
                    content = content.rsplit("(GhidraScript)", 1)[0].strip()
                    if content:
                        tokens = [t.strip() for t in content.split(",") if t.strip()]
                        break
            break
    if count is None:
        print(f"{agent}: no GLOBAL UNIQUE section found (still running or failed)")
        continue
    out_path = os.path.join(OUT_DIR, f"{agent}.raw_tokens.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({
            "agent": agent,
            "extraction_method": "ExtractVocab.java v2 (dual-pattern + stoplist), raw/uncurated",
            "note": "Unfiltered token list -- includes real per-agent vocab mixed with residual shared-library noise not yet in the stoplist. Needs manual curation into commands/conditionals/params like control4_agent_scheduler.json.",
            "token_count": count,
            "tokens": tokens,
        }, f, indent=2)
    print(f"{agent}: {count} tokens -> {out_path}")
