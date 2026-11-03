// Original Axiom RE exporter. Uses upstream Ghidra APIs; no target execution.
// @category Axiom
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.block.*;
import com.google.gson.*;
import java.nio.file.*;

public class AxiomExport extends GhidraScript {
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 1) throw new IllegalArgumentException("Expected export path");
        JsonObject root = new JsonObject();
        root.addProperty("language", currentProgram.getLanguageID().toString());
        JsonArray functions = new JsonArray(); JsonArray warnings = new JsonArray();
        DecompInterface decompiler = new DecompInterface();
        try {
            if (!decompiler.openProgram(currentProgram)) throw new IllegalStateException(decompiler.getLastMessage());
            FunctionIterator iterator = currentProgram.getFunctionManager().getFunctions(true);
            int count = 0;
            while (iterator.hasNext() && !monitor.isCancelled()) {
                if (count++ >= 10000) { warnings.add("Function export limited to 10,000 entries."); break; }
                Function f = iterator.next(); JsonObject item = new JsonObject();
                item.addProperty("address", f.getEntryPoint().toString()); item.addProperty("name", f.getName());
                item.addProperty("signature", f.getSignature().toString()); item.addProperty("comment", f.getComment() == null ? "" : f.getComment());
                item.addProperty("engineName", f.getName());
                DecompileResults result = decompiler.decompileFunction(f, 15, monitor);
                item.addProperty("code", result.decompileCompleted() ? result.getDecompiledFunction().getC() : "");
                if (!result.decompileCompleted()) item.addProperty("error", result.getErrorMessage());
                StringBuilder assembly = new StringBuilder();
                InstructionIterator instructions = currentProgram.getListing().getInstructions(f.getBody(), true);
                int instructionCount = 0;
                while (instructions.hasNext()) {
                    if (instructionCount++ >= 4096) { assembly.append("[instruction listing truncated]\n"); break; }
                    Instruction instruction = instructions.next(); assembly.append(instruction.getAddress()).append("  ").append(instruction).append('\n');
                }
                item.addProperty("assembly", assembly.toString());
                JsonArray blocks = new JsonArray();
                CodeBlockIterator blockIterator = new BasicBlockModel(currentProgram).getCodeBlocksContaining(f.getBody(), monitor);
                while (blockIterator.hasNext()) {
                    if (blocks.size() >= 4096) { warnings.add("CFG truncated for " + f.getEntryPoint()); break; }
                    CodeBlock block = blockIterator.next(); JsonObject node = new JsonObject();
                    node.addProperty("address", block.getFirstStartAddress().toString());
                    JsonArray destinations = new JsonArray();
                    CodeBlockReferenceIterator edges = block.getDestinations(monitor);
                    while (edges.hasNext() && destinations.size() < 1000) destinations.add(edges.next().getDestinationAddress().toString());
                    node.add("destinations", destinations); blocks.add(node);
                }
                item.add("blocks", blocks);
                JsonArray callers = new JsonArray(); JsonArray callees = new JsonArray();
                for (Function caller : f.getCallingFunctions(monitor)) { if (callers.size() >= 1000) break; callers.add(caller.getEntryPoint().toString()); }
                for (Function callee : f.getCalledFunctions(monitor)) { if (callees.size() >= 1000) break; callees.add(callee.getEntryPoint().toString()); }
                item.add("callers", callers); item.add("callees", callees); functions.add(item);
            }
        } finally { decompiler.dispose(); }
        root.add("functions", functions); root.add("warnings", warnings);
        Files.writeString(Path.of(args[0]), new GsonBuilder().setPrettyPrinting().create().toJson(root));
    }
}
