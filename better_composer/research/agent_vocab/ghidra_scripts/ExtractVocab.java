// Decompile every function, extract PTR_s_<NAME> string-reference tokens, rank by count.
// High-count functions are command/event/conditional dispatchers; their tokens are the vocab.
// @category Control4

import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.util.task.ConsoleTaskMonitor;

import java.util.*;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class ExtractVocab extends GhidraScript {

    static final Pattern TOKEN_PATTERN = Pattern.compile("PTR_s_([A-Za-z0-9_]+?)_[0-9a-fA-F]{6,10}\\b");
    // Ghidra sometimes inlines a short/single-use string as a literal "TEXT" in the decompiled C
    // instead of naming a PTR_s_ pointer (this is actually the MORE common case for one-off
    // registration calls) -- catch that form too.
    static final Pattern LITERAL_PATTERN = Pattern.compile("\"([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)\"");
    // Control4 command/param/event tokens are ALL_CAPS_WITH_UNDERSCORES; require an underscore to
    // filter out protobuf type-name noise (int32/string/etc) and single generic words (ERROR).
    static final Pattern SHAPE = Pattern.compile("^[A-Z][A-Z0-9]*(_[A-Z0-9]+)+$");
    static final int MIN_TOKENS = 1; // per-command registration is often its own small function

    // Known non-Control4 noise: OpenSSL/XML/SOAP/crypto constants that happen to match the shape.
    static final Set<String> STOPLIST = new HashSet<>(Arrays.asList(
        "SOAP_ENV", "AES_128_WRAP", "AES_192_WRAP", "AES_256_WRAP", "ENCRYPTED_PRIVATE_KEY",
        "PRIVATE_KEY", "PUBLIC_KEY", "RSA_PRIVATE_KEY", "RSA_PUBLIC_KEY", "EC_PRIVATE_KEY",
        "X509_CERTIFICATE", "CERTIFICATE_REQUEST", "TRUSTED_CERTIFICATE", "NEW_CERTIFICATE_REQUEST",
        "PKCS7", "PKCS8", "UTF_8", "UTF_16", "CDATA_SECTION"
    ));

    @Override
    public void run() throws Exception {
        FunctionManager fm = currentProgram.getFunctionManager();
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        ConsoleTaskMonitor monitor2 = new ConsoleTaskMonitor();

        List<Function> allFuncs = new ArrayList<>();
        for (Function f : fm.getFunctions(true)) {
            allFuncs.add(f);
        }
        println("Total functions: " + allFuncs.size());

        Map<Function, LinkedHashSet<String>> results = new LinkedHashMap<>();
        TreeSet<String> globalTokens = new TreeSet<>();

        int done = 0;
        for (Function f : allFuncs) {
            done++;
            if (done % 500 == 0) println("...progress " + done + "/" + allFuncs.size());
            try {
                DecompileResults res = decomp.decompileFunction(f, 30, monitor2);
                if (!res.decompileCompleted()) continue;
                String c = res.getDecompiledFunction().getC();
                LinkedHashSet<String> tokens = new LinkedHashSet<>();
                for (Pattern p : new Pattern[]{TOKEN_PATTERN, LITERAL_PATTERN}) {
                    Matcher m = p.matcher(c);
                    while (m.find()) {
                        String tok = m.group(1);
                        if (SHAPE.matcher(tok).matches() && !STOPLIST.contains(tok)) {
                            tokens.add(tok);
                        }
                    }
                }
                if (tokens.size() >= MIN_TOKENS) {
                    results.put(f, tokens);
                    globalTokens.addAll(tokens);
                }
            } catch (Exception e) {
                // skip
            }
        }

        println("\n\n=== GLOBAL UNIQUE SHAPED TOKENS: " + globalTokens.size() + " ===");
        println(String.join(", ", globalTokens));

        println("\n\n=== FUNCTIONS WITH SHAPED TOKENS: " + results.size() + " ===");
        List<Map.Entry<Function, LinkedHashSet<String>>> sorted = new ArrayList<>(results.entrySet());
        sorted.sort((a, b) -> b.getValue().size() - a.getValue().size());
        for (Map.Entry<Function, LinkedHashSet<String>> e : sorted) {
            println("\n--- " + e.getKey().getName() + " @ " + e.getKey().getEntryPoint() + " (" + e.getValue().size() + " tokens) ---");
            println(String.join(", ", e.getValue()));
        }

        decomp.dispose();
        println("\n\nDONE");
    }
}
