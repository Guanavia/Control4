// Decompile GetCreationFunc (and GetAgentName) and follow into the actual creation/constructor code.
// @category Control4

import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.symbol.SymbolTable;
import ghidra.program.model.symbol.Symbol;
import ghidra.util.task.ConsoleTaskMonitor;

import java.util.*;

public class TraceCreation extends GhidraScript {

    @Override
    public void run() throws Exception {
        FunctionManager fm = currentProgram.getFunctionManager();
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        ConsoleTaskMonitor monitor2 = new ConsoleTaskMonitor();

        for (String name : new String[]{"GetCreationFunc", "GetAgentName"}) {
            println("\n\n===== Looking for: " + name + " =====");
            List<Function> matches = new ArrayList<>();
            for (Function f : fm.getFunctions(true)) {
                if (f.getName().equals(name)) matches.add(f);
            }
            if (matches.isEmpty()) {
                println("NOT FOUND as a function; trying symbol table...");
                SymbolTable st = currentProgram.getSymbolTable();
                for (Symbol s : st.getSymbols(name)) {
                    println("symbol: " + s + " @ " + s.getAddress());
                    Function f = fm.getFunctionAt(s.getAddress());
                    if (f != null) matches.add(f);
                }
            }
            for (Function f : matches) {
                println("Function: " + f.getName() + " @ " + f.getEntryPoint());
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
            }
        }

        decomp.dispose();
        println("\n\nDONE");
    }
}
