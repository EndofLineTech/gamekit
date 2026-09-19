"""Exercise the diagnostic C++ pass-through with a controlled shared library."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class CompileTimingTests(unittest.TestCase):
    def test_preserves_arguments_output_pointer_failure_and_errno(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            header = r'''
#include <string>
#include <vector>
#include <cerrno>
struct IRCompiler {}; struct IRObject {}; struct IRError {};
struct IRMetalLibBinary {}; struct IRShaderReflection {}; struct D3DMInputLayoutDesc {};
IRObject *IRCompilerAllocCompileAndLink(IRCompiler *, const std::vector<std::string> &, const IRObject *, IRError **);
'''
            (root / "api.h").write_text(header)
            (root / "mock.cpp").write_text(r'''
#include "api.h"
IRObject *IRCompilerAllocCompileAndLink(IRCompiler *c, const std::vector<std::string> &v, const IRObject *i, IRError **e) {
    static IRError error;
    if (!c || v.size() != 1 || v[0] != "private-shader-name" || !i || !e) __builtin_trap();
    *e = &error; errno = E2BIG;
    return c == reinterpret_cast<IRCompiler *>(1) ? const_cast<IRObject *>(i) : nullptr;
}
bool IRCreateStageInFunction(const IRCompiler *, IRMetalLibBinary *, const IRShaderReflection *, const D3DMInputLayoutDesc &) { return false; }
extern "C" const char *IRShaderReflectionCopyJSONString(const IRShaderReflection *) { return nullptr; }
extern "C" void IRShaderReflectionFreeString(const char *) {}
''')
            (root / "main.cpp").write_text(r'''
#include "api.h"
int main() {
    IRObject input; IRError *error = nullptr;
    std::vector<std::string> names{"private-shader-name"};
    auto result = IRCompilerAllocCompileAndLink(reinterpret_cast<IRCompiler *>(1), names, &input, &error);
    if (result != &input || !error || errno != E2BIG || names[0] != "private-shader-name") return 1;
    error = nullptr; errno = 0;
    result = IRCompilerAllocCompileAndLink(reinterpret_cast<IRCompiler *>(2), names, &input, &error);
    return result || !error || errno != E2BIG;
}
''')
            def run(args, **kwargs):
                result = subprocess.run(args, capture_output=True, timeout=30, **kwargs)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                return result
            compiler = ["xcrun", "clang++", "-std=c++17", "-Wall", "-Wextra", "-Werror"]
            mock = root / "mock.dylib"
            run(compiler + ["-dynamiclib", str(root / "mock.cpp"), "-o", str(mock)])
            helper = root / "trace.dylib"
            source = Path(__file__).resolve().parents[1] / "diagnostics/MetalStageInTrace.mm"
            run(compiler + ["-dynamiclib", "-fobjc-arc", "-framework", "Foundation", "-DGAMEKIT_COMPILE_TIMING",
                           '-DGAMEKIT_STAGEIN_LOG_DIRECTORY="' + str(root) + '"', str(source), str(mock), "-o", str(helper)])
            program = root / "helldivers2.exe"
            run(compiler + [str(root / "main.cpp"), str(mock), "-o", str(program)])
            run([str(program)], env=dict(os.environ, DYLD_INSERT_LIBRARIES=str(helper),
                                        GAMEKIT_SESSION_ID="test", WINEPREFIX=str(root)))
            text = (root / "stage-in.jsonl").read_text()
            rows = [json.loads(line) for line in text.splitlines()]
            calls = [r for r in rows if r["event"] == "compile-link"]
            self.assertEqual([r["success"] for r in calls], [True, False])
            self.assertTrue(all(r["durationMS"] >= 0 for r in calls))
            self.assertNotIn("private-shader-name", text)
