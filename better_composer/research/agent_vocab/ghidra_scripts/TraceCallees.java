// Starting from a named function, decompile it and recursively decompile its callees up to a depth limit.
// @category Control4

import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.util.task.ConsoleTaskMonitor;

import java.util.*;

public class TraceCallees extends GhidraScript {

    static final int MAX_DEPTH = 3;
    static final int MAX_FUNCS = 60;

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        String startName = (args.length > 0) ? args[0] : "FUN_10056f50";
        FunctionManager fm = currentProgram.getFunctionManager();
        Function start = null;
        for (Function f : fm.getFunctions(true)) {
            if (f.getName().equals(startName)) { start = f; break; }
        }
        if (start == null) {
            println("Could not find function: " + startName);
            return;
        }

        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        ConsoleTaskMonitor monitor2 = new ConsoleTaskMonitor();

        Set<Function> visited = new LinkedHashSet<>();
        Deque<Object[]> queue = new ArrayDeque<>(); // {Function, depth}
        queue.add(new Object[]{start, 0});

        while (!queue.isEmpty() && visited.size() < MAX_FUNCS) {
            Object[] item = queue.poll();
            Function f = (Function) item[0];
            int depth = (Integer) item[1];
            if (visited.contains(f)) continue;
            visited.add(f);

            println("\n\n===== [depth " + depth + "] " + f.getName() + " @ " + f.getEntryPoint() + " =====");
            try {
                DecompileResults res = decomp.decompileFunction(f, 30, monitor2);
                if (res.decompileCompleted()) {
                    println(res.getDecompiledFunction().getC());
                } else {
                    println("DECOMPILE FAILED: " + res.getErrorMessage());
                }
            } catch (Exception e) {
                println("EXCEPTION: " + e);
            }

            if (depth < MAX_DEPTH) {
                for (Function callee : f.getCalledFunctions(monitor2)) {
                    if (!visited.contains(callee)) {
                        queue.add(new Object[]{callee, depth + 1});
                    }
                }
            }
        }

        decomp.dispose();
        println("\n\nVisited " + visited.size() + " functions. DONE");
    }
}
