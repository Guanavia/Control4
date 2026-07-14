import os, re

SCRATCH = r"C:\Users\David\AppData\Local\Temp\claude\c--Users-David-OneDrive-Documents-GitHub-Control4-better-composer\e9dd508c-3805-4f57-b20b-5e956b545996\scratchpad"
DLL_DIR = os.path.join(SCRATCH, "agent_dlls")

GENERIC_BASES = {
    "C4BaseDriver", "C4BaseAgentDriver", "CmdDispatcher", "CondDispatcher",
    "C4TypesManager", "PluginXManager",
}

PATTERN = re.compile(rb"[A-Za-z_][A-Za-z0-9_]{2,40}::(?:ExecuteCommand|TestCondition|ExecuteCmd|HandleConditional)")

results = {}
for fn in sorted(os.listdir(DLL_DIR)):
    if not fn.endswith(".c4w"):
        continue
    path = os.path.join(DLL_DIR, fn)
    data = open(path, "rb").read()
    matches = set(m.group(0).decode("latin-1") for m in PATTERN.finditer(data))
    own_classes = set()
    for m in matches:
        cls = m.split("::")[0]
        if cls not in GENERIC_BASES:
            own_classes.add(cls)
    results[fn] = (own_classes, matches)

legacy = []
modern = []
for fn, (own, allm) in results.items():
    if own:
        legacy.append((fn, own))
    else:
        modern.append((fn, allm))

print("=== LEGACY STYLE (own dispatch override found):", len(legacy), "===")
for fn, own in legacy:
    print(f"  {fn}: {sorted(own)}")

print("\n=== MODERN STYLE (generic dispatcher only, or nothing found):", len(modern), "===")
for fn, allm in modern:
    print(f"  {fn}: {sorted(allm) if allm else '(no dispatch strings at all)'}")
