"""Zero-dependency mutation tester for all Python and Bash code in this repo.

Run from repo root:
    python3 tests/mutation_test.py
"""

import ast
import copy
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

PYTHON_TARGETS = [
    ("lambda/handler.py", ["tests.test_handler"]),
    ("chat_cli.py", ["tests.test_cli"]),
    ("backend/domain/entities.py", ["tests.test_clean_backend"]),
    ("backend/use_cases/ask_question.py", ["tests.test_clean_backend"]),
    ("backend/use_cases/submit_feedback.py", ["tests.test_clean_backend"]),
    ("backend/adapters/auth/jwks_verifier.py", ["tests.test_clean_backend"]),
    ("backend/adapters/controllers/apigw_controller.py", ["tests.test_clean_backend"]),
    ("agentcore_runtime/use_cases.py", ["tests.test_clean_backend"]),
]

BASH_TARGETS = [
    ("scripts/lib/common.sh", ["tests.test_scripts"]),
    ("scripts/guardrail.sh", ["tests.test_scripts", "tests.test_handler"]),
    ("scripts/storage.sh", ["tests.test_scripts"]),
    ("scripts/knowledge_base.sh", ["tests.test_scripts"]),
    ("scripts/compute_api.sh", ["tests.test_scripts"]),
    ("scripts/resource_group.sh", ["tests.test_scripts"]),
    ("scripts/checks.sh", ["tests.test_scripts"]),
    ("scripts/smoke_test_tf.sh", ["tests.test_scripts"]),
    ("deploy.sh", ["tests.test_scripts"]),
    ("teardown.sh", ["tests.test_scripts"]),
]


def generate_python_mutants(source_code):
    tree = ast.parse(source_code)
    mutants = []

    def add_mutant(mutated_tree, lineno, desc):
        try:
            code = ast.unparse(mutated_tree)
        except Exception:
            return
        if code != source_code:
            mutants.append((lineno, desc, code))

    nodes = list(ast.walk(tree))
    for idx, node in enumerate(nodes):
        lineno = getattr(node, "lineno", 0)

        if isinstance(node, ast.Compare) and len(node.ops) == 1:
            op = node.ops[0]
            swaps = {
                ast.Eq: (ast.NotEq, "== -> !="),
                ast.NotEq: (ast.Eq, "!= -> =="),
                ast.In: (ast.NotIn, "in -> not in"),
                ast.NotIn: (ast.In, "not in -> in"),
            }
            for src_cls, (dst_cls, label) in swaps.items():
                if isinstance(op, src_cls):
                    cloned = copy.deepcopy(tree)
                    list(ast.walk(cloned))[idx].ops[0] = dst_cls()
                    add_mutant(cloned, lineno, f"Compare: {label}")

        if isinstance(node, ast.BoolOp):
            if isinstance(node.op, ast.And):
                cloned = copy.deepcopy(tree)
                list(ast.walk(cloned))[idx].op = ast.Or()
                add_mutant(cloned, lineno, "BoolOp: and -> or")
            elif isinstance(node.op, ast.Or):
                cloned = copy.deepcopy(tree)
                list(ast.walk(cloned))[idx].op = ast.And()
                add_mutant(cloned, lineno, "BoolOp: or -> and")

        if isinstance(node, ast.Constant):
            val = node.value
            if isinstance(val, bool):
                cloned = copy.deepcopy(tree)
                list(ast.walk(cloned))[idx].value = not val
                add_mutant(cloned, lineno, f"Bool: {val} -> {not val}")
            elif isinstance(val, int) and val in (1, 5, 30, 200, 400, 429, 500, 502):
                cloned = copy.deepcopy(tree)
                list(ast.walk(cloned))[idx].value = val + 1
                add_mutant(cloned, lineno, f"Int: {val} -> {val + 1}")
            elif isinstance(val, str) and val in (
                "NONE",
                "INTERVENED",
                "guardrail_intervened",
                "vector",
                "managed",
                "multi",
                "single",
                "ThrottlingException",
                "sharePointLocation",
                "s3Location",
                "webLocation",
                "POST",
                "x-api-key",
                "RAG_API_URL",
                "RAG_API_KEY",
                "exit",
                "quit",
            ):
                cloned = copy.deepcopy(tree)
                list(ast.walk(cloned))[idx].value = f"MUTATED_{val}"
                add_mutant(cloned, lineno, f"Str: '{val}' -> 'MUTATED_{val}'")

        if isinstance(node, ast.If) and isinstance(node.test, ast.UnaryOp) and isinstance(node.test.op, ast.Not):
            cloned = copy.deepcopy(tree)
            target_if = list(ast.walk(cloned))[idx]
            target_if.test = target_if.test.operand
            add_mutant(cloned, lineno, "If: remove 'not'")

        if (
            isinstance(node, ast.Expr)
            and isinstance(node.value, ast.Call)
            and isinstance(node.value.func, ast.Attribute)
            and node.value.func.attr == "reverse"
        ):
            cloned = copy.deepcopy(tree)
            list(ast.walk(cloned))[idx].value = ast.Constant(value=None)
            add_mutant(cloned, lineno, "Drop items.reverse()")

    return mutants


