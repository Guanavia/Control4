// Find code that references key dispatcher-related strings, and decompile the containing functions.
// @category Control4

import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.*;
import ghidra.program.model.address.Address;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.util.task.ConsoleTaskMonitor;

import java.util.*;

public class FindDispatch extends GhidraScript {

    String[] TARGET_STRINGS = {
        "scheduler_agent::ExecuteCommand",
        "scheduler_agent::TestCondition",
        "CmdDispatcher::ExecuteCmd",
        "CondDispatcher::HandleConditional",
        "C4BaseDriver::TestCondition",
        "C4TypesManager::ProcessSyncBoundCall"
    };

    @Override
    public void run() throws Exception {
        Listing listing = currentProgram.getListing();
        FunctionManager fm = currentProgram.getFunctionManager();
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        ConsoleTaskMonitor monitor2 = new ConsoleTaskMonitor();

        Set<Function> toDecompile = new LinkedHashSet<>();

        DataIterator dataIter = listing.getDefinedData(true);
        while (dataIter.hasNext()) {
            Data d = dataIter.next();
            if (!d.hasStringValue()) continue;
            String val = d.getValue().toString();
            for (String target : TARGET_STRINGS) {
                if (val.contains(target)) {
                    Address strAddr = d.getAddress();
                    println("STRING '" + target + "' @ " + strAddr);
                    Reference[] refs = getReferencesTo(strAddr);
                    for (Reference r : refs) {
                        Address from = r.getFromAddress();
                        println("  referenced from " + from + " (" + r.getReferenceType() + ")");
                        Function f = fm.getFunctionContaining(from);
                        if (f == null) {
                            // try to find/create function at that location
                            try {
                                f = createFunction(from, null);
                                if (f != null) println("    created function: " + f.getName() + " @ " + f.getEntryPoint());
                            } catch (Exception e) {
                                println("    could not create function: " + e);
                            }
                        } else {
                            println("    inside function: " + f.getName() + " @ " + f.getEntryPoint());
                        }
                        if (f != null) toDecompile.add(f);
                    }
                }
            }
        }

        println("\n\n=== FUNCTIONS TO DECOMPILE: " + toDecompile.size() + " ===");
        for (Function f : toDecompile) {
            println("\n\n===== DECOMPILE: " + f.getName() + " @ " + f.getEntryPoint() + " =====");
            try {
                DecompileResults res = decomp.decompileFunction(f, 60, monitor2);
                if (res.decompileCompleted()) {
                    println(res.getDecompiledFunction().getC());
                } else {
                    println("DECOMPILE FAILED: " + res.getErrorMessage());
                }
            } catch (Exception e) {
                println("EXCEPTION: " + e);
            }
        }

        decomp.dispose();
        println("\n\nDONE");
    }
}
