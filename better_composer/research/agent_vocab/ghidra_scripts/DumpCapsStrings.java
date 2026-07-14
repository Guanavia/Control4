// Dump all ALL_CAPS_WITH_UNDERSCORES string data anywhere in the binary (command/param token shape).
// @category Control4

import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Listing;

import java.util.regex.Pattern;

public class DumpCapsStrings extends GhidraScript {

    static final Pattern SHAPE = Pattern.compile("^[A-Z][A-Z0-9_]{2,40}$");

    @Override
    public void run() throws Exception {
        Listing listing = currentProgram.getListing();
        DataIterator dataIter = listing.getDefinedData(true);
        int count = 0;
        int total = 0;
        while (dataIter.hasNext()) {
            Data d = dataIter.next();
            if (!d.hasStringValue()) continue;
            total++;
            Object val = d.getValue();
            if (val == null) continue;
            String s = val.toString();
            if (SHAPE.matcher(s).matches()) {
                println(d.getAddress() + ": " + s);
                count++;
            }
        }
        println("\n\nTotal string data items: " + total);
        println("ALL_CAPS-shaped matches: " + count);
        println("DONE");
    }
}