# Targeted high-signal Bash mutation rules (line-based, skipping comments/echoes)
BASH_RULES = [
    (r'\[ "\$\{KB_REUSED:-false\}" = "true" \]', '[ "${KB_REUSED:-false}" != "true" ]', 'flip KB_REUSED = true'),
    (r'\[ "\$\{KEEP_KB:-false\}" = "true" \]', '[ "${KEEP_KB:-false}" != "true" ]', 'flip KEEP_KB = true'),
    (r'\[ "\$\{DDB_REUSED:-false\}" = "true" \]', '[ "${DDB_REUSED:-false}" != "true" ]', 'flip DDB_REUSED = true'),
    (r'\[ "\$\{GUARDRAIL_MANAGED:-true\}" = "true" \]', '[ "${GUARDRAIL_MANAGED:-true}" != "true" ]', 'flip GUARDRAIL_MANAGED = true'),
    (r'\[ "\$\{KEEP_KB_REPLY\}" = "YES" \]', '[ "${KEEP_KB_REPLY}" = "yes" ]', 'weaken YES -> yes'),
    (r'\[ "\$\{kb_status\}" = "ACTIVE" \]', '[ "${kb_status}" != "ACTIVE" ]', 'flip ACTIVE status check'),
    (r'"Sites\.Selected"', '"Sites.MUTATED"', 'mutate Sites.Selected'),
    (r'"Sites\.Read\.All"', '"Sites.MUTATED"', 'mutate Sites.Read.All'),
    (r'\[\[\s*!\s*"\$\{value\}"\s*=~', '[[ "${value}" =~', 'invert validate_slug regex'),
    (r'"inputStrength": "HIGH"', '"inputStrength": "LOW"', 'weaken guardrail HIGH -> LOW'),
    (r'"action": "ANONYMIZE"', '"action": "BLOCK"', 'mutate PII ANONYMIZE -> BLOCK'),
    (r'KB_MODE=\$\{KB_MODE\}', 'KB_MODE=hardcoded', 'break Lambda KB_MODE wiring'),
    (r'retag_reused_resources', ': # skipped retag_reused_resources', 'skip retag_reused_resources'),
    (r'save_config_var "\$\{CONFIG_FILE\}" "KB_ID"', ': # skipped save KB_ID', 'skip saving KB_ID'),
    (r'clear_config_var "\$\{CONFIG_FILE\}" "KB_ID"', ': # skipped clear KB_ID', 'skip clearing KB_ID'),
    (r'aws bedrock delete-guardrail', ': # skipped delete-guardrail', 'skip delete-guardrail'),
    (r'aws s3vectors delete-index', ': # skipped delete-index', 'skip s3vectors delete-index'),
    (r'aws bedrock-agent delete-knowledge-base', ': # skipped delete-kb', 'skip delete-knowledge-base'),
]


def generate_bash_mutants(source_code):
    lines = source_code.splitlines(keepends=True)
    mutants = []
    seen = set()

    for idx, line in enumerate(lines, 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        for pattern, repl, desc in BASH_RULES:
            if re.search(pattern, line):
                # Limit repeated identical PII lines to the first occurrence per file
                key = (desc,)
                if desc == "mutate PII ANONYMIZE -> BLOCK" and key in seen:
                    continue
                if desc == "weaken guardrail HIGH -> LOW" and key in seen:
                    continue
                seen.add(key)
                mutated_line = re.sub(pattern, repl, line, count=1)
                if mutated_line != line:
                    new_lines = lines[: idx - 1] + [mutated_line] + lines[idx:]
                    mutants.append((idx, desc, "".join(new_lines)))
    return mutants


def run_test_modules(modules):
    proc = subprocess.run(
        [sys.executable, "-m", "unittest", *modules],
        cwd=REPO_ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return proc.returncode == 0


def mutate_file(rel_path, modules, generator):
    path = REPO_ROOT / rel_path
    original = path.read_text(encoding="utf-8")
    mutants = generator(original)
    killed = 0
    survived = []

    try:
        for lineno, desc, code in mutants:
            path.write_text(code, encoding="utf-8")
            if run_test_modules(modules):
                survived.append((lineno, desc))
            else:
                killed += 1
    finally:
        path.write_text(original, encoding="utf-8")

    return len(mutants), killed, survived


def main():
    baseline = subprocess.run(
        [sys.executable, "-m", "unittest", "discover", "-s", "tests"],
        cwd=REPO_ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if baseline.returncode != 0:
        print("Baseline tests FAILED! Aborting mutation run.")
        sys.exit(1)

    total_all = 0
    killed_all = 0
    all_survived = []

    print(f"{'File':<30} {'Mutants':>7} {'Killed':>7} {'Survived':>8} {'Score':>8}")
    print("-" * 66)

    for rel_path, modules in PYTHON_TARGETS:
        total, killed, survived = mutate_file(rel_path, modules, generate_python_mutants)
        total_all += total
        killed_all += killed
        score = (killed / total * 100) if total else 100.0
        print(f"{rel_path:<30} {total:>7} {killed:>7} {len(survived):>8} {score:>7.1f}%")
        for lineno, desc in survived:
            all_survived.append((rel_path, lineno, desc))

    for rel_path, modules in BASH_TARGETS:
        total, killed, survived = mutate_file(rel_path, modules, generate_bash_mutants)
        total_all += total
        killed_all += killed
        score = (killed / total * 100) if total else 100.0
        print(f"{rel_path:<30} {total:>7} {killed:>7} {len(survived):>8} {score:>7.1f}%")
        for lineno, desc in survived:
            all_survived.append((rel_path, lineno, desc))

    print("-" * 66)
    overall = (killed_all / total_all * 100) if total_all else 100.0
    print(f"{'TOTAL':<30} {total_all:>7} {killed_all:>7} {len(all_survived):>8} {overall:>7.1f}%")

    if all_survived:
        print("\nSurviving mutants:")
        for rel_path, lineno, desc in all_survived:
            print(f"  {rel_path}:{lineno} -> {desc}")
        sys.exit(1)


if __name__ == "__main__":
    main()
