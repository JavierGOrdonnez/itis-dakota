#!/bin/bash
#
# Regenerate stubs/dakota/environment/{__init__.pyi,environment.pyi} from
# the compiled dakota.environment extension. Requires wheelhouse/*.whl to
# already exist (run `make wheel` first, or invoke via `make stubs`).

set -ex

cd "$(dirname "$0")/.."

STUBS_VENV=.venv-stubs
STUBS_DIR=stubs/dakota/environment

rm -rf "$STUBS_VENV"

WHEEL=$(ls wheelhouse/itis_dakota-*.whl | head -1)
PYTAG=$(echo "$WHEEL" | sed -E 's/.*-(cp[0-9]+)-.*\.whl/\1/')
PYVER=$(echo "$PYTAG" | sed -E 's/cp([0-9])([0-9]+)/\1.\2/')

echo "Generating stubs for Python $PYVER (wheel: $WHEEL)"

if command -v uv >/dev/null 2>&1; then
	uv venv --python "$PYVER" "$STUBS_VENV"
	uv pip install --python "$STUBS_VENV/bin/python" numpy pybind11-stubgen "$WHEEL"
else
	"python$PYVER" -m venv "$STUBS_VENV"
	"$STUBS_VENV/bin/pip" install numpy pybind11-stubgen "$WHEEL"
fi

OUT=$(mktemp -d)
"$STUBS_VENV/bin/pybind11-stubgen" dakota.environment -o "$OUT"

mkdir -p "$STUBS_DIR"
cp "$OUT/dakota/environment/__init__.pyi" "$STUBS_DIR/__init__.pyi"
cp "$OUT/dakota/environment/environment.pyi" "$STUBS_DIR/environment.pyi"
touch "$STUBS_DIR/py.typed"

# pybind11-stubgen can't resolve the nlohmann::json/pybind11_json binding to
# a real Python type and emits a bare, unimported `json` annotation on the
# study(..., input_json) overloads. Normalize it to typing.Any (accurate:
# any JSON-serializable Python value) so the stub is actually valid.
sed -i 's/: json)/: typing.Any)/g' "$STUBS_DIR/environment.pyi"

# pybind11-stubgen can't see through the py::object/py::dict C++ params to
# the actual callable contract (traced via Pybind11Interface::derived_map_ac:
# a per-evaluation callback is invoked as callback(kwargs) -> dict; a batch
# callback (interface.concurrency.batch) is invoked as
# callback(list[kwargs]) -> Iterable[dict]; `callbacks` is dict[str, <either
# callback shape>] keyed by analysis-driver id). Replace the untyped
# `callback: typing.Any` / bare `callbacks: dict` with a proper Callable
# alias instead of leaving them as Any / an unparameterized dict.
"$STUBS_VENV/bin/python" - "$STUBS_DIR/environment.pyi" <<'PYEOF'
import re, sys

path = sys.argv[1]
text = open(path).read()

alias = (
    "DakotaEvaluatorCallback = typing.Callable[[dict[str, typing.Any]], dict[str, typing.Any]]\n"
    '"""Per-evaluation analysis-driver callback: receives a params dict (variable\n'
    "values/labels/ASV, either as numpy arrays or lists depending on the\n"
    '`numpy` interface option) and must return a response dict."""\n'
    "DakotaBatchCallback = typing.Callable[[list[dict[str, typing.Any]]], typing.Iterable[dict[str, typing.Any]]]\n"
    '"""Batch analysis-driver callback (used with `interface.concurrency.batch`):\n'
    "receives a list of per-evaluation params dicts and must return/yield one\n"
    'response dict per input, in the same order."""\n'
    "DakotaCallback = typing.Union[DakotaEvaluatorCallback, DakotaBatchCallback]\n"
    '"""Either callback shape accepted by `study(callback=...)` / `callbacks={...}`."""\n'
)
marker = "__all__: list[str] = "
idx = text.index(marker)
line_end = text.index("\n", idx) + 1
text = text[:line_end] + alias + text[line_end:]

text = text.replace("callback: typing.Any", "callback: DakotaCallback")
text = re.sub(r"callbacks: dict(?!\[)", "callbacks: dict[str, DakotaCallback]", text)

# pybind11-stubgen emits `numpy.ndarray[numpy.float64]`, but numpy.ndarray's
# single type-parameter is the shape, not the dtype (a type checker reports
# this as invalid). Use the correctly-parameterized numpy.typing.NDArray.
text = text.replace("import numpy\n", "import numpy\nimport numpy.typing\n", 1)
text = text.replace("numpy.ndarray[numpy.float64]", "numpy.typing.NDArray[numpy.float64]")

open(path, "w").write(text)
PYEOF

rm -rf "$OUT" "$STUBS_VENV"

echo "Stubs written to $STUBS_DIR/__init__.pyi"
